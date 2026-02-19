/**
 * Property-Based Tests for Amazon Simple Storage Service (Amazon S3) Upload Security
 *
 * Feature: oumi-blog-security-remediation
 * Property 2: Amazon S3 Upload Security
 *
 * **Validates: Requirements 3.6**
 *
 * Verifies that S3 upload commands exist in scripts and that the project
 * relies on S3 default encryption rather than explicit encryption flags.
 */

import fc from 'fast-check';
import fs from 'fs';
import path from 'path';
import { fileURLToPath } from 'url';

const __filename = fileURLToPath(import.meta.url);
const __dirname = path.dirname(__filename);

// Paths to directories containing S3 upload commands
const SCRIPTS_DIR = path.join(__dirname, '..', 'scripts');
const SECURITY_DIR = path.join(__dirname, '..', 'security');

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
 * Patterns that identify S3 upload commands
 * Note: We look for commands that actually upload data, not read-only commands
 */
const S3_UPLOAD_PATTERNS = [
  /aws\s+s3\s+cp\s+[^|]+\s+s3:\/\//,  // aws s3 cp ... s3:// (uploading to S3)
  /aws\s+s3\s+sync\s+[^s][^3][^:]/,   // aws s3 sync (not starting with s3:)
  /aws\s+s3\s+mv\s+[^|]+\s+s3:\/\//,  // aws s3 mv ... s3:// (moving to S3)
  /aws\s+s3api\s+put-object/,          // aws s3api put-object
];

/**
 * Patterns that indicate explicit KMS encryption flags (should NOT be present)
 */
const KMS_ENCRYPTION_PATTERNS = [
  /--sse\s+aws:kms/,                    // --sse aws:kms
  /--sse\s+"aws:kms"/,                  // --sse "aws:kms"
  /--sse\s+'aws:kms'/,                  // --sse 'aws:kms'
  /--sse-kms-key-id/,                   // --sse-kms-key-id (implies KMS encryption)
  /--server-side-encryption\s+aws:kms/, // Full form
];

/**
 * Check if content contains S3 upload commands
 */
function containsS3UploadCommands(content) {
  return S3_UPLOAD_PATTERNS.some(pattern => pattern.test(content));
}

/**
 * Check if content has explicit KMS encryption parameters (should not be present)
 */
function hasKmsEncryptionParameters(content) {
  return KMS_ENCRYPTION_PATTERNS.some(pattern => pattern.test(content));
}


/**
 * Extract S3 upload command lines from content
 */
function extractS3UploadLines(content) {
  const lines = content.split('\n');
  const uploadLines = [];
  
  for (let i = 0; i < lines.length; i++) {
    const line = lines[i];
    
    // Check if this line contains an S3 upload command
    if (S3_UPLOAD_PATTERNS.some(pattern => pattern.test(line))) {
      // Collect the full command (may span multiple lines with \)
      let fullCommand = line;
      let j = i;
      
      while (fullCommand.trimEnd().endsWith('\\') && j < lines.length - 1) {
        j++;
        fullCommand += '\n' + lines[j];
      }
      
      uploadLines.push({
        lineNumber: i + 1,
        command: fullCommand
      });
    }
  }
  
  return uploadLines;
}

/**
 * Check if a specific S3 command has explicit KMS encryption flags
 */
function commandHasKmsEncryption(command) {
  return KMS_ENCRYPTION_PATTERNS.some(pattern => pattern.test(command));
}

/**
 * Analyze a script for S3 upload commands
 */
function analyzeScriptUploads(scriptPath) {
  const content = fs.readFileSync(scriptPath, 'utf-8');
  const uploadCommands = extractS3UploadLines(content);

  return {
    scriptPath,
    hasUploadCommands: uploadCommands.length > 0,
    commands: uploadCommands.map(cmd => ({
      ...cmd,
      hasKmsFlags: commandHasKmsEncryption(cmd.command)
    })),
    hasKmsContent: hasKmsEncryptionParameters(content)
  };
}

describe('Feature: oumi-blog-security-remediation, Property 2: S3 Upload Security', () => {

  // Get all shell scripts
  const workflowScripts = findShellScripts(SCRIPTS_DIR);
  const securityScripts = findShellScripts(SECURITY_DIR);
  const allScripts = [...workflowScripts, ...securityScripts];

  test('Scripts directory should contain shell scripts', () => {
    expect(workflowScripts.length).toBeGreaterThan(0);
  });

  // Test that scripts do NOT contain explicit KMS encryption flags (relying on S3 default encryption)
  allScripts.forEach(scriptPath => {
    const relativePath = path.relative(path.join(__dirname, '..'), scriptPath);

    test(`Script ${relativePath} should not contain explicit KMS encryption flags`, () => {
      const content = fs.readFileSync(scriptPath, 'utf-8');
      expect(hasKmsEncryptionParameters(content)).toBe(false);
    });
  });

  // Specifically test upload-to-s3.sh relies on S3 default encryption
  test('upload-to-s3.sh should rely on S3 default encryption (no KMS flags)', () => {
    const uploadScript = path.join(SCRIPTS_DIR, 'upload-to-s3.sh');

    if (fs.existsSync(uploadScript)) {
      const content = fs.readFileSync(uploadScript, 'utf-8');

      // Should contain S3 upload commands
      expect(containsS3UploadCommands(content)).toBe(true);

      // Should NOT have KMS encryption parameters
      expect(hasKmsEncryptionParameters(content)).toBe(false);
    }
  });

  // Property-based test: S3 upload patterns correctly identify upload commands
  test('Property: S3 upload patterns correctly identify upload commands', () => {
    const uploadCommandArbitrary = fc.oneof(
      fc.constantFrom(
        'aws s3 cp file.txt s3://bucket/key',
        'aws s3 sync ./local s3://bucket/',
        'aws s3 mv source.txt s3://bucket/dest.txt',
        'aws s3api put-object --bucket mybucket --key mykey'
      )
    );

    fc.assert(
      fc.property(uploadCommandArbitrary, (command) => {
        return containsS3UploadCommands(command);
      }),
      { numRuns: 100 }
    );
  });

  // Property-based test: Non-upload S3 commands are not flagged
  test('Property: Non-upload S3 commands are not flagged as uploads', () => {
    const nonUploadCommandArbitrary = fc.constantFrom(
      'aws s3 ls s3://bucket/',
      'aws s3 rb s3://bucket',
      'aws s3 mb s3://new-bucket',
      'aws s3api get-object --bucket mybucket --key mykey output.txt',
      'aws s3api list-objects --bucket mybucket',
      'aws s3api head-object --bucket mybucket --key mykey'
    );

    fc.assert(
      fc.property(nonUploadCommandArbitrary, (command) => {
        return !containsS3UploadCommands(command);
      }),
      { numRuns: 100 }
    );
  });

  // Property-based test: Commands without KMS flags are correctly identified
  test('Property: Commands without KMS flags are correctly identified', () => {
    const noKmsCommandArbitrary = fc.constantFrom(
      'aws s3 cp file.txt s3://bucket/key',
      'aws s3 sync ./local s3://bucket/prefix',
      'aws s3 mv file.txt s3://bucket/key',
      'aws s3api put-object --bucket mybucket --key mykey --body file.txt'
    );

    fc.assert(
      fc.property(noKmsCommandArbitrary, (command) => {
        return !hasKmsEncryptionParameters(command);
      }),
      { numRuns: 100 }
    );
  });
});
