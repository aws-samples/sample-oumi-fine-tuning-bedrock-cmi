#!/bin/bash
# Copyright Amazon.com, Inc. or its affiliates. All Rights Reserved.
# SPDX-License-Identifier: MIT-0
# Import to Bedrock Script
#
# This script creates a model import job in Amazon Bedrock and monitors
# the import status until completion. Model artifacts are retrieved from
# Amazon Simple Storage Service (Amazon S3).
#
# Security Controls and Measurable Outcomes:
#   - S3 Encryption Verification: Validates server-side encryption before import
#   - IAM Role Validation: Verifies Bedrock has required S3 permissions
#   - Import Job Auditing: Logs job creation and status for compliance tracking
#   - Timeout Controls: Prevents indefinite resource consumption
#
# Implementation Priority: Priority 2 (High) - See docs/SECURITY.md Section 10
#
# Usage:
#   ./import-to-bedrock.sh --model-name <NAME> --s3-uri <S3_URI> --role-arn <ROLE_ARN> [OPTIONS]
#
# Options:
#   --model-name      Name for the imported model (required)
#   --s3-uri          S3 URI of model artifacts (required)
#   --role-arn        IAM role ARN for Bedrock to access S3 (required)
#   --job-name        Custom import job name (default: auto-generated)
#   --wait            Wait for import to complete
#   --timeout         Timeout in seconds when waiting (default: 3600)
#   --poll-interval   Polling interval in seconds (default: 30)
#   -h, --help        Show this help message

set -euo pipefail

# Exit codes
readonly EXIT_SUCCESS=0
readonly EXIT_INVALID_ARGS=1
readonly EXIT_AWS_ERROR=2
readonly EXIT_VALIDATION_ERROR=3
readonly EXIT_TIMEOUT_ERROR=4

# Color codes for output
readonly RED='\033[0;31m'
readonly GREEN='\033[0;32m'
readonly YELLOW='\033[1;33m'
readonly BLUE='\033[0;34m'
readonly NC='\033[0m' # No Color

# Default values
MODEL_NAME=""
S3_URI=""
ROLE_ARN=""
JOB_NAME=""
WAIT_FOR_COMPLETION=false
TIMEOUT_SECONDS=3600
POLL_INTERVAL=30

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
# Log a progress message
# Arguments:
#   Message to log
#######################################
log_progress() {
  echo -e "${BLUE}[PROGRESS]${NC} $1"
}

#######################################
# Display usage information
#######################################
show_usage() {
  echo "Import to Bedrock Script"
  echo ""
  echo "Usage:"
  echo "  $0 --model-name <NAME> --s3-uri <S3_URI> --role-arn <ROLE_ARN> [OPTIONS]"
  echo ""
  echo "Options:"
  echo "  --model-name      Name for the imported model (required)"
  echo "  --s3-uri          S3 URI of model artifacts (required)"
  echo "  --role-arn        IAM role ARN for Bedrock to access S3 (required)"
  echo "  --job-name        Custom import job name (default: auto-generated)"
  echo "  --wait            Wait for import to complete"
  echo "  --timeout         Timeout in seconds when waiting (default: $TIMEOUT_SECONDS)"
  echo "  --poll-interval   Polling interval in seconds (default: $POLL_INTERVAL)"
  echo "  -h, --help        Show this help message"
  echo ""
  echo "Examples:"
  echo "  $0 --model-name my-model --s3-uri s3://bucket/models/ --role-arn arn:aws:iam::123456789012:role/BedrockModelImportRole"
  echo "  $0 --model-name my-model --s3-uri s3://bucket/models/ --role-arn arn:aws:iam::123456789012:role/BedrockModelImportRole --wait"
  echo ""
  echo "Exit codes:"
  echo "  0 - Success"
  echo "  1 - Invalid arguments"
  echo "  2 - AWS CLI error"
  echo "  3 - Validation error"
  echo "  4 - Timeout error"
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
      --model-name)
        if [[ -z "${2:-}" ]]; then
          log_error "Model name argument requires a value"
          return "$EXIT_INVALID_ARGS"
        fi
        MODEL_NAME="$2"
        shift 2
        ;;
      --s3-uri)
        if [[ -z "${2:-}" ]]; then
          log_error "S3 URI argument requires a value"
          return "$EXIT_INVALID_ARGS"
        fi
        S3_URI="$2"
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
      --job-name)
        if [[ -z "${2:-}" ]]; then
          log_error "Job name argument requires a value"
          return "$EXIT_INVALID_ARGS"
        fi
        JOB_NAME="$2"
        shift 2
        ;;
      --wait)
        WAIT_FOR_COMPLETION=true
        shift
        ;;
      --timeout)
        if [[ -z "${2:-}" ]]; then
          log_error "Timeout argument requires a value"
          return "$EXIT_INVALID_ARGS"
        fi
        TIMEOUT_SECONDS="$2"
        shift 2
        ;;
      --poll-interval)
        if [[ -z "${2:-}" ]]; then
          log_error "Poll interval argument requires a value"
          return "$EXIT_INVALID_ARGS"
        fi
        POLL_INTERVAL="$2"
        shift 2
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
# Validate model name format
# Arguments:
#   model_name: Model name to validate
# Returns:
#   0 if valid, non-zero otherwise
#######################################
validate_model_name() {
  local model_name="${1:-}"
  
  if [[ -z "$model_name" ]]; then
    log_error "Model name is required"
    return "$EXIT_INVALID_ARGS"
  fi
  
  # Model name: alphanumeric, hyphens, underscores, 1-63 characters
  if [[ ! "$model_name" =~ ^[a-zA-Z0-9][a-zA-Z0-9_-]{0,62}$ ]]; then
    log_error "Invalid model name format: $model_name"
    log_error "Model name must be 1-63 characters, alphanumeric, hyphens, and underscores"
    return "$EXIT_VALIDATION_ERROR"
  fi
  
  return "$EXIT_SUCCESS"
}

#######################################
# Validate S3 URI format
# Arguments:
#   s3_uri: S3 URI to validate
# Returns:
#   0 if valid, non-zero otherwise
#######################################
validate_s3_uri() {
  local s3_uri="${1:-}"
  
  if [[ -z "$s3_uri" ]]; then
    log_error "S3 URI is required"
    return "$EXIT_INVALID_ARGS"
  fi
  
  # S3 URI format: s3://bucket-name/key
  if [[ ! "$s3_uri" =~ ^s3://[a-z0-9][a-z0-9.-]{1,61}[a-z0-9]/.* ]]; then
    log_error "Invalid S3 URI format: $s3_uri"
    log_error "Expected format: s3://bucket-name/path/"
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
validate_role_arn() {
  local role_arn="${1:-}"
  
  if [[ -z "$role_arn" ]]; then
    log_error "Role ARN is required"
    return "$EXIT_INVALID_ARGS"
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
# Validate timeout is a positive integer
# Arguments:
#   timeout: Timeout value to validate
# Returns:
#   0 if valid, non-zero otherwise
#######################################
validate_timeout() {
  local timeout="${1:-}"
  
  if [[ ! "$timeout" =~ ^[0-9]+$ ]] || [[ "$timeout" -lt 1 ]]; then
    log_error "Timeout must be a positive integer: $timeout"
    return "$EXIT_VALIDATION_ERROR"
  fi
  
  return "$EXIT_SUCCESS"
}

#######################################
# Validate poll interval is a positive integer
# Arguments:
#   interval: Poll interval to validate
# Returns:
#   0 if valid, non-zero otherwise
#######################################
validate_poll_interval() {
  local interval="${1:-}"
  
  if [[ ! "$interval" =~ ^[0-9]+$ ]] || [[ "$interval" -lt 1 ]]; then
    log_error "Poll interval must be a positive integer: $interval"
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
# Verify S3 artifacts exist
# Arguments:
#   s3_uri: S3 URI to verify
# Returns:
#   0 if exists, non-zero otherwise
#######################################
verify_s3_artifacts() {
  local s3_uri="${1:-}"

  log_info "Verifying S3 artifacts: $s3_uri"

  # Extract bucket and prefix from URI
  local bucket_and_key="${s3_uri#s3://}"
  local bucket="${bucket_and_key%%/*}"
  local prefix="${bucket_and_key#*/}"

  # Check if objects exist at the location
  local object_count
  object_count=$(aws s3 ls "$s3_uri" --no-cli-pager 2>/dev/null | wc -l)

  if [[ "$object_count" -eq 0 ]]; then
    log_error "No objects found at S3 URI: $s3_uri"
    return "$EXIT_VALIDATION_ERROR"
  fi

  log_info "Found $object_count objects at S3 URI"
  return "$EXIT_SUCCESS"
}

#######################################
# Verify S3 objects are encrypted
# Arguments:
#   s3_uri: S3 URI to verify encryption
# Returns:
#   0 if encrypted, non-zero otherwise
#######################################
verify_s3_encryption() {
  local s3_uri="${1:-}"

  log_info "Verifying S3 encryption for: $s3_uri"

  # Extract bucket and prefix from URI
  local bucket_and_key="${s3_uri#s3://}"
  local bucket="${bucket_and_key%%/*}"
  local prefix="${bucket_and_key#*/}"

  # List recursively to get actual object keys (not PRE directory entries)
  local first_key
  first_key=$(aws s3 ls "$s3_uri" --recursive --no-cli-pager 2>/dev/null | head -1 | awk '{print $NF}')

  if [[ -z "$first_key" ]]; then
    log_error "No objects found to verify encryption"
    return "$EXIT_VALIDATION_ERROR"
  fi

  # Check encryption metadata on the object
  local encryption_type
  encryption_type=$(aws s3api head-object \
    --bucket "$bucket" \
    --key "$first_key" \
    --query 'ServerSideEncryption' \
    --output text \
    --no-cli-pager 2>/dev/null)

  if [[ "$encryption_type" != "aws:kms" ]] && [[ "$encryption_type" != "AES256" ]]; then
    log_error "S3 objects are not encrypted. Found encryption type: ${encryption_type:-none}"
    log_error "Model artifacts must be encrypted with server-side encryption"
    return "$EXIT_VALIDATION_ERROR"
  fi

  log_success "S3 objects are encrypted (${encryption_type})"

  return "$EXIT_SUCCESS"
}

#######################################
# Create model import job
# Returns:
#   Job identifier via stdout, or empty on failure
#######################################
create_import_job() {
  # Log messages go to stderr so stdout is clean for the job ARN
  log_info "Creating model import job..." >&2

  # Generate job name if not provided
  if [[ -z "$JOB_NAME" ]]; then
    JOB_NAME="${MODEL_NAME}-import-$(date +%Y%m%d-%H%M%S)"
  fi

  log_info "Job name: $JOB_NAME" >&2
  log_info "Model name: $MODEL_NAME" >&2
  log_info "S3 URI: $S3_URI" >&2
  log_info "Role ARN: $ROLE_ARN" >&2

  # Create the import job
  local job_arn
  local aws_err
  aws_err=$(mktemp)
  job_arn=$(aws bedrock create-model-import-job \
    --job-name "$JOB_NAME" \
    --imported-model-name "$MODEL_NAME" \
    --role-arn "$ROLE_ARN" \
    --model-data-source "s3DataSource={s3Uri=$S3_URI}" \
    --query 'jobArn' \
    --output text \
    --no-cli-pager 2>"$aws_err")
  local rc=$?

  if [[ $rc -ne 0 ]] || [[ -z "$job_arn" ]] || [[ "$job_arn" == "None" ]]; then
    log_error "Failed to create model import job"
    [[ -s "$aws_err" ]] && log_error "$(cat "$aws_err")"
    rm -f "$aws_err"
    return "$EXIT_AWS_ERROR"
  fi
  rm -f "$aws_err"

  log_success "Import job created: $job_arn" >&2
  echo "$job_arn"
  return "$EXIT_SUCCESS"
}

#######################################
# Get import job status
# Arguments:
#   job_arn: Job ARN to check
# Returns:
#   Status via stdout
#######################################
get_job_status() {
  local job_arn="${1:-}"
  
  local status
  status=$(aws bedrock get-model-import-job \
    --job-identifier "$job_arn" \
    --query 'status' \
    --output text \
    --no-cli-pager 2>/dev/null)
  
  echo "$status"
}

#######################################
# Get import job details
# Arguments:
#   job_arn: Job ARN to check
#######################################
get_job_details() {
  local job_arn="${1:-}"
  
  aws bedrock get-model-import-job \
    --job-identifier "$job_arn" \
    --no-cli-pager 2>/dev/null
}

#######################################
# Wait for import job to complete
# Arguments:
#   job_arn: Job ARN to monitor
# Returns:
#   0 on success, non-zero on failure
#######################################
wait_for_completion() {
  local job_arn="${1:-}"
  
  log_info "Waiting for import job to complete (timeout: ${TIMEOUT_SECONDS}s)..."
  
  local start_time
  start_time=$(date +%s)
  local elapsed=0
  
  while [[ "$elapsed" -lt "$TIMEOUT_SECONDS" ]]; do
    local status
    status=$(get_job_status "$job_arn")
    
    case "$status" in
      Completed)
        log_success "Import job completed successfully"
        return "$EXIT_SUCCESS"
        ;;
      Failed)
        log_error "Import job failed"
        log_info "Job details:"
        get_job_details "$job_arn"
        return "$EXIT_AWS_ERROR"
        ;;
      InProgress|Pending)
        log_progress "Status: $status (elapsed: ${elapsed}s)"
        sleep "$POLL_INTERVAL"
        ;;
      *)
        log_error "Unknown job status: $status"
        return "$EXIT_AWS_ERROR"
        ;;
    esac
    
    local current_time
    current_time=$(date +%s)
    elapsed=$((current_time - start_time))
  done
  
  log_error "Timeout waiting for import job to complete"
  return "$EXIT_TIMEOUT_ERROR"
}

#######################################
# Validate all inputs
# Returns:
#   0 if all inputs are valid, non-zero otherwise
#######################################
validate_inputs() {
  local exit_code=0
  
  if ! validate_model_name "$MODEL_NAME"; then
    exit_code="$EXIT_VALIDATION_ERROR"
  fi
  
  if ! validate_s3_uri "$S3_URI"; then
    exit_code="$EXIT_VALIDATION_ERROR"
  fi
  
  if ! validate_role_arn "$ROLE_ARN"; then
    exit_code="$EXIT_VALIDATION_ERROR"
  fi
  
  if ! validate_timeout "$TIMEOUT_SECONDS"; then
    exit_code="$EXIT_VALIDATION_ERROR"
  fi
  
  if ! validate_poll_interval "$POLL_INTERVAL"; then
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
  log_info "Bedrock import workflow started"
  
  # Validate inputs
  if ! validate_inputs; then
    return "$EXIT_VALIDATION_ERROR"
  fi
  
  # Check AWS CLI
  if ! check_aws_cli; then
    return "$EXIT_AWS_ERROR"
  fi
  
  # Verify S3 artifacts exist
  if ! verify_s3_artifacts "$S3_URI"; then
    return "$EXIT_VALIDATION_ERROR"
  fi

  # Verify S3 encryption before import
  if ! verify_s3_encryption "$S3_URI"; then
    return "$EXIT_VALIDATION_ERROR"
  fi

  # Create import job
  local job_arn
  job_arn=$(create_import_job)
  local create_result=$?
  
  if [[ $create_result -ne 0 ]] || [[ -z "$job_arn" ]]; then
    log_error "Failed to create import job"
    return "$EXIT_AWS_ERROR"
  fi
  
  # Wait for completion if requested
  if [[ "$WAIT_FOR_COMPLETION" == "true" ]]; then
    if ! wait_for_completion "$job_arn"; then
      return "$EXIT_AWS_ERROR"
    fi
  else
    log_info "Import job started. Use --wait to wait for completion."
    log_info "Check status: aws bedrock get-model-import-job --job-identifier $job_arn"
  fi
  
  log_success "Bedrock import workflow completed"
  echo ""
  log_info "Job ARN: $job_arn"
  log_info "Model name: $MODEL_NAME"
  echo ""
  log_info "Next steps:"
  log_info "  Invoke model: ./scripts/invoke-model.sh --model-id $MODEL_NAME"
  
  return "$EXIT_SUCCESS"
}

# Main execution
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
  # Parse command line arguments
  if ! parse_arguments "$@"; then
    exit "$EXIT_INVALID_ARGS"
  fi
  
  # Check required arguments
  if [[ -z "$MODEL_NAME" ]]; then
    log_error "Model name is required (--model-name)"
    show_usage
    exit "$EXIT_INVALID_ARGS"
  fi
  
  if [[ -z "$S3_URI" ]]; then
    log_error "S3 URI is required (--s3-uri)"
    show_usage
    exit "$EXIT_INVALID_ARGS"
  fi
  
  if [[ -z "$ROLE_ARN" ]]; then
    log_error "Role ARN is required (--role-arn)"
    show_usage
    exit "$EXIT_INVALID_ARGS"
  fi
  
  # Run main function
  main
fi
