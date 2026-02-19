/**
 * Property-Based Tests for IAM Policy Least-Privilege Compliance
 * 
 * Feature: oumi-blog-security-remediation
 * Property 1: IAM Policy Least-Privilege Compliance
 * 
 * **Validates: Requirements 2.2**
 * 
 * For any IAM policy document in the repository, all policy statements 
 * SHALL NOT contain wildcard (*) actions in the Action field.
 */

import fc from 'fast-check';
import fs from 'fs';
import path from 'path';
import { fileURLToPath } from 'url';

const __filename = fileURLToPath(import.meta.url);
const __dirname = path.dirname(__filename);

// Path to IAM policies directory
const IAM_POLICIES_DIR = path.join(__dirname, '..', 'iam');

/**
 * Recursively find all JSON files in a directory
 */
function findJsonFiles(dir, files = []) {
  if (!fs.existsSync(dir)) {
    return files;
  }
  
  const entries = fs.readdirSync(dir, { withFileTypes: true });
  
  for (const entry of entries) {
    const fullPath = path.join(dir, entry.name);
    if (entry.isDirectory()) {
      findJsonFiles(fullPath, files);
    } else if (entry.name.endsWith('.json')) {
      files.push(fullPath);
    }
  }
  
  return files;
}

/**
 * Check if an action contains a wildcard
 */
function containsWildcardAction(action) {
  if (typeof action === 'string') {
    // Check for standalone wildcard or wildcard in action (e.g., "s3:*", "*")
    return action === '*' || action.endsWith(':*');
  }
  return false;
}

/**
 * Extract all actions from a policy statement
 */
function extractActions(statement) {
  const actions = [];
  if (statement.Action) {
    if (Array.isArray(statement.Action)) {
      actions.push(...statement.Action);
    } else {
      actions.push(statement.Action);
    }
  }
  return actions;
}

/**
 * Validate that a policy has no wildcard actions in Allow statements
 */
function validateNoWildcardActions(policy) {
  const violations = [];
  
  if (!policy.Statement || !Array.isArray(policy.Statement)) {
    return violations;
  }
  
  for (const statement of policy.Statement) {
    // Only check Allow statements - Deny statements with wildcards are acceptable
    if (statement.Effect === 'Allow') {
      const actions = extractActions(statement);
      for (const action of actions) {
        if (containsWildcardAction(action)) {
          violations.push({
            sid: statement.Sid || 'unnamed',
            action: action
          });
        }
      }
    }
  }
  
  return violations;
}

describe('Feature: oumi-blog-security-remediation, Property 1: IAM Policy Least-Privilege Compliance', () => {
  
  // Get all IAM policy files
  const policyFiles = findJsonFiles(IAM_POLICIES_DIR);
  
  test('IAM policies directory should contain policy files', () => {
    expect(policyFiles.length).toBeGreaterThan(0);
  });
  
  // Test each policy file for wildcard actions
  policyFiles.forEach(policyFile => {
    const relativePath = path.relative(IAM_POLICIES_DIR, policyFile);
    
    test(`Policy ${relativePath} should not contain wildcard actions in Allow statements`, () => {
      const content = fs.readFileSync(policyFile, 'utf-8');
      const policy = JSON.parse(content);
      
      const violations = validateNoWildcardActions(policy);
      
      if (violations.length > 0) {
        const violationDetails = violations
          .map(v => `Statement "${v.sid}" has wildcard action: ${v.action}`)
          .join('\n');
        fail(`Found wildcard actions in Allow statements:\n${violationDetails}`);
      }
      
      expect(violations).toHaveLength(0);
    });
  });
  
  // Property-based test: For any generated IAM policy-like structure,
  // our validation function correctly identifies wildcard actions
  test('Property: Validation function correctly identifies wildcard actions', () => {
    // Arbitrary for generating IAM-like action strings
    const actionArbitrary = fc.oneof(
      fc.constant('*'),
      fc.constant('s3:*'),
      fc.constant('ec2:*'),
      fc.constant('bedrock:*'),
      fc.constant('s3:GetObject'),
      fc.constant('s3:PutObject'),
      fc.constant('ec2:DescribeInstances'),
      fc.constant('bedrock:InvokeModel'),
      fc.constant('kms:Decrypt'),
      fc.constant('logs:CreateLogStream')
    );
    
    // Arbitrary for generating policy statements
    const statementArbitrary = fc.record({
      Sid: fc.string({ minLength: 1, maxLength: 20 }),
      Effect: fc.constantFrom('Allow', 'Deny'),
      Action: fc.oneof(
        actionArbitrary,
        fc.array(actionArbitrary, { minLength: 1, maxLength: 5 })
      ),
      Resource: fc.constant('arn:aws:s3:::test-bucket/*')
    });
    
    // Arbitrary for generating policies
    const policyArbitrary = fc.record({
      Version: fc.constant('2012-10-17'),
      Statement: fc.array(statementArbitrary, { minLength: 1, maxLength: 5 })
    });
    
    fc.assert(
      fc.property(policyArbitrary, (policy) => {
        const violations = validateNoWildcardActions(policy);
        
        // Count expected violations (wildcard actions in Allow statements)
        let expectedViolationCount = 0;
        for (const statement of policy.Statement) {
          if (statement.Effect === 'Allow') {
            const actions = extractActions(statement);
            for (const action of actions) {
              if (containsWildcardAction(action)) {
                expectedViolationCount++;
              }
            }
          }
        }
        
        return violations.length === expectedViolationCount;
      }),
      { numRuns: 100 }
    );
  });
  
  // Property-based test: Specific actions (non-wildcard) should never be flagged
  test('Property: Specific actions are never flagged as violations', () => {
    const specificActions = [
      's3:GetObject',
      's3:PutObject',
      's3:ListBucket',
      'bedrock:InvokeModel',
      'bedrock:CreateModelImportJob',
      'logs:CreateLogStream',
      'logs:PutLogEvents'
    ];
    
    const specificActionArbitrary = fc.constantFrom(...specificActions);
    
    const statementArbitrary = fc.record({
      Sid: fc.string({ minLength: 1, maxLength: 20 }),
      Effect: fc.constant('Allow'),
      Action: fc.oneof(
        specificActionArbitrary,
        fc.array(specificActionArbitrary, { minLength: 1, maxLength: 5 })
      ),
      Resource: fc.constant('arn:aws:s3:::test-bucket/*')
    });
    
    const policyArbitrary = fc.record({
      Version: fc.constant('2012-10-17'),
      Statement: fc.array(statementArbitrary, { minLength: 1, maxLength: 5 })
    });
    
    fc.assert(
      fc.property(policyArbitrary, (policy) => {
        const violations = validateNoWildcardActions(policy);
        return violations.length === 0;
      }),
      { numRuns: 100 }
    );
  });
  
  // Property-based test: Wildcard actions in Deny statements should not be flagged
  test('Property: Wildcard actions in Deny statements are acceptable', () => {
    const wildcardActions = ['*', 's3:*', 'ec2:*', 'bedrock:*'];
    const wildcardActionArbitrary = fc.constantFrom(...wildcardActions);
    
    const denyStatementArbitrary = fc.record({
      Sid: fc.string({ minLength: 1, maxLength: 20 }),
      Effect: fc.constant('Deny'),
      Action: fc.oneof(
        wildcardActionArbitrary,
        fc.array(wildcardActionArbitrary, { minLength: 1, maxLength: 3 })
      ),
      Resource: fc.constant('arn:aws:s3:::test-bucket/*')
    });
    
    const policyArbitrary = fc.record({
      Version: fc.constant('2012-10-17'),
      Statement: fc.array(denyStatementArbitrary, { minLength: 1, maxLength: 3 })
    });
    
    fc.assert(
      fc.property(policyArbitrary, (policy) => {
        const violations = validateNoWildcardActions(policy);
        // Deny statements with wildcards should not be flagged
        return violations.length === 0;
      }),
      { numRuns: 100 }
    );
  });
});
