#!/bin/bash
# Copyright Amazon.com, Inc. or its affiliates. All Rights Reserved.
# SPDX-License-Identifier: MIT-0
# Validate Deployment Script
# 
# This script validates the security configuration of a deployment including:
# - S3 bucket security configuration
# - IAM role permissions
# - Model import status
#
# Requirements: 5.1, 5.2, 5.3
#
# Usage:
#   ./validate-deployment.sh --bucket <BUCKET_NAME> [OPTIONS]
#
# Options:
#   --bucket          S3 bucket name to validate (required)
#   --role-arn        IAM role ARN to validate (optional)
#   --model-id        Bedrock model ID to validate (optional)
#   --verbose         Show detailed output
#   -h, --help        Show this help message

set -euo pipefail

# Exit codes
readonly EXIT_SUCCESS=0
readonly EXIT_INVALID_ARGS=1
readonly EXIT_AWS_ERROR=2
readonly EXIT_VALIDATION_ERROR=3
readonly EXIT_SECURITY_FAILURE=4

# Color codes for output
readonly RED='\033[0;31m'
readonly GREEN='\033[0;32m'
readonly YELLOW='\033[1;33m'
readonly BLUE='\033[0;34m'
readonly NC='\033[0m' # No Color

# Default values
BUCKET_NAME=""
ROLE_ARN=""
MODEL_ID=""
VERBOSE=false

# Validation results
VALIDATION_PASSED=0
VALIDATION_FAILED=0
VALIDATION_WARNINGS=0

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
  echo -e "${GREEN}[PASS]${NC} $1"
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
# Log a failure message
# Arguments:
#   Message to log
#######################################
log_fail() {
  echo -e "${RED}[FAIL]${NC} $1"
}

#######################################
# Log a warning message
# Arguments:
#   Message to log
#######################################
log_warn() {
  echo -e "${YELLOW}[WARN]${NC} $1"
}

#######################################
# Log a verbose message (only if verbose mode is enabled)
# Arguments:
#   Message to log
#######################################
log_verbose() {
  if [[ "$VERBOSE" == "true" ]]; then
    echo -e "${BLUE}[DEBUG]${NC} $1"
  fi
}

#######################################
# Display usage information
#######################################
show_usage() {
  echo "Validate Deployment Script"
  echo ""
  echo "Usage:"
  echo "  $0 --bucket <BUCKET_NAME> [OPTIONS]"
  echo ""
  echo "Options:"
  echo "  --bucket          S3 bucket name to validate (required)"
  echo "  --role-arn        IAM role ARN to validate (optional)"
  echo "  --model-id        Bedrock model ID to validate (optional)"
  echo "  --verbose         Show detailed output"
  echo "  -h, --help        Show this help message"
  echo ""
  echo "Examples:"
  echo "  $0 --bucket my-model-bucket"
  echo "  $0 --bucket my-model-bucket --role-arn arn:aws:iam::123456789012:role/BedrockRole"
  echo "  $0 --bucket my-model-bucket --model-id my-imported-model --verbose"
  echo ""
  echo "Exit codes:"
  echo "  0 - All validations passed"
  echo "  1 - Invalid arguments"
  echo "  2 - AWS CLI error"
  echo "  3 - Validation error"
  echo "  4 - Security validation failed"
}

#######################################
# Parse command line arguments
# Arguments:
#   All command line arguments
# Returns:
#   0 on success, non-zero on failure
#######################################
parse_arguments() {
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --bucket)
        if [[ -z "${2:-}" ]]; then
          log_error "Bucket argument requires a value"
          return "$EXIT_INVALID_ARGS"
        fi
        BUCKET_NAME="$2"
        shift 2
        ;;
      --role-arn)
        if [[ -z "${2:-}" ]]; then
          log_error "Role ARN argument requires a value"
          return "$EXIT_INVALID_ARGS"
        fi
        ROLE_ARN="$2"
        shift 2
        ;;
      --model-id)
        if [[ -z "${2:-}" ]]; then
          log_error "Model ID argument requires a value"
          return "$EXIT_INVALID_ARGS"
        fi
        MODEL_ID="$2"
        shift 2
        ;;
      --verbose)
        VERBOSE=true
        shift
        ;;
      -h|--help)
        show_usage
        exit "$EXIT_SUCCESS"
        ;;
      *)
        log_error "Unknown option: $1"
        show_usage
        return "$EXIT_INVALID_ARGS"
        ;;
    esac
  done
  
  return "$EXIT_SUCCESS"
}

#######################################
# Validate bucket name format
# Arguments:
#   bucket_name: S3 bucket name to validate
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
# Validate IAM role ARN format
# Arguments:
#   role_arn: IAM role ARN to validate
# Returns:
#   0 if valid, non-zero otherwise
#######################################
validate_role_arn_format() {
  local role_arn="${1:-}"
  
  if [[ -z "$role_arn" ]]; then
    return "$EXIT_SUCCESS"  # Optional parameter
  fi
  
  # IAM role ARN format
  if [[ ! "$role_arn" =~ ^arn:aws:iam::[0-9]{12}:role/.+ ]]; then
    log_error "Invalid IAM role ARN format: $role_arn"
    log_error "Expected format: arn:aws:iam::ACCOUNT_ID:role/ROLE_NAME"
    return "$EXIT_VALIDATION_ERROR"
  fi
  
  return "$EXIT_SUCCESS"
}

#######################################
# Validate model ID format
# Arguments:
#   model_id: Bedrock model ID to validate
# Returns:
#   0 if valid, non-zero otherwise
#######################################
validate_model_id_format() {
  local model_id="${1:-}"
  
  if [[ -z "$model_id" ]]; then
    return "$EXIT_SUCCESS"  # Optional parameter
  fi
  
  # Model ID: alphanumeric, hyphens, underscores, colons, periods
  if [[ ! "$model_id" =~ ^[a-zA-Z0-9][a-zA-Z0-9_:.-]*$ ]]; then
    log_error "Invalid model ID format: $model_id"
    return "$EXIT_VALIDATION_ERROR"
  fi
  
  return "$EXIT_SUCCESS"
}

#######################################
# Check AWS CLI is available and configured
# Returns:
#   0 if available, non-zero otherwise
#######################################
check_aws_cli() {
  if ! command -v aws &> /dev/null; then
    log_error "AWS CLI is not installed or not in PATH"
    return "$EXIT_AWS_ERROR"
  fi
  
  if ! aws sts get-caller-identity --no-cli-pager &> /dev/null; then
    log_error "AWS credentials are not configured or invalid"
    return "$EXIT_AWS_ERROR"
  fi
  
  return "$EXIT_SUCCESS"
}

#######################################
# Record a passed validation
# Arguments:
#   check_name: Name of the check that passed
#######################################
record_pass() {
  local check_name="${1:-}"
  log_success "$check_name"
  ((VALIDATION_PASSED++))
}

#######################################
# Record a failed validation
# Arguments:
#   check_name: Name of the check that failed
#######################################
record_fail() {
  local check_name="${1:-}"
  log_fail "$check_name"
  ((VALIDATION_FAILED++))
}

#######################################
# Record a warning
# Arguments:
#   check_name: Name of the check with warning
#######################################
record_warn() {
  local check_name="${1:-}"
  log_warn "$check_name"
  ((VALIDATION_WARNINGS++))
}

#######################################
# Validate S3 Block Public Access configuration
# Arguments:
#   bucket_name: S3 bucket name
# Returns:
#   0 if properly configured, non-zero otherwise
#######################################
validate_block_public_access() {
  local bucket_name="${1:-}"
  
  log_info "Checking Block Public Access for bucket: $bucket_name"
  
  local bpa_config
  if ! bpa_config=$(aws s3api get-public-access-block \
    --bucket "$bucket_name" \
    --query 'PublicAccessBlockConfiguration' \
    --output json \
    --no-cli-pager 2>/dev/null); then
    record_fail "Block Public Access: Not configured"
    return "$EXIT_SECURITY_FAILURE"
  fi
  
  log_verbose "Block Public Access config: $bpa_config"
  
  # Check all four settings
  local block_public_acls
  local ignore_public_acls
  local block_public_policy
  local restrict_public_buckets
  
  block_public_acls=$(echo "$bpa_config" | python3 -c "import sys, json; print(json.load(sys.stdin).get('BlockPublicAcls', False))" 2>/dev/null || echo "false")
  ignore_public_acls=$(echo "$bpa_config" | python3 -c "import sys, json; print(json.load(sys.stdin).get('IgnorePublicAcls', False))" 2>/dev/null || echo "false")
  block_public_policy=$(echo "$bpa_config" | python3 -c "import sys, json; print(json.load(sys.stdin).get('BlockPublicPolicy', False))" 2>/dev/null || echo "false")
  restrict_public_buckets=$(echo "$bpa_config" | python3 -c "import sys, json; print(json.load(sys.stdin).get('RestrictPublicBuckets', False))" 2>/dev/null || echo "false")
  
  local all_enabled=true
  
  if [[ "$block_public_acls" != "True" ]]; then
    log_verbose "BlockPublicAcls is not enabled"
    all_enabled=false
  fi
  
  if [[ "$ignore_public_acls" != "True" ]]; then
    log_verbose "IgnorePublicAcls is not enabled"
    all_enabled=false
  fi
  
  if [[ "$block_public_policy" != "True" ]]; then
    log_verbose "BlockPublicPolicy is not enabled"
    all_enabled=false
  fi
  
  if [[ "$restrict_public_buckets" != "True" ]]; then
    log_verbose "RestrictPublicBuckets is not enabled"
    all_enabled=false
  fi
  
  if [[ "$all_enabled" == "true" ]]; then
    record_pass "Block Public Access: All settings enabled"
    return "$EXIT_SUCCESS"
  else
    record_fail "Block Public Access: Not all settings enabled"
    return "$EXIT_SECURITY_FAILURE"
  fi
}

#######################################
# Validate S3 bucket encryption configuration
# Arguments:
#   bucket_name: S3 bucket name
# Returns:
#   0 if properly configured, non-zero otherwise
#######################################
validate_bucket_encryption() {
  local bucket_name="${1:-}"
  
  log_info "Checking encryption for bucket: $bucket_name"
  
  local encryption_config
  if ! encryption_config=$(aws s3api get-bucket-encryption \
    --bucket "$bucket_name" \
    --query 'ServerSideEncryptionConfiguration.Rules[0].ApplyServerSideEncryptionByDefault' \
    --output json \
    --no-cli-pager 2>/dev/null); then
    record_fail "Bucket Encryption: Not configured"
    return "$EXIT_SECURITY_FAILURE"
  fi
  
  log_verbose "Encryption config: $encryption_config"
  
  local sse_algorithm
  sse_algorithm=$(echo "$encryption_config" | python3 -c "import sys, json; print(json.load(sys.stdin).get('SSEAlgorithm', ''))" 2>/dev/null || echo "")
  
  if [[ "$sse_algorithm" == "AES256" ]]; then
    record_pass "Bucket Encryption: SSE-S3 (AES256) enabled"
    return "$EXIT_SUCCESS"
  elif [[ "$sse_algorithm" == "aws:kms" ]]; then
    record_pass "Bucket Encryption: SSE-KMS enabled"
    return "$EXIT_SUCCESS"
  else
    record_fail "Bucket Encryption: Unknown or no encryption ($sse_algorithm)"
    return "$EXIT_SECURITY_FAILURE"
  fi
}

#######################################
# Validate S3 bucket versioning
# Arguments:
#   bucket_name: S3 bucket name
# Returns:
#   0 if enabled, non-zero otherwise
#######################################
validate_bucket_versioning() {
  local bucket_name="${1:-}"
  
  log_info "Checking versioning for bucket: $bucket_name"
  
  local versioning_status
  versioning_status=$(aws s3api get-bucket-versioning \
    --bucket "$bucket_name" \
    --query 'Status' \
    --output text \
    --no-cli-pager 2>/dev/null || echo "None")
  
  log_verbose "Versioning status: $versioning_status"
  
  if [[ "$versioning_status" == "Enabled" ]]; then
    record_pass "Bucket Versioning: Enabled"
    return "$EXIT_SUCCESS"
  elif [[ "$versioning_status" == "Suspended" ]]; then
    record_warn "Bucket Versioning: Suspended (should be Enabled)"
    return "$EXIT_SUCCESS"
  else
    record_fail "Bucket Versioning: Not enabled"
    return "$EXIT_SECURITY_FAILURE"
  fi
}

#######################################
# Validate S3 bucket logging
# Arguments:
#   bucket_name: S3 bucket name
# Returns:
#   0 if enabled, non-zero otherwise
#######################################
validate_bucket_logging() {
  local bucket_name="${1:-}"
  
  log_info "Checking access logging for bucket: $bucket_name"
  
  local logging_config
  logging_config=$(aws s3api get-bucket-logging \
    --bucket "$bucket_name" \
    --query 'LoggingEnabled' \
    --output json \
    --no-cli-pager 2>/dev/null || echo "null")
  
  log_verbose "Logging config: $logging_config"
  
  if [[ "$logging_config" != "null" ]] && [[ -n "$logging_config" ]]; then
    record_pass "Bucket Logging: Enabled"
    return "$EXIT_SUCCESS"
  else
    record_fail "Bucket Logging: Not configured (required for audit trails per docs/SECURITY.md)"
    return "$EXIT_VALIDATION_ERROR"
  fi
}

#######################################
# Validate S3 bucket policy for TLS enforcement
# Arguments:
#   bucket_name: S3 bucket name
# Returns:
#   0 if TLS is enforced, non-zero otherwise
#######################################
validate_tls_enforcement() {
  local bucket_name="${1:-}"
  
  log_info "Checking TLS enforcement for bucket: $bucket_name"
  
  local bucket_policy
  if ! bucket_policy=$(aws s3api get-bucket-policy \
    --bucket "$bucket_name" \
    --query 'Policy' \
    --output text \
    --no-cli-pager 2>/dev/null); then
    record_warn "Bucket Policy: No policy configured (TLS enforcement recommended)"
    return "$EXIT_SUCCESS"
  fi
  
  log_verbose "Bucket policy: $bucket_policy"
  
  # Check if policy contains SecureTransport condition
  if echo "$bucket_policy" | grep -q "aws:SecureTransport"; then
    record_pass "TLS Enforcement: SecureTransport condition found in policy"
    return "$EXIT_SUCCESS"
  else
    record_warn "TLS Enforcement: No SecureTransport condition in bucket policy"
    return "$EXIT_SUCCESS"
  fi
}

#######################################
# Validate all S3 bucket security settings
# Arguments:
#   bucket_name: S3 bucket name
# Returns:
#   0 if all critical checks pass, non-zero otherwise
#######################################
validate_s3_security() {
  local bucket_name="${1:-}"
  local critical_failure=false
  
  echo ""
  echo "=========================================="
  echo "S3 Bucket Security Validation"
  echo "Bucket: $bucket_name"
  echo "=========================================="
  echo ""
  
  # Verify bucket exists
  if ! aws s3api head-bucket --bucket "$bucket_name" --no-cli-pager 2>/dev/null; then
    log_error "Cannot access bucket: $bucket_name"
    return "$EXIT_AWS_ERROR"
  fi
  
  # Run all S3 security checks
  validate_block_public_access "$bucket_name" || critical_failure=true
  validate_bucket_encryption "$bucket_name" || critical_failure=true
  validate_bucket_versioning "$bucket_name" || true  # Warning only
  validate_bucket_logging "$bucket_name" || true  # Warning only
  validate_tls_enforcement "$bucket_name" || true  # Warning only
  
  if [[ "$critical_failure" == "true" ]]; then
    return "$EXIT_SECURITY_FAILURE"
  fi
  
  return "$EXIT_SUCCESS"
}

#######################################
# Validate IAM role exists and has required permissions
# Arguments:
#   role_arn: IAM role ARN
# Returns:
#   0 if role is valid, non-zero otherwise
#######################################
validate_iam_role() {
  local role_arn="${1:-}"
  
  if [[ -z "$role_arn" ]]; then
    return "$EXIT_SUCCESS"  # Skip if not provided
  fi
  
  echo ""
  echo "=========================================="
  echo "IAM Role Validation"
  echo "Role: $role_arn"
  echo "=========================================="
  echo ""
  
  # Extract role name from ARN
  local role_name
  role_name=$(echo "$role_arn" | sed 's/.*:role\///')
  
  log_info "Checking IAM role: $role_name"
  
  # Check if role exists
  if ! aws iam get-role --role-name "$role_name" --no-cli-pager &>/dev/null; then
    record_fail "IAM Role: Role does not exist or is not accessible"
    return "$EXIT_SECURITY_FAILURE"
  fi
  
  record_pass "IAM Role: Role exists and is accessible"
  
  # Check attached policies
  log_info "Checking attached policies..."
  
  local attached_policies
  attached_policies=$(aws iam list-attached-role-policies \
    --role-name "$role_name" \
    --query 'AttachedPolicies[].PolicyName' \
    --output text \
    --no-cli-pager 2>/dev/null || echo "")
  
  if [[ -n "$attached_policies" ]]; then
    log_verbose "Attached policies: $attached_policies"
    record_pass "IAM Role: Has attached policies"
  else
    record_warn "IAM Role: No managed policies attached"
  fi
  
  # Check inline policies
  local inline_policies
  inline_policies=$(aws iam list-role-policies \
    --role-name "$role_name" \
    --query 'PolicyNames' \
    --output text \
    --no-cli-pager 2>/dev/null || echo "")
  
  if [[ -n "$inline_policies" ]]; then
    log_verbose "Inline policies: $inline_policies"
    record_pass "IAM Role: Has inline policies"
  fi
  
  # Check trust policy for Bedrock
  log_info "Checking trust policy..."
  
  local trust_policy
  trust_policy=$(aws iam get-role \
    --role-name "$role_name" \
    --query 'Role.AssumeRolePolicyDocument' \
    --output json \
    --no-cli-pager 2>/dev/null || echo "{}")
  
  log_verbose "Trust policy: $trust_policy"
  
  if echo "$trust_policy" | grep -q "bedrock.amazonaws.com"; then
    record_pass "IAM Role: Trust policy allows Bedrock service"
  else
    record_warn "IAM Role: Trust policy may not allow Bedrock service"
  fi
  
  return "$EXIT_SUCCESS"
}

#######################################
# Validate Bedrock model import status
# Arguments:
#   model_id: Bedrock model ID
# Returns:
#   0 if model is available, non-zero otherwise
#######################################
validate_model_status() {
  local model_id="${1:-}"
  
  if [[ -z "$model_id" ]]; then
    return "$EXIT_SUCCESS"  # Skip if not provided
  fi
  
  echo ""
  echo "=========================================="
  echo "Bedrock Model Validation"
  echo "Model: $model_id"
  echo "=========================================="
  echo ""
  
  log_info "Checking model status: $model_id"
  
  # Try to get model information
  local model_info
  if model_info=$(aws bedrock get-imported-model \
    --model-identifier "$model_id" \
    --output json \
    --no-cli-pager 2>/dev/null); then
    
    log_verbose "Model info: $model_info"
    
    local model_name
    model_name=$(echo "$model_info" | python3 -c "import sys, json; print(json.load(sys.stdin).get('modelName', 'Unknown'))" 2>/dev/null || echo "Unknown")
    
    record_pass "Model Status: Model '$model_name' is available"
    
    # Check model ARN
    local model_arn
    model_arn=$(echo "$model_info" | python3 -c "import sys, json; print(json.load(sys.stdin).get('modelArn', ''))" 2>/dev/null || echo "")
    
    if [[ -n "$model_arn" ]]; then
      log_verbose "Model ARN: $model_arn"
      record_pass "Model Status: Model ARN is valid"
    fi
    
    return "$EXIT_SUCCESS"
  else
    # Model not found as imported model, check if it's a foundation model
    if aws bedrock get-foundation-model \
      --model-identifier "$model_id" \
      --no-cli-pager &>/dev/null; then
      record_pass "Model Status: Foundation model is available"
      return "$EXIT_SUCCESS"
    fi
    
    record_fail "Model Status: Model not found or not accessible"
    return "$EXIT_VALIDATION_ERROR"
  fi
}

#######################################
# Print validation summary
#######################################
print_summary() {
  echo ""
  echo "=========================================="
  echo "Validation Summary"
  echo "=========================================="
  echo ""
  echo -e "  ${GREEN}Passed:${NC}   $VALIDATION_PASSED"
  echo -e "  ${RED}Failed:${NC}   $VALIDATION_FAILED"
  echo -e "  ${YELLOW}Warnings:${NC} $VALIDATION_WARNINGS"
  echo ""
  
  if [[ "$VALIDATION_FAILED" -eq 0 ]]; then
    log_success "All critical security validations passed"
    if [[ "$VALIDATION_WARNINGS" -gt 0 ]]; then
      log_info "Review warnings above for recommended improvements"
    fi
  else
    log_error "Some security validations failed - review and remediate"
  fi
  echo ""
}

#######################################
# Validate all inputs
# Returns:
#   0 if all inputs are valid, non-zero otherwise
#######################################
validate_inputs() {
  local exit_code=0
  
  if ! validate_bucket_name "$BUCKET_NAME"; then
    exit_code="$EXIT_VALIDATION_ERROR"
  fi
  
  if ! validate_role_arn_format "$ROLE_ARN"; then
    exit_code="$EXIT_VALIDATION_ERROR"
  fi
  
  if ! validate_model_id_format "$MODEL_ID"; then
    exit_code="$EXIT_VALIDATION_ERROR"
  fi
  
  return "$exit_code"
}

#######################################
# Main function
# Returns:
#   0 on success, non-zero on failure
#######################################
main() {
  log_info "Deployment validation started"
  
  # Validate inputs
  if ! validate_inputs; then
    return "$EXIT_VALIDATION_ERROR"
  fi
  
  # Check AWS CLI
  if ! check_aws_cli; then
    return "$EXIT_AWS_ERROR"
  fi
  
  local overall_result=0
  
  # Validate S3 bucket security
  if ! validate_s3_security "$BUCKET_NAME"; then
    overall_result="$EXIT_SECURITY_FAILURE"
  fi
  
  # Validate IAM role if provided
  if [[ -n "$ROLE_ARN" ]]; then
    if ! validate_iam_role "$ROLE_ARN"; then
      overall_result="$EXIT_SECURITY_FAILURE"
    fi
  fi
  
  # Validate model status if provided
  if [[ -n "$MODEL_ID" ]]; then
    if ! validate_model_status "$MODEL_ID"; then
      overall_result="$EXIT_VALIDATION_ERROR"
    fi
  fi
  
  # Print summary
  print_summary
  
  return "$overall_result"
}

# Main execution
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
  # Parse command line arguments
  if ! parse_arguments "$@"; then
    exit "$EXIT_INVALID_ARGS"
  fi
  
  # Check required arguments
  if [[ -z "$BUCKET_NAME" ]]; then
    log_error "Bucket name is required (--bucket)"
    show_usage
    exit "$EXIT_INVALID_ARGS"
  fi
  
  # Run main function
  main
fi
