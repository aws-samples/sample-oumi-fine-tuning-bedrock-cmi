#!/bin/bash
# Copyright Amazon.com, Inc. or its affiliates. All Rights Reserved.
# SPDX-License-Identifier: MIT-0
# AWS Key Management Service (AWS KMS) Encryption Setup Script
#
# This script creates or configures AWS KMS keys and applies encryption
# configuration to Amazon S3 buckets for the Oumi fine-tuning workflow.
#
# Requirements: 4.3, 5.1, 5.2, 5.3
#
# Usage:
#   ./encryption-setup.sh create-key <KEY_ALIAS> [DESCRIPTION]
#   ./encryption-setup.sh configure-bucket <BUCKET_NAME> <KMS_KEY_ID>
#   ./encryption-setup.sh setup <BUCKET_NAME> <KEY_ALIAS> [DESCRIPTION]

set -euo pipefail

# Exit codes
readonly EXIT_SUCCESS=0
readonly EXIT_INVALID_ARGS=1
readonly EXIT_AWS_ERROR=2
readonly EXIT_VALIDATION_ERROR=3

# Color codes for output
readonly RED='\033[0;31m'
readonly GREEN='\033[0;32m'
readonly YELLOW='\033[1;33m'
readonly NC='\033[0m' # No Color

#######################################
# Log an error message to stderr
# Arguments:
#   Message to log
#######################################
log_error() {
  echo -e "${RED}[ERROR]${NC} $1" >&2
}

#######################################
# Log a success message
# Arguments:
#   Message to log
#######################################
log_success() {
  echo -e "${GREEN}[SUCCESS]${NC} $1"
}

#######################################
# Log an info message
# Arguments:
#   Message to log
#######################################
log_info() {
  echo -e "${YELLOW}[INFO]${NC} $1"
}

#######################################
# Validate that a bucket name follows S3 naming rules
# Arguments:
#   bucket_name: The S3 bucket name to validate
# Returns:
#   0 if valid, non-zero otherwise
#######################################
validate_bucket_name() {
  local bucket_name="${1:-}"
  
  if [[ -z "$bucket_name" ]]; then
    log_error "Bucket name is required"
    return "$EXIT_INVALID_ARGS"
  fi
  
  # S3 bucket naming rules: 3-63 characters, lowercase, numbers, hyphens
  if [[ ! "$bucket_name" =~ ^[a-z0-9][a-z0-9.-]{1,61}[a-z0-9]$ ]]; then
    log_error "Invalid bucket name format: $bucket_name"
    return "$EXIT_VALIDATION_ERROR"
  fi
  
  return "$EXIT_SUCCESS"
}

#######################################
# Validate KMS key alias format
# Arguments:
#   key_alias: The KMS key alias to validate
# Returns:
#   0 if valid, non-zero otherwise
#######################################
validate_key_alias() {
  local key_alias="${1:-}"
  
  if [[ -z "$key_alias" ]]; then
    log_error "Key alias is required"
    return "$EXIT_INVALID_ARGS"
  fi
  
  # Remove 'alias/' prefix if present for validation
  local alias_name="${key_alias#alias/}"
  
  # KMS alias naming: alphanumeric, forward slashes, underscores, hyphens
  # Cannot start with 'aws/' (reserved for AWS managed keys)
  if [[ ! "$alias_name" =~ ^[a-zA-Z0-9/_-]+$ ]]; then
    log_error "Invalid key alias format: $key_alias"
    log_error "Alias must contain only alphanumeric characters, forward slashes, underscores, and hyphens"
    return "$EXIT_VALIDATION_ERROR"
  fi
  
  if [[ "$alias_name" =~ ^aws/ ]]; then
    log_error "Key alias cannot start with 'aws/' (reserved for AWS managed keys)"
    return "$EXIT_VALIDATION_ERROR"
  fi
  
  return "$EXIT_SUCCESS"
}

#######################################
# Validate that a KMS key ID is provided and has valid format
# Arguments:
#   kms_key_id: The KMS key ID or ARN to validate
# Returns:
#   0 if valid, non-zero otherwise
#######################################
validate_kms_key_id() {
  local kms_key_id="${1:-}"
  
  if [[ -z "$kms_key_id" ]]; then
    log_error "KMS key ID is required"
    return "$EXIT_INVALID_ARGS"
  fi
  
  # KMS key can be key ID, key ARN, alias name, or alias ARN
  local key_id_pattern='^[a-f0-9]{8}-[a-f0-9]{4}-[a-f0-9]{4}-[a-f0-9]{4}-[a-f0-9]{12}$'
  local key_arn_pattern='^arn:aws:kms:[a-z0-9-]+:[0-9]{12}:key/[a-f0-9-]+$'
  local alias_pattern='^alias/[a-zA-Z0-9/_-]+$'
  local alias_arn_pattern='^arn:aws:kms:[a-z0-9-]+:[0-9]{12}:alias/[a-zA-Z0-9/_-]+$'
  
  if [[ ! "$kms_key_id" =~ $key_id_pattern ]] && \
     [[ ! "$kms_key_id" =~ $key_arn_pattern ]] && \
     [[ ! "$kms_key_id" =~ $alias_pattern ]] && \
     [[ ! "$kms_key_id" =~ $alias_arn_pattern ]]; then
    log_error "Invalid KMS key ID format: $kms_key_id"
    return "$EXIT_VALIDATION_ERROR"
  fi
  
  return "$EXIT_SUCCESS"
}

#######################################
# Check if AWS CLI is available and configured
# Returns:
#   0 if AWS CLI is available, non-zero otherwise
#######################################
check_aws_cli() {
  if ! command -v aws &> /dev/null; then
    log_error "AWS CLI is not installed or not in PATH"
    return "$EXIT_AWS_ERROR"
  fi
  
  # Verify AWS credentials are configured
  if ! aws sts get-caller-identity --no-cli-pager &> /dev/null; then
    log_error "AWS credentials are not configured or invalid"
    return "$EXIT_AWS_ERROR"
  fi
  
  return "$EXIT_SUCCESS"
}

#######################################
# Get the current AWS account ID
# Returns:
#   The AWS account ID via stdout
#######################################
get_account_id() {
  aws sts get-caller-identity --query 'Account' --output text --no-cli-pager
}

#######################################
# Get the current AWS region
# Returns:
#   The AWS region via stdout
#######################################
get_region() {
  aws configure get region --no-cli-pager || echo "us-east-1"
}

#######################################
# Create a KMS key with appropriate policy for S3 encryption
# Arguments:
#   key_alias: The alias for the KMS key
#   description: (Optional) Description for the key
# Returns:
#   0 on success, non-zero on failure
#   Outputs the key ID on success
#######################################
create_kms_key() {
  local key_alias="${1:-}"
  local description="${2:-KMS key for S3 bucket encryption}"
  
  log_info "Creating KMS key with alias: $key_alias"
  
  # Validate inputs
  if ! validate_key_alias "$key_alias"; then
    return "$EXIT_INVALID_ARGS"
  fi
  
  # Check AWS CLI
  if ! check_aws_cli; then
    return "$EXIT_AWS_ERROR"
  fi
  
  local account_id
  local region
  account_id=$(get_account_id)
  region=$(get_region)
  
  # Prepend 'alias/' prefix if not present
  if [[ ! "$key_alias" =~ ^alias/ ]]; then
    key_alias="alias/$key_alias"
  fi

  # Check if alias already exists
  if aws kms describe-key --key-id "$key_alias" --no-cli-pager &> /dev/null; then
    log_info "Key alias already exists: $key_alias"
    local existing_key_id
    existing_key_id=$(aws kms describe-key --key-id "$key_alias" --query 'KeyMetadata.KeyId' --output text --no-cli-pager)
    log_success "Using existing KMS key: $existing_key_id"
    echo "$existing_key_id"
    return "$EXIT_SUCCESS"
  fi
  
  # Create key policy allowing S3 service to use the key
  local key_policy
  key_policy=$(cat <<EOF
{
  "Version": "2012-10-17",
  "Id": "key-policy-s3-encryption",
  "Statement": [
    {
      "Sid": "Enable IAM User Permissions",
      "Effect": "Allow",
      "Principal": {
        "AWS": "arn:aws:iam::$account_id:root"
      },
      "Action": "kms:*",
      "Resource": "*"
    },
    {
      "Sid": "Allow S3 Service",
      "Effect": "Allow",
      "Principal": {
        "Service": "s3.amazonaws.com"
      },
      "Action": [
        "kms:Encrypt",
        "kms:Decrypt",
        "kms:ReEncrypt*",
        "kms:GenerateDataKey*",
        "kms:DescribeKey"
      ],
      "Resource": "*",
      "Condition": {
        "StringEquals": {
          "aws:SourceAccount": "$account_id"
        }
      }
    },
    {
      "Sid": "Allow CloudTrail Service",
      "Effect": "Allow",
      "Principal": {
        "Service": "cloudtrail.amazonaws.com"
      },
      "Action": [
        "kms:GenerateDataKey*",
        "kms:DescribeKey"
      ],
      "Resource": "*",
      "Condition": {
        "StringEquals": {
          "aws:SourceAccount": "$account_id"
        },
        "StringLike": {
          "kms:EncryptionContext:aws:cloudtrail:arn": "arn:aws:cloudtrail:*:$account_id:trail/*"
        }
      }
    }
  ]
}
EOF
)
  
  # Create the KMS key
  local key_id
  key_id=$(aws kms create-key \
    --description "$description" \
    --key-usage ENCRYPT_DECRYPT \
    --key-spec SYMMETRIC_DEFAULT \
    --policy "$key_policy" \
    --query 'KeyMetadata.KeyId' \
    --output text \
    --no-cli-pager)
  
  if [[ -z "$key_id" ]]; then
    log_error "Failed to create KMS key"
    return "$EXIT_AWS_ERROR"
  fi
  
  log_info "Created KMS key: $key_id"
  
  # Create alias for the key
  if ! aws kms create-alias \
    --alias-name "$key_alias" \
    --target-key-id "$key_id" \
    --no-cli-pager; then
    log_error "Failed to create alias for KMS key"
    return "$EXIT_AWS_ERROR"
  fi
  
  # Enable key rotation
  log_info "Enabling automatic key rotation"
  if ! aws kms enable-key-rotation \
    --key-id "$key_id" \
    --no-cli-pager; then
    log_error "Failed to enable key rotation"
    return "$EXIT_AWS_ERROR"
  fi
  
  log_success "KMS key created: $key_id with alias: $key_alias"
  echo "$key_id"
  return "$EXIT_SUCCESS"
}

#######################################
# Configure S3 bucket encryption with KMS
# Arguments:
#   bucket_name: The S3 bucket name
#   kms_key_id: The KMS key ID, ARN, or alias
# Returns:
#   0 on success, non-zero on failure
#######################################
configure_bucket_encryption() {
  local bucket_name="${1:-}"
  local kms_key_id="${2:-}"
  
  log_info "Configuring encryption for bucket: $bucket_name"
  
  # Validate inputs
  if ! validate_bucket_name "$bucket_name"; then
    return "$EXIT_INVALID_ARGS"
  fi
  
  if ! validate_kms_key_id "$kms_key_id"; then
    return "$EXIT_INVALID_ARGS"
  fi
  
  # Check AWS CLI
  if ! check_aws_cli; then
    return "$EXIT_AWS_ERROR"
  fi
  
  # Verify the KMS key exists and is accessible
  if ! aws kms describe-key --key-id "$kms_key_id" --no-cli-pager &> /dev/null; then
    log_error "KMS key not found or not accessible: $kms_key_id"
    return "$EXIT_AWS_ERROR"
  fi
  
  # Configure SSE-KMS encryption with bucket key enabled
  local encryption_config
  encryption_config=$(cat <<EOF
{
  "Rules": [
    {
      "ApplyServerSideEncryptionByDefault": {
        "SSEAlgorithm": "aws:kms",
        "KMSMasterKeyID": "$kms_key_id"
      },
      "BucketKeyEnabled": true
    }
  ]
}
EOF
)
  
  if ! aws s3api put-bucket-encryption \
    --bucket "$bucket_name" \
    --server-side-encryption-configuration "$encryption_config" \
    --no-cli-pager; then
    log_error "Failed to configure encryption for bucket: $bucket_name"
    return "$EXIT_AWS_ERROR"
  fi
  
  log_success "SSE-KMS encryption configured for bucket: $bucket_name"
  return "$EXIT_SUCCESS"
}

#######################################
# Full encryption setup: create KMS key and configure bucket
# Arguments:
#   bucket_name: The S3 bucket name
#   key_alias: The alias for the KMS key
#   description: (Optional) Description for the key
# Returns:
#   0 on success, non-zero on failure
#######################################
setup_encryption() {
  local bucket_name="${1:-}"
  local key_alias="${2:-}"
  local description="${3:-KMS key for $bucket_name encryption}"
  
  log_info "Setting up encryption for bucket: $bucket_name"
  
  # Validate inputs
  if ! validate_bucket_name "$bucket_name"; then
    return "$EXIT_INVALID_ARGS"
  fi
  
  if ! validate_key_alias "$key_alias"; then
    return "$EXIT_INVALID_ARGS"
  fi
  
  # Create or get KMS key
  local key_id
  key_id=$(create_kms_key "$key_alias" "$description")
  local create_result=$?
  
  if [[ $create_result -ne 0 ]]; then
    log_error "Failed to create or retrieve KMS key"
    return "$EXIT_AWS_ERROR"
  fi
  
  # Prepend 'alias/' prefix to key_alias for bucket configuration API call
  if [[ ! "$key_alias" =~ ^alias/ ]]; then
    key_alias="alias/$key_alias"
  fi
  
  # Configure bucket encryption using the alias
  if ! configure_bucket_encryption "$bucket_name" "$key_alias"; then
    log_error "Failed to configure bucket encryption"
    return "$EXIT_AWS_ERROR"
  fi
  
  log_success "Encryption setup complete for bucket: $bucket_name with key: $key_alias"
  return "$EXIT_SUCCESS"
}

#######################################
# Verify encryption configuration for a bucket
# Arguments:
#   bucket_name: The S3 bucket name
# Returns:
#   0 if encryption is properly configured, non-zero otherwise
#######################################
verify_encryption() {
  local bucket_name="${1:-}"
  
  log_info "Verifying encryption for bucket: $bucket_name"
  
  # Validate inputs
  if ! validate_bucket_name "$bucket_name"; then
    return "$EXIT_INVALID_ARGS"
  fi
  
  # Check AWS CLI
  if ! check_aws_cli; then
    return "$EXIT_AWS_ERROR"
  fi
  
  # Get encryption configuration
  local encryption_config
  if ! encryption_config=$(aws s3api get-bucket-encryption \
    --bucket "$bucket_name" \
    --query 'ServerSideEncryptionConfiguration.Rules[0]' \
    --output json \
    --no-cli-pager 2>/dev/null); then
    log_error "No encryption configuration found for bucket: $bucket_name"
    return "$EXIT_VALIDATION_ERROR"
  fi
  
  # Verify SSE-KMS is configured
  local sse_algorithm
  sse_algorithm=$(echo "$encryption_config" | python3 -c "import sys, json; print(json.load(sys.stdin).get('ApplyServerSideEncryptionByDefault', {}).get('SSEAlgorithm', ''))")
  
  if [[ "$sse_algorithm" != "aws:kms" ]]; then
    log_error "Bucket is not configured with SSE-KMS encryption"
    return "$EXIT_VALIDATION_ERROR"
  fi
  
  # Verify bucket key is enabled
  local bucket_key_enabled
  bucket_key_enabled=$(echo "$encryption_config" | python3 -c "import sys, json; print(json.load(sys.stdin).get('BucketKeyEnabled', False))")
  
  if [[ "$bucket_key_enabled" != "True" ]]; then
    log_info "Warning: Bucket key is not enabled (recommended for cost optimization)"
  fi
  
  local kms_key
  kms_key=$(echo "$encryption_config" | python3 -c "import sys, json; print(json.load(sys.stdin).get('ApplyServerSideEncryptionByDefault', {}).get('KMSMasterKeyID', 'N/A'))")
  
  log_success "Encryption verified for bucket: $bucket_name"
  log_info "  SSE Algorithm: $sse_algorithm"
  log_info "  KMS Key: $kms_key"
  log_info "  Bucket Key Enabled: $bucket_key_enabled"
  
  return "$EXIT_SUCCESS"
}

# Display usage information
show_usage() {
  echo "Encryption Setup Script"
  echo ""
  echo "Usage:"
  echo "  $0 create-key <KEY_ALIAS> [DESCRIPTION]"
  echo "  $0 configure-bucket <BUCKET_NAME> <KMS_KEY_ID>"
  echo "  $0 setup <BUCKET_NAME> <KEY_ALIAS> [DESCRIPTION]"
  echo "  $0 verify <BUCKET_NAME>"
  echo ""
  echo "Commands:"
  echo "  create-key        Create a new KMS key with the specified alias"
  echo "  configure-bucket  Configure S3 bucket encryption with existing KMS key"
  echo "  setup             Create KMS key and configure bucket encryption"
  echo "  verify            Verify encryption configuration for a bucket"
  echo ""
  echo "Arguments:"
  echo "  KEY_ALIAS     KMS key alias (e.g., 'oumi-encryption-key' or 'alias/oumi-encryption-key')"
  echo "  KMS_KEY_ID    KMS key ID, ARN, or alias"
  echo "  BUCKET_NAME   S3 bucket name"
  echo "  DESCRIPTION   Optional description for the KMS key"
  echo ""
  echo "Exit codes:"
  echo "  0 - Success"
  echo "  1 - Invalid arguments"
  echo "  2 - AWS CLI error"
  echo "  3 - Validation error"
}

# Main execution
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
  if [[ $# -eq 0 ]]; then
    show_usage
    exit "$EXIT_INVALID_ARGS"
  fi
  
  command="${1:-}"
  shift
  
  case "$command" in
    create-key)
      create_kms_key "$@"
      ;;
    configure-bucket)
      configure_bucket_encryption "$@"
      ;;
    setup)
      setup_encryption "$@"
      ;;
    verify)
      verify_encryption "$@"
      ;;
    -h|--help|help)
      show_usage
      exit "$EXIT_SUCCESS"
      ;;
    *)
      log_error "Unknown command: $command"
      show_usage
      exit "$EXIT_INVALID_ARGS"
      ;;
  esac
fi
