#!/bin/bash
# Copyright Amazon.com, Inc. or its affiliates. All Rights Reserved.
# SPDX-License-Identifier: MIT-0
# Amazon Simple Storage Service (Amazon S3) Security Configuration Script
#
# This script provides functions to configure Amazon S3 bucket security settings
# including Block Public Access, encryption, versioning, and logging.
#
# Security Controls and Measurable Outcomes:
#   - Block Public Access: Prevents accidental public exposure (CIS AWS 2.1.5)
#   - Versioning: Enables recovery from accidental deletion or tampering
#   - Access Logging: Provides audit trail for compliance (SOC 2, ISO 27001)
#
# Implementation Priority: Priority 1 (Critical) - See docs/SECURITY.md Section 10
#
# Usage:
#   source s3-security-config.sh
#   configure_block_public_access <BUCKET_NAME>
#   configure_versioning <BUCKET_NAME>
#   configure_logging <BUCKET_NAME> <LOG_BUCKET_NAME> [LOG_PREFIX]

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
# Validate that a bucket name is provided and follows S3 naming rules
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
    log_error "Bucket names must be 3-63 characters, lowercase letters, numbers, and hyphens"
    return "$EXIT_VALIDATION_ERROR"
  fi
  
  # Cannot start with 'xn--' or end with '-s3alias'
  if [[ "$bucket_name" =~ ^xn-- ]] || [[ "$bucket_name" =~ -s3alias$ ]]; then
    log_error "Invalid bucket name: cannot start with 'xn--' or end with '-s3alias'"
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
# Configure Block Public Access for an S3 bucket
# Arguments:
#   bucket_name: The S3 bucket name
# Returns:
#   0 on success, non-zero on failure
#######################################
configure_block_public_access() {
  local bucket_name="${1:-}"
  
  log_info "Configuring Block Public Access for bucket: $bucket_name"
  
  # Validate inputs
  if ! validate_bucket_name "$bucket_name"; then
    return "$EXIT_INVALID_ARGS"
  fi
  
  # Check AWS CLI
  if ! check_aws_cli; then
    return "$EXIT_AWS_ERROR"
  fi
  
  # Enable all Block Public Access settings
  if ! aws s3api put-public-access-block \
    --bucket "$bucket_name" \
    --public-access-block-configuration \
    "BlockPublicAcls=true,IgnorePublicAcls=true,BlockPublicPolicy=true,RestrictPublicBuckets=true" \
    --no-cli-pager; then
    log_error "Failed to configure Block Public Access for bucket: $bucket_name"
    return "$EXIT_AWS_ERROR"
  fi
  
  log_success "Block Public Access configured for bucket: $bucket_name"
  return "$EXIT_SUCCESS"
}

#######################################
# Configure versioning for an S3 bucket
# Arguments:
#   bucket_name: The S3 bucket name
# Returns:
#   0 on success, non-zero on failure
#######################################
configure_versioning() {
  local bucket_name="${1:-}"
  
  log_info "Enabling versioning for bucket: $bucket_name"
  
  # Validate inputs
  if ! validate_bucket_name "$bucket_name"; then
    return "$EXIT_INVALID_ARGS"
  fi
  
  # Check AWS CLI
  if ! check_aws_cli; then
    return "$EXIT_AWS_ERROR"
  fi
  
  # Enable versioning
  if ! aws s3api put-bucket-versioning \
    --bucket "$bucket_name" \
    --versioning-configuration Status=Enabled \
    --no-cli-pager; then
    log_error "Failed to enable versioning for bucket: $bucket_name"
    return "$EXIT_AWS_ERROR"
  fi
  
  log_success "Versioning enabled for bucket: $bucket_name"
  return "$EXIT_SUCCESS"
}

#######################################
# Configure S3 access logging for a bucket
# Arguments:
#   bucket_name: The S3 bucket name to enable logging for
#   log_bucket_name: The target bucket for access logs
#   log_prefix: (Optional) Prefix for log objects, defaults to "s3-access-logs/"
# Returns:
#   0 on success, non-zero on failure
#######################################
configure_logging() {
  local bucket_name="${1:-}"
  local log_bucket_name="${2:-}"
  local log_prefix="${3:-s3-access-logs/}"
  
  log_info "Configuring access logging for bucket: $bucket_name"
  
  # Validate inputs
  if ! validate_bucket_name "$bucket_name"; then
    return "$EXIT_INVALID_ARGS"
  fi
  
  if ! validate_bucket_name "$log_bucket_name"; then
    log_error "Invalid log bucket name"
    return "$EXIT_INVALID_ARGS"
  fi
  
  # Validate log prefix (should not start with / and should end with /)
  if [[ "$log_prefix" =~ ^/ ]]; then
    log_error "Log prefix should not start with '/'"
    return "$EXIT_VALIDATION_ERROR"
  fi
  
  if [[ -n "$log_prefix" ]] && [[ ! "$log_prefix" =~ /$ ]]; then
    log_prefix="${log_prefix}/"
  fi
  
  # Check AWS CLI
  if ! check_aws_cli; then
    return "$EXIT_AWS_ERROR"
  fi
  
  # Configure logging
  local logging_config
  logging_config=$(cat <<EOF
{
  "LoggingEnabled": {
    "TargetBucket": "$log_bucket_name",
    "TargetPrefix": "$log_prefix"
  }
}
EOF
)
  
  if ! aws s3api put-bucket-logging \
    --bucket "$bucket_name" \
    --bucket-logging-status "$logging_config" \
    --no-cli-pager; then
    log_error "Failed to configure logging for bucket: $bucket_name"
    return "$EXIT_AWS_ERROR"
  fi
  
  log_success "Access logging configured for bucket: $bucket_name -> $log_bucket_name/$log_prefix"
  return "$EXIT_SUCCESS"
}

#######################################
# Configure MFA Delete for an S3 bucket
#
# NOTE: MFA Delete can only be enabled by the root account or an IAM user
# with MFA enabled. This operation requires:
# - AWS access key ID and secret access key (not session credentials)
# - A valid MFA device serial number and one-time token code
#
# Arguments:
#   bucket_name: The S3 bucket name
#   mfa_device_arn: The ARN of the MFA device (e.g., arn:aws:iam::123456789012:mfa/user)
#   mfa_token_code: The current 6-digit token code from the MFA device
# Returns:
#   0 on success, non-zero on failure
#######################################
configure_mfa_delete() {
  local bucket_name="${1:-}"
  local mfa_device_arn="${2:-}"
  local mfa_token_code="${3:-}"

  log_info "Configuring MFA Delete for bucket: $bucket_name"

  # Validate inputs
  if ! validate_bucket_name "$bucket_name"; then
    return "$EXIT_INVALID_ARGS"
  fi

  if [[ -z "$mfa_device_arn" ]]; then
    log_error "MFA device ARN is required"
    log_error "Format: arn:aws:iam::<ACCOUNT_ID>:mfa/<MFA_DEVICE_NAME>"
    return "$EXIT_INVALID_ARGS"
  fi

  # Validate MFA device ARN format
  if [[ ! "$mfa_device_arn" =~ ^arn:aws:iam::[0-9]{12}:mfa/[a-zA-Z0-9+=,.@_-]+$ ]]; then
    log_error "Invalid MFA device ARN format: $mfa_device_arn"
    return "$EXIT_VALIDATION_ERROR"
  fi

  if [[ -z "$mfa_token_code" ]]; then
    log_error "MFA token code is required"
    return "$EXIT_INVALID_ARGS"
  fi

  # Validate token code format (6 digits)
  if [[ ! "$mfa_token_code" =~ ^[0-9]{6}$ ]]; then
    log_error "MFA token code must be a 6-digit number: $mfa_token_code"
    return "$EXIT_VALIDATION_ERROR"
  fi

  # Check AWS CLI
  if ! check_aws_cli; then
    return "$EXIT_AWS_ERROR"
  fi

  # Verify versioning is enabled (required for MFA Delete)
  local versioning_status
  versioning_status=$(aws s3api get-bucket-versioning \
    --bucket "$bucket_name" \
    --query 'Status' \
    --output text \
    --no-cli-pager 2>/dev/null) || true

  if [[ "$versioning_status" != "Enabled" ]]; then
    log_error "Versioning must be enabled before configuring MFA Delete"
    log_error "Run: configure_versioning $bucket_name"
    return "$EXIT_VALIDATION_ERROR"
  fi

  # Enable MFA Delete
  # The --mfa parameter format is: "SerialNumber TokenCode" (space-separated)
  if ! aws s3api put-bucket-versioning \
    --bucket "$bucket_name" \
    --versioning-configuration "Status=Enabled,MFADelete=Enabled" \
    --mfa "$mfa_device_arn $mfa_token_code" \
    --no-cli-pager; then
    log_error "Failed to configure MFA Delete for bucket: $bucket_name"
    log_error "Verify that you are using root account credentials or IAM user credentials with MFA"
    return "$EXIT_AWS_ERROR"
  fi

  log_success "MFA Delete enabled for bucket: $bucket_name"
  return "$EXIT_SUCCESS"
}

#######################################
# Apply a bucket policy from a JSON file
# Arguments:
#   bucket_name: The S3 bucket name
#   policy_file: Path to the JSON policy file
# Returns:
#   0 on success, non-zero on failure
#######################################
apply_bucket_policy() {
  local bucket_name="${1:-}"
  local policy_file="${2:-}"
  
  log_info "Applying bucket policy to: $bucket_name"
  
  # Validate inputs
  if ! validate_bucket_name "$bucket_name"; then
    return "$EXIT_INVALID_ARGS"
  fi
  
  if [[ -z "$policy_file" ]]; then
    log_error "Policy file path is required"
    return "$EXIT_INVALID_ARGS"
  fi
  
  if [[ ! -f "$policy_file" ]]; then
    log_error "Policy file not found: $policy_file"
    return "$EXIT_VALIDATION_ERROR"
  fi
  
  # Validate JSON syntax
  if ! python3 -m json.tool "$policy_file" > /dev/null 2>&1; then
    log_error "Invalid JSON in policy file: $policy_file"
    return "$EXIT_VALIDATION_ERROR"
  fi
  
  # Check AWS CLI
  if ! check_aws_cli; then
    return "$EXIT_AWS_ERROR"
  fi
  
  # Apply the bucket policy
  if ! aws s3api put-bucket-policy \
    --bucket "$bucket_name" \
    --policy "file://$policy_file" \
    --no-cli-pager; then
    log_error "Failed to apply bucket policy to: $bucket_name"
    return "$EXIT_AWS_ERROR"
  fi
  
  log_success "Bucket policy applied to: $bucket_name"
  return "$EXIT_SUCCESS"
}

#######################################
# Configure all security settings for an S3 bucket
# Arguments:
#   bucket_name: The S3 bucket name
#   log_bucket_name: The target bucket for access logs
#   policy_file: (Optional) Path to bucket policy JSON file
#   mfa_device_arn: (Optional) MFA device ARN for MFA Delete
#   mfa_token_code: (Optional) MFA token code for MFA Delete
# Returns:
#   0 on success, non-zero on failure
#######################################
configure_all_security() {
  local bucket_name="${1:-}"
  local log_bucket_name="${2:-}"
  local policy_file="${3:-}"
  local mfa_device_arn="${4:-}"
  local mfa_token_code="${5:-}"

  log_info "Configuring all security settings for bucket: $bucket_name"

  local exit_code=0

  # Configure Block Public Access
  if ! configure_block_public_access "$bucket_name"; then
    log_error "Failed to configure Block Public Access"
    exit_code="$EXIT_AWS_ERROR"
  fi

  # Configure versioning
  if ! configure_versioning "$bucket_name"; then
    log_error "Failed to configure versioning"
    exit_code="$EXIT_AWS_ERROR"
  fi

  # Configure logging
  if ! configure_logging "$bucket_name" "$log_bucket_name"; then
    log_error "Failed to configure logging"
    exit_code="$EXIT_AWS_ERROR"
  fi

  # Apply bucket policy if provided
  if [[ -n "$policy_file" ]]; then
    if ! apply_bucket_policy "$bucket_name" "$policy_file"; then
      log_error "Failed to apply bucket policy"
      exit_code="$EXIT_AWS_ERROR"
    fi
  fi

  # Configure MFA Delete if MFA credentials provided (optional advanced security)
  if [[ -n "$mfa_device_arn" ]] && [[ -n "$mfa_token_code" ]]; then
    log_info "MFA credentials provided - configuring MFA Delete"
    if ! configure_mfa_delete "$bucket_name" "$mfa_device_arn" "$mfa_token_code"; then
      log_error "Failed to configure MFA Delete"
      exit_code="$EXIT_AWS_ERROR"
    fi
  else
    log_info "MFA Delete not configured (optional - requires MFA device ARN and token code)"
  fi

  if [[ "$exit_code" -eq 0 ]]; then
    log_success "All security settings configured for bucket: $bucket_name"
  else
    log_error "Some security configurations failed for bucket: $bucket_name"
  fi

  return "$exit_code"
}

# Main execution when script is run directly (not sourced)
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
  # Display usage if no arguments provided
  if [[ $# -eq 0 ]]; then
    echo "S3 Security Configuration Script"
    echo ""
    echo "Usage:"
    echo "  $0 block-public-access <BUCKET_NAME>"
    echo "  $0 versioning <BUCKET_NAME>"
    echo "  $0 logging <BUCKET_NAME> <LOG_BUCKET_NAME> [LOG_PREFIX]"
    echo "  $0 policy <BUCKET_NAME> <POLICY_FILE>"
    echo "  $0 mfa-delete <BUCKET_NAME> <MFA_DEVICE_ARN> <MFA_TOKEN_CODE>"
    echo "  $0 all <BUCKET_NAME> <LOG_BUCKET_NAME> [POLICY_FILE] [MFA_DEVICE_ARN] [MFA_TOKEN_CODE]"
    echo ""
    echo "Commands:"
    echo "  block-public-access  Enable S3 Block Public Access"
    echo "  versioning           Enable bucket versioning"
    echo "  logging              Configure S3 access logging"
    echo "  policy               Apply a bucket policy from file"
    echo "  mfa-delete           Enable MFA Delete (requires root/IAM with MFA)"
    echo "  all                  Configure all security settings"
    echo ""
    echo "Exit codes:"
    echo "  0 - Success"
    echo "  1 - Invalid arguments"
    echo "  2 - AWS CLI error"
    echo "  3 - Validation error"
    echo ""
    echo "Notes:"
    echo "  MFA Delete requires root account credentials or IAM user with MFA enabled."
    echo "  Session credentials (assumed roles) cannot be used for MFA Delete operations."
    exit "$EXIT_INVALID_ARGS"
  fi

  command="${1:-}"
  shift

  case "$command" in
    block-public-access)
      configure_block_public_access "$@"
      ;;
    versioning)
      configure_versioning "$@"
      ;;
    logging)
      configure_logging "$@"
      ;;
    policy)
      apply_bucket_policy "$@"
      ;;
    mfa-delete)
      configure_mfa_delete "$@"
      ;;
    all)
      configure_all_security "$@"
      ;;
    *)
      log_error "Unknown command: $command"
      exit "$EXIT_INVALID_ARGS"
      ;;
  esac
fi
