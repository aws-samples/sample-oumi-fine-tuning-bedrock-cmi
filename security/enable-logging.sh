#!/bin/bash
# Copyright Amazon.com, Inc. or its affiliates. All Rights Reserved.
# SPDX-License-Identifier: MIT-0
# Amazon CloudWatch and AWS CloudTrail Logging Setup Script
#
# This script configures logging for AWS resources including Amazon CloudWatch log groups,
# AWS CloudTrail trails, and Amazon S3 access logging.
#
# Security Controls and Measurable Outcomes:
#   - CloudWatch Log Groups: Centralized logging with configurable retention (SOC 2)
#   - CloudTrail Integration: API activity auditing for compliance (CIS AWS 3.1)
#   - S3 Access Logging: Object-level audit trail (ISO 27001 A.12.4.1)
#   - Log File Validation: Ensures log integrity for forensic analysis
#
# Implementation Priority: Priority 1 (Critical) - See docs/SECURITY.md Section 10
#
# Usage:
#   ./enable-logging.sh cloudwatch <LOG_GROUP_NAME> [RETENTION_DAYS]
#   ./enable-logging.sh cloudtrail <TRAIL_NAME> <S3_BUCKET_NAME> [LOG_GROUP_NAME]
#   ./enable-logging.sh s3 <BUCKET_NAME> <LOG_BUCKET_NAME> [LOG_PREFIX]
#   ./enable-logging.sh all <PROJECT_NAME> <S3_BUCKET_NAME>

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

# Default values
readonly DEFAULT_RETENTION_DAYS=30
readonly DEFAULT_LOG_PREFIX="logs/"

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
# Validate that a name follows AWS naming conventions
# Arguments:
#   name: The name to validate
#   type: The type of resource (for error messages)
# Returns:
#   0 if valid, non-zero otherwise
#######################################
validate_name() {
  local name="${1:-}"
  local type="${2:-resource}"
  
  if [[ -z "$name" ]]; then
    log_error "$type name is required"
    return "$EXIT_INVALID_ARGS"
  fi
  
  # General AWS naming: alphanumeric, hyphens, underscores, forward slashes, periods
  if [[ ! "$name" =~ ^[a-zA-Z0-9/_.-]+$ ]]; then
    log_error "Invalid $type name format: $name"
    return "$EXIT_VALIDATION_ERROR"
  fi
  
  return "$EXIT_SUCCESS"
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
# Validate retention days is a positive integer
# Arguments:
#   retention_days: The retention period in days
# Returns:
#   0 if valid, non-zero otherwise
#######################################
validate_retention_days() {
  local retention_days="${1:-}"
  
  if [[ -z "$retention_days" ]]; then
    return "$EXIT_SUCCESS"  # Optional parameter
  fi
  
  # Valid CloudWatch retention values
  local valid_values=(1 3 5 7 14 30 60 90 120 150 180 365 400 545 731 1096 1827 2192 2557 2922 3288 3653)
  
  if [[ ! "$retention_days" =~ ^[0-9]+$ ]]; then
    log_error "Retention days must be a positive integer: $retention_days"
    return "$EXIT_VALIDATION_ERROR"
  fi
  
  local is_valid=false
  for val in "${valid_values[@]}"; do
    if [[ "$retention_days" -eq "$val" ]]; then
      is_valid=true
      break
    fi
  done
  
  if [[ "$is_valid" == "false" ]]; then
    log_error "Invalid retention days: $retention_days. Valid values: ${valid_values[*]}"
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
# Configure CloudWatch log group
# Arguments:
#   log_group_name: The name of the log group
#   retention_days: (Optional) Log retention period in days
# Returns:
#   0 on success, non-zero on failure
#######################################
configure_cloudwatch_log_group() {
  local log_group_name="${1:-}"
  local retention_days="${2:-$DEFAULT_RETENTION_DAYS}"
  
  log_info "Configuring CloudWatch log group: $log_group_name"
  
  # Validate inputs
  if ! validate_name "$log_group_name" "Log group"; then
    return "$EXIT_INVALID_ARGS"
  fi
  
  if ! validate_retention_days "$retention_days"; then
    return "$EXIT_VALIDATION_ERROR"
  fi
  
  # Check AWS CLI
  if ! check_aws_cli; then
    return "$EXIT_AWS_ERROR"
  fi
  
  # Create log group if it doesn't exist
  if ! aws logs describe-log-groups \
    --log-group-name-prefix "$log_group_name" \
    --query "logGroups[?logGroupName=='$log_group_name'].logGroupName" \
    --output text --no-cli-pager | grep -q "^$log_group_name$"; then
    
    log_info "Creating log group: $log_group_name"
    if ! aws logs create-log-group \
      --log-group-name "$log_group_name" \
      --no-cli-pager; then
      log_error "Failed to create log group: $log_group_name"
      return "$EXIT_AWS_ERROR"
    fi
  else
    log_info "Log group already exists: $log_group_name"
  fi
  
  # Set retention policy
  log_info "Setting retention policy to $retention_days days"
  if ! aws logs put-retention-policy \
    --log-group-name "$log_group_name" \
    --retention-in-days "$retention_days" \
    --no-cli-pager; then
    log_error "Failed to set retention policy for log group: $log_group_name"
    return "$EXIT_AWS_ERROR"
  fi
  
  log_success "CloudWatch log group configured: $log_group_name (retention: $retention_days days)"
  return "$EXIT_SUCCESS"
}

#######################################
# Configure CloudTrail trail
# Arguments:
#   trail_name: The name of the CloudTrail trail
#   s3_bucket_name: The S3 bucket for trail logs
#   log_group_name: (Optional) CloudWatch log group for trail events
# Returns:
#   0 on success, non-zero on failure
#######################################
configure_cloudtrail() {
  local trail_name="${1:-}"
  local s3_bucket_name="${2:-}"
  local log_group_name="${3:-}"
  
  log_info "Configuring CloudTrail trail: $trail_name"
  
  # Validate inputs
  if ! validate_name "$trail_name" "Trail"; then
    return "$EXIT_INVALID_ARGS"
  fi
  
  if ! validate_bucket_name "$s3_bucket_name"; then
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
  
  # Check if trail exists
  local trail_exists=false
  if aws cloudtrail describe-trails \
    --trail-name-list "$trail_name" \
    --query 'trailList[0].Name' \
    --output text --no-cli-pager 2>/dev/null | grep -q "^$trail_name$"; then
    trail_exists=true
    log_info "Trail already exists: $trail_name"
  fi
  
  if [[ "$trail_exists" == "false" ]]; then
    log_info "Creating CloudTrail trail: $trail_name"
    
    local create_args=(
      --name "$trail_name"
      --s3-bucket-name "$s3_bucket_name"
      --s3-key-prefix "cloudtrail"
      --include-global-service-events
      --is-multi-region-trail
      --enable-log-file-validation
      --no-cli-pager
    )
    
    # Add CloudWatch Logs integration if log group specified
    if [[ -n "$log_group_name" ]]; then
      # Create log group first
      configure_cloudwatch_log_group "$log_group_name"
      
      local log_group_arn="arn:aws:logs:$region:$account_id:log-group:$log_group_name:*"
      local role_arn="arn:aws:iam::$account_id:role/CloudTrail_CloudWatchLogs_Role"
      
      create_args+=(--cloud-watch-logs-log-group-arn "$log_group_arn")
      create_args+=(--cloud-watch-logs-role-arn "$role_arn")
    fi
    
    if ! aws cloudtrail create-trail "${create_args[@]}"; then
      log_error "Failed to create CloudTrail trail: $trail_name"
      return "$EXIT_AWS_ERROR"
    fi
  fi
  
  # Start logging
  log_info "Starting CloudTrail logging"
  if ! aws cloudtrail start-logging \
    --name "$trail_name" \
    --no-cli-pager; then
    log_error "Failed to start logging for trail: $trail_name"
    return "$EXIT_AWS_ERROR"
  fi
  
  log_success "CloudTrail trail configured: $trail_name -> s3://$s3_bucket_name/cloudtrail/"
  return "$EXIT_SUCCESS"
}

#######################################
# Configure S3 access logging
# Arguments:
#   bucket_name: The S3 bucket to enable logging for
#   log_bucket_name: The target bucket for access logs
#   log_prefix: (Optional) Prefix for log objects
# Returns:
#   0 on success, non-zero on failure
#######################################
configure_s3_logging() {
  local bucket_name="${1:-}"
  local log_bucket_name="${2:-}"
  local log_prefix="${3:-$DEFAULT_LOG_PREFIX}"
  
  log_info "Configuring S3 access logging for bucket: $bucket_name"
  
  # Validate inputs
  if ! validate_bucket_name "$bucket_name"; then
    return "$EXIT_INVALID_ARGS"
  fi
  
  if ! validate_bucket_name "$log_bucket_name"; then
    log_error "Invalid log bucket name"
    return "$EXIT_INVALID_ARGS"
  fi
  
  # Append trailing slash to log prefix if missing
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
    "TargetPrefix": "${log_prefix}${bucket_name}/"
  }
}
EOF
)
  
  if ! aws s3api put-bucket-logging \
    --bucket "$bucket_name" \
    --bucket-logging-status "$logging_config" \
    --no-cli-pager; then
    log_error "Failed to configure S3 access logging for bucket: $bucket_name"
    return "$EXIT_AWS_ERROR"
  fi
  
  log_success "S3 access logging configured: $bucket_name -> $log_bucket_name/${log_prefix}${bucket_name}/"
  return "$EXIT_SUCCESS"
}

#######################################
# Configure all logging for a project
# Arguments:
#   project_name: The project name (used for naming resources)
#   s3_bucket_name: The S3 bucket for logs
# Returns:
#   0 on success, non-zero on failure
#######################################
configure_all_logging() {
  local project_name="${1:-}"
  local s3_bucket_name="${2:-}"
  
  log_info "Configuring all logging for project: $project_name"
  
  # Validate inputs
  if ! validate_name "$project_name" "Project"; then
    return "$EXIT_INVALID_ARGS"
  fi
  
  if ! validate_bucket_name "$s3_bucket_name"; then
    return "$EXIT_INVALID_ARGS"
  fi
  
  local exit_code=0
  local log_group_name="/aws/$project_name"
  local trail_name="${project_name}-trail"
  
  # Configure CloudWatch log group
  if ! configure_cloudwatch_log_group "$log_group_name"; then
    log_error "Failed to configure CloudWatch log group"
    exit_code="$EXIT_AWS_ERROR"
  fi
  
  # Configure CloudTrail
  if ! configure_cloudtrail "$trail_name" "$s3_bucket_name" "$log_group_name"; then
    log_error "Failed to configure CloudTrail"
    exit_code="$EXIT_AWS_ERROR"
  fi
  
  # Configure S3 access logging (log bucket logs to itself with different prefix)
  if ! configure_s3_logging "$s3_bucket_name" "$s3_bucket_name" "s3-access-logs"; then
    log_error "Failed to configure S3 access logging"
    exit_code="$EXIT_AWS_ERROR"
  fi
  
  if [[ "$exit_code" -eq 0 ]]; then
    log_success "All logging configured for project: $project_name"
  else
    log_error "Some logging configurations failed for project: $project_name"
  fi
  
  return "$exit_code"
}

# Display usage information
show_usage() {
  echo "Enable Logging Script"
  echo ""
  echo "Usage:"
  echo "  $0 cloudwatch <LOG_GROUP_NAME> [RETENTION_DAYS]"
  echo "  $0 cloudtrail <TRAIL_NAME> <S3_BUCKET_NAME> [LOG_GROUP_NAME]"
  echo "  $0 s3 <BUCKET_NAME> <LOG_BUCKET_NAME> [LOG_PREFIX]"
  echo "  $0 all <PROJECT_NAME> <S3_BUCKET_NAME>"
  echo ""
  echo "Commands:"
  echo "  cloudwatch  Configure CloudWatch log group with retention policy"
  echo "  cloudtrail  Configure CloudTrail trail with S3 and optional CloudWatch integration"
  echo "  s3          Configure S3 access logging"
  echo "  all         Configure all logging for a project"
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
    cloudwatch)
      configure_cloudwatch_log_group "$@"
      ;;
    cloudtrail)
      configure_cloudtrail "$@"
      ;;
    s3)
      configure_s3_logging "$@"
      ;;
    all)
      configure_all_logging "$@"
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
