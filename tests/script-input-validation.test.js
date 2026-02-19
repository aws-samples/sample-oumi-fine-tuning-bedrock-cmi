/**
 * Property-Based Tests for Script Input Validation
 * 
 * Feature: oumi-blog-security-remediation
 * Property 3: Script Input Validation
 * 
 * **Validates: Requirements 5.1, 5.2**
 * 
 * For any executable script in the repository that accepts parameters,
 * the script SHALL include validation logic that checks parameter values
 * before execution.
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
 * Patterns that indicate input validation in shell scripts
 */
const INPUT_VALIDATION_PATTERNS = [
  // Variable emptiness checks
  /\[\[\s*-z\s+"\$\{?\w+/,           // [[ -z "$var" or [[ -z "${var
  /\[\[\s*-n\s+"\$\{?\w+/,           // [[ -n "$var" or [[ -n "${var
  /\[\s+-z\s+"\$\{?\w+/,             // [ -z "$var" or [ -z "${var
  /\[\s+-n\s+"\$\{?\w+/,             // [ -n "$var" or [ -n "${var
  
  // Parameter default/required patterns
  /\$\{\w+:-/,                        // ${var:-default}
  /\$\{\w+:\?/,                       // ${var:?error}
  
  // Regex validation
  /=~\s+\^/,                          // =~ ^ (regex match)
  
  // Validation function calls
  /validate_\w+/,                     // validate_* function calls
  
  // Conditional checks on parameters
  /if\s+\[\[?\s+.*\$\{?\w+/,         // if [[ ... $var or if [ ... $var
];

/**
 * Patterns that indicate the script accepts parameters
 */
const PARAMETER_ACCEPTANCE_PATTERNS = [
  /\$1\b/,                            // $1 positional parameter
  /\$2\b/,                            // $2 positional parameter
  /\$\{1/,                            // ${1} or ${1:-}
  /\$\{2/,                            // ${2} or ${2:-}
  /\$@/,                              // $@ all parameters
  /\$\*/,                             // $* all parameters
  /\$#/,                              // $# parameter count
  /getopts/,                          // getopts for option parsing
  /shift\b/,                          // shift command
];

/**
 * Check if a script accepts parameters
 */
function acceptsParameters(content) {
  return PARAMETER_ACCEPTANCE_PATTERNS.some(pattern => pattern.test(content));
}

/**
 * Check if a script has input validation
 */
function hasInputValidation(content) {
  return INPUT_VALIDATION_PATTERNS.some(pattern => pattern.test(content));
}

/**
 * Count the number of validation patterns found in content
 */
function countValidationPatterns(content) {
  return INPUT_VALIDATION_PATTERNS.filter(pattern => pattern.test(content)).length;
}

/**
 * Extract function definitions from a shell script
 */
function extractFunctions(content) {
  const functionPattern = /^(\w+)\s*\(\)\s*\{/gm;
  const functions = [];
  let match;
  
  while ((match = functionPattern.exec(content)) !== null) {
    functions.push(match[1]);
  }
  
  return functions;
}

/**
 * Check if a function has validation logic
 */
function functionHasValidation(content, functionName) {
  // Find the function body
  const functionStart = content.indexOf(`${functionName}()`);
  if (functionStart === -1) {
    return false;
  }
  
  // Extract function body (simplified - looks for next function or end)
  const afterFunction = content.slice(functionStart);
  const braceStart = afterFunction.indexOf('{');
  if (braceStart === -1) {
    return false;
  }
  
  // Find matching closing brace (simplified approach)
  let braceCount = 0;
  let functionEnd = braceStart;
  for (let i = braceStart; i < afterFunction.length; i++) {
    if (afterFunction[i] === '{') braceCount++;
    if (afterFunction[i] === '}') braceCount--;
    if (braceCount === 0) {
      functionEnd = i;
      break;
    }
  }
  
  const functionBody = afterFunction.slice(braceStart, functionEnd + 1);
  return hasInputValidation(functionBody);
}

describe('Feature: oumi-blog-security-remediation, Property 3: Script Input Validation', () => {
  
  // Get all shell scripts
  const securityScripts = findShellScripts(SECURITY_SCRIPTS_DIR);
  const workflowScripts = findShellScripts(WORKFLOW_SCRIPTS_DIR);
  const allScripts = [...securityScripts, ...workflowScripts];
  
  test('Security scripts directory should contain shell scripts', () => {
    expect(securityScripts.length).toBeGreaterThan(0);
  });
  
  // Test each script that accepts parameters has input validation
  allScripts.forEach(scriptPath => {
    const relativePath = path.relative(path.join(__dirname, '..'), scriptPath);
    
    test(`Script ${relativePath} should have input validation if it accepts parameters`, () => {
      const content = fs.readFileSync(scriptPath, 'utf-8');
      
      if (acceptsParameters(content)) {
        const hasValidation = hasInputValidation(content);
        
        if (!hasValidation) {
          fail(`Script accepts parameters but has no input validation: ${relativePath}`);
        }
        
        expect(hasValidation).toBe(true);
      } else {
        // Script doesn't accept parameters, validation not required
        expect(true).toBe(true);
      }
    });
  });
  
  // Test that validation functions exist for parameter-accepting scripts
  securityScripts.forEach(scriptPath => {
    const relativePath = path.relative(path.join(__dirname, '..'), scriptPath);
    
    test(`Script ${relativePath} should have dedicated validation functions`, () => {
      const content = fs.readFileSync(scriptPath, 'utf-8');
      
      if (acceptsParameters(content)) {
        const functions = extractFunctions(content);
        const validationFunctions = functions.filter(f => f.startsWith('validate_'));
        
        // Scripts that accept parameters should have at least one validation function
        expect(validationFunctions.length).toBeGreaterThan(0);
      }
    });
  });
  
  // Property-based test: For any generated parameter name, validation should check it
  test('Property: Validation patterns correctly identify validation logic', () => {
    // Arbitrary for generating shell script validation snippets
    const validationSnippetArbitrary = fc.oneof(
      // Empty check patterns
      fc.constantFrom(
        'if [[ -z "$bucket_name" ]]; then',
        'if [[ -z "${bucket_name:-}" ]]; then',
        'if [ -z "$1" ]; then',
        '[[ -n "$key_id" ]] || return 1'
      ),
      // Regex validation patterns
      fc.constantFrom(
        'if [[ ! "$bucket_name" =~ ^[a-z0-9] ]]; then',
        '[[ "$key_id" =~ ^[a-f0-9-]+$ ]]'
      ),
      // Validation function calls
      fc.constantFrom(
        'validate_bucket_name "$bucket_name"',
        'validate_name "$1" "resource"'
      ),
      // Parameter defaults
      fc.constantFrom(
        'local bucket_name="${1:-}"',
        'local key_id="${2:?Key ID required}"'
      )
    );
    
    fc.assert(
      fc.property(validationSnippetArbitrary, (snippet) => {
        // All generated validation snippets should be detected as validation
        return hasInputValidation(snippet);
      }),
      { numRuns: 100 }
    );
  });
  
  // Property-based test: Non-validation code should not be flagged as validation
  test('Property: Non-validation code is not flagged as validation', () => {
    const nonValidationSnippetArbitrary = fc.constantFrom(
      'echo "Hello World"',
      'aws s3 cp file.txt s3://bucket/',
      'local result=$(some_command)',
      'for item in "${items[@]}"; do',
      'while read -r line; do',
      'case "$command" in',
      'function do_something() {',
      '# This is a comment'
    );
    
    fc.assert(
      fc.property(nonValidationSnippetArbitrary, (snippet) => {
        // Non-validation snippets should not be detected as validation
        return !hasInputValidation(snippet);
      }),
      { numRuns: 100 }
    );
  });
  
  // Property-based test: Scripts with parameters should have proportional validation
  test('Property: Parameter-accepting scripts have multiple validation patterns', () => {
    // For each security script that accepts parameters, verify it has multiple validation patterns
    const scriptsWithParams = securityScripts.filter(scriptPath => {
      const content = fs.readFileSync(scriptPath, 'utf-8');
      return acceptsParameters(content);
    });
    
    // Generate test cases for each script
    const scriptContents = scriptsWithParams.map(scriptPath => ({
      path: scriptPath,
      content: fs.readFileSync(scriptPath, 'utf-8')
    }));
    
    // Each script should have at least 2 validation patterns
    for (const { path: scriptPath, content } of scriptContents) {
      const validationCount = countValidationPatterns(content);
      const relativePath = path.relative(path.join(__dirname, '..'), scriptPath);
      
      expect(validationCount).toBeGreaterThanOrEqual(2);
    }
  });
});
