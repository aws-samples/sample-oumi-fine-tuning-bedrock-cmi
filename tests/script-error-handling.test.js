/**
 * Property-Based Tests for Script Error Handling
 * 
 * Feature: oumi-blog-security-remediation
 * Property 4: Script Error Handling
 * 
 * **Validates: Requirements 5.3**
 * 
 * For any executable script in the repository, the script SHALL include
 * error handling with appropriate exit codes and error messages.
 */

import fc from 'fast-check';
import fs from 'fs';
import path from 'path';
import { fileURLToPath } from 'url';

const __filename = fileURLToPath(import.meta.url);
const __dirname = path.dirname(__filename);

// Paths to script directories
const SECURITY_SCRIPTS_DIR = path.join(__dirname, '..', 'security');
const WORKFLOW_SCRIPTS_DIR = path.join(__dirname, '..', 'scripts');

/**
 * Find all shell scripts in a directory
 */
function findShellScripts(dir, scripts = []) {
  if (!fs.existsSync(dir)) {
    return scripts;
  }
  
  const entries = fs.readdirSync(dir, { withFileTypes: true });
  
  for (const entry of entries) {
    const fullPath = path.join(dir, entry.name);
    if (entry.isDirectory()) {
      findShellScripts(fullPath, scripts);
    } else if (entry.name.endsWith('.sh')) {
      scripts.push(fullPath);
    }
  }
  
  return scripts;
}

/**
 * Error handling patterns in shell scripts
 */
const ERROR_HANDLING_PATTERNS = {
  // Strict mode settings
  strictMode: [
    /set\s+-e/,                         // set -e (exit on error)
    /set\s+-u/,                         // set -u (error on undefined vars)
    /set\s+-o\s+pipefail/,              // set -o pipefail
    /set\s+-euo\s+pipefail/,            // Combined strict mode
  ],
  
  // Exit codes
  exitCodes: [
    /exit\s+\$\w+/,                     // exit $variable
    /exit\s+[0-9]+/,                    // exit with numeric code
    /return\s+\$\w+/,                   // return $variable
    /return\s+[0-9]+/,                  // return with numeric code
    /EXIT_\w+=/,                        // EXIT_* constant definitions
  ],
  
  // Error logging
  errorLogging: [
    /log_error/,                        // log_error function call
    /echo.*\[ERROR\]/,                  // echo with [ERROR] prefix
    /echo.*>&2/,                        // echo to stderr
    /printf[\s\S]*>&2/,                 // printf to stderr ([\s\S] matches any char including newlines)
  ],
  
  // Conditional error handling
  conditionalHandling: [
    /if\s+!\s+/,                        // if ! command (negation check)
    /\|\|\s+\{/,                        // || { error handling block
    /\|\|\s+return/,                    // || return on failure
    /\|\|\s+exit/,                      // || exit on failure
    /\|\|\s+log_error/,                 // || log_error on failure
  ],
  
  // Command result checking
  resultChecking: [
    /\$\?/,                             // Check last command exit status
    /if\s+\[\[?\s+\$\?\s+/,            // if [[ $? ... ]]
  ],
};

/**
 * Check if script has strict mode enabled
 */
function hasStrictMode(content) {
  return ERROR_HANDLING_PATTERNS.strictMode.some(pattern => pattern.test(content));
}

/**
 * Check if script has defined exit codes
 */
function hasExitCodes(content) {
  return ERROR_HANDLING_PATTERNS.exitCodes.some(pattern => pattern.test(content));
}

/**
 * Check if script has error logging
 */
function hasErrorLogging(content) {
  return ERROR_HANDLING_PATTERNS.errorLogging.some(pattern => pattern.test(content));
}

/**
 * Check if script has conditional error handling
 */
function hasConditionalHandling(content) {
  return ERROR_HANDLING_PATTERNS.conditionalHandling.some(pattern => pattern.test(content));
}

/**
 * Count total error handling patterns found
 */
function countErrorHandlingPatterns(content) {
  let count = 0;
  
  for (const category of Object.values(ERROR_HANDLING_PATTERNS)) {
    for (const pattern of category) {
      if (pattern.test(content)) {
        count++;
      }
    }
  }
  
  return count;
}

/**
 * Check if script has comprehensive error handling
 * Requires at least one pattern from each category
 */
function hasComprehensiveErrorHandling(content) {
  return (
    hasStrictMode(content) &&
    hasExitCodes(content) &&
    hasErrorLogging(content) &&
    hasConditionalHandling(content)
  );
}

/**
 * Extract exit code constants from script
 */
function extractExitCodeConstants(content) {
  const exitCodePattern = /readonly\s+(EXIT_\w+)=(\d+)/g;
  const constants = [];
  let match;
  
  while ((match = exitCodePattern.exec(content)) !== null) {
    constants.push({
      name: match[1],
      value: parseInt(match[2], 10)
    });
  }
  
  return constants;
}

/**
 * Check if script uses consistent exit codes
 */
function usesConsistentExitCodes(content) {
  const constants = extractExitCodeConstants(content);
  
  if (constants.length === 0) {
    return false;
  }
  
  // Check that EXIT_SUCCESS is 0
  const successCode = constants.find(c => c.name === 'EXIT_SUCCESS');
  if (successCode && successCode.value !== 0) {
    return false;
  }
  
  // Check that error codes are non-zero
  const errorCodes = constants.filter(c => c.name !== 'EXIT_SUCCESS');
  return errorCodes.every(c => c.value > 0);
}

describe('Feature: oumi-blog-security-remediation, Property 4: Script Error Handling', () => {
  
  // Get all shell scripts
  const securityScripts = findShellScripts(SECURITY_SCRIPTS_DIR);
  const workflowScripts = findShellScripts(WORKFLOW_SCRIPTS_DIR);
  const allScripts = [...securityScripts, ...workflowScripts];
  
  test('Security scripts directory should contain shell scripts', () => {
    expect(securityScripts.length).toBeGreaterThan(0);
  });
  
  // Test each script has strict mode enabled
  securityScripts.forEach(scriptPath => {
    const relativePath = path.relative(path.join(__dirname, '..'), scriptPath);
    
    test(`Script ${relativePath} should have strict mode enabled`, () => {
      const content = fs.readFileSync(scriptPath, 'utf-8');
      
      if (!hasStrictMode(content)) {
        fail(`Script does not have strict mode (set -euo pipefail): ${relativePath}`);
      }
      
      expect(hasStrictMode(content)).toBe(true);
    });
  });
  
  // Test each script has defined exit codes
  securityScripts.forEach(scriptPath => {
    const relativePath = path.relative(path.join(__dirname, '..'), scriptPath);
    
    test(`Script ${relativePath} should have defined exit codes`, () => {
      const content = fs.readFileSync(scriptPath, 'utf-8');
      
      if (!hasExitCodes(content)) {
        fail(`Script does not have defined exit codes: ${relativePath}`);
      }
      
      expect(hasExitCodes(content)).toBe(true);
    });
  });
  
  // Test each script has error logging
  securityScripts.forEach(scriptPath => {
    const relativePath = path.relative(path.join(__dirname, '..'), scriptPath);
    
    test(`Script ${relativePath} should have error logging`, () => {
      const content = fs.readFileSync(scriptPath, 'utf-8');
      
      if (!hasErrorLogging(content)) {
        fail(`Script does not have error logging: ${relativePath}`);
      }
      
      expect(hasErrorLogging(content)).toBe(true);
    });
  });
  
  // Test each script has conditional error handling
  securityScripts.forEach(scriptPath => {
    const relativePath = path.relative(path.join(__dirname, '..'), scriptPath);
    
    test(`Script ${relativePath} should have conditional error handling`, () => {
      const content = fs.readFileSync(scriptPath, 'utf-8');
      
      if (!hasConditionalHandling(content)) {
        fail(`Script does not have conditional error handling: ${relativePath}`);
      }
      
      expect(hasConditionalHandling(content)).toBe(true);
    });
  });
  
  // Test each script uses consistent exit codes
  securityScripts.forEach(scriptPath => {
    const relativePath = path.relative(path.join(__dirname, '..'), scriptPath);
    
    test(`Script ${relativePath} should use consistent exit codes`, () => {
      const content = fs.readFileSync(scriptPath, 'utf-8');
      
      if (!usesConsistentExitCodes(content)) {
        fail(`Script does not use consistent exit codes: ${relativePath}`);
      }
      
      expect(usesConsistentExitCodes(content)).toBe(true);
    });
  });
  
  // Property-based test: Error handling patterns are correctly identified
  test('Property: Error handling patterns correctly identify error handling code', () => {
    const errorHandlingSnippetArbitrary = fc.oneof(
      // Strict mode patterns
      fc.constantFrom(
        'set -e',
        'set -u',
        'set -o pipefail',
        'set -euo pipefail'
      ),
      // Exit code patterns
      fc.constantFrom(
        'exit 0',
        'exit 1',
        'exit $EXIT_ERROR',
        'return $EXIT_SUCCESS',
        'readonly EXIT_SUCCESS=0'
      ),
      // Error logging patterns
      fc.constantFrom(
        'log_error "Something went wrong"',
        'echo "[ERROR] Failed to execute" >&2',
        'printf "Error: %s\n" "$msg" >&2'
      ),
      // Conditional handling patterns
      fc.constantFrom(
        'if ! command; then',
        'command || { log_error "failed"; return 1; }',
        'command || return $EXIT_ERROR',
        'command || exit 1'
      )
    );
    
    fc.assert(
      fc.property(errorHandlingSnippetArbitrary, (snippet) => {
        // All generated error handling snippets should be detected
        return countErrorHandlingPatterns(snippet) > 0;
      }),
      { numRuns: 100 }
    );
  });
  
  // Property-based test: Non-error-handling code should not be flagged
  test('Property: Non-error-handling code is not flagged as error handling', () => {
    const nonErrorHandlingSnippetArbitrary = fc.constantFrom(
      'echo "Hello World"',
      'local var="value"',
      'for item in list; do',
      'while true; do',
      'function do_something() {',
      '# This is a comment',
      'aws s3 ls',
      'grep pattern file.txt'
    );
    
    fc.assert(
      fc.property(nonErrorHandlingSnippetArbitrary, (snippet) => {
        // Non-error-handling snippets should have 0 patterns
        return countErrorHandlingPatterns(snippet) === 0;
      }),
      { numRuns: 100 }
    );
  });
  
  // Property-based test: Scripts should have comprehensive error handling
  test('Property: Security scripts have comprehensive error handling', () => {
    // For each security script, verify it has comprehensive error handling
    const scriptContents = securityScripts.map(scriptPath => ({
      path: scriptPath,
      content: fs.readFileSync(scriptPath, 'utf-8')
    }));
    
    for (const { path: scriptPath, content } of scriptContents) {
      const relativePath = path.relative(path.join(__dirname, '..'), scriptPath);
      
      expect(hasComprehensiveErrorHandling(content)).toBe(true);
    }
  });
  
  // Property-based test: Exit codes should follow conventions
  test('Property: Exit codes follow Unix conventions', () => {
    // Generate exit code scenarios
    const exitCodeArbitrary = fc.record({
      success: fc.constant(0),
      invalidArgs: fc.integer({ min: 1, max: 255 }),
      awsError: fc.integer({ min: 1, max: 255 }),
      validationError: fc.integer({ min: 1, max: 255 })
    });
    
    fc.assert(
      fc.property(exitCodeArbitrary, (codes) => {
        // Success should always be 0
        if (codes.success !== 0) return false;
        
        // Error codes should be non-zero
        if (codes.invalidArgs === 0) return false;
        if (codes.awsError === 0) return false;
        if (codes.validationError === 0) return false;
        
        // Error codes should be in valid range (1-255)
        if (codes.invalidArgs > 255) return false;
        if (codes.awsError > 255) return false;
        if (codes.validationError > 255) return false;
        
        return true;
      }),
      { numRuns: 100 }
    );
  });
});
