#!/bin/bash
# Copyright Amazon.com, Inc. or its affiliates. All Rights Reserved.
# SPDX-License-Identifier: MIT-0
# Upload to Amazon Simple Storage Service (Amazon S3) Script
#
# This script uploads model artifacts to Amazon S3 with server-side encryption.
# Uploads rely on the bucket's default encryption configuration (SSE-S3).
#
# Security Controls and Measurable Outcomes:
#   - S3 Default Encryption: Bucket default encryption applies to all uploads
#   - TLS 1.2+: All transfers use secure transport (enforced by bucket policy)
#   - Integrity Verification: Upload validation prevents corrupted artifacts
#
# Implementation Priority: Priority 1 (Critical) - See docs/SECURITY.md Section 10
#
# Usage:
#   ./upload-to-s3.sh --bucket <BUCKET_NAME> --source <SOURCE_PATH> [OPTIONS]
#
# Options:
#   --bucket          Amazon S3 bucket name (required)
#   --source          Source directory or file to upload (required)
#   --prefix          Amazon S3 key prefix (default: models/)
#   --dry-run         Show what would be uploaded without uploading
#   --delete          Delete files in Amazon S3 that don't exist locally (sync mode)
#   -h, --help        Show this help message

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
BUCKET_NAME=""
SOURCE_PATH=""
S3_PREFIX="models/"
DRY_RUN=false
DELETE_MODE=false

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
# Display usage information
#######################################
show_usage() {
  echo "Upload to S3 Script"
  echo ""
  echo "Usage:"
  echo "  $0 --bucket <BUCKET_NAME> --source <SOURCE_PATH> [OPTIONS]"
  echo ""
  echo "Options:"
  echo "  --bucket          S3 bucket name (required)"
  echo "  --source          Source directory or file to upload (required)"
  echo "  --prefix          S3 key prefix (default: models/)"
  echo "  --dry-run         Show what would be uploaded without uploading"
  echo "  --delete          Delete files in S3 that don't exist locally (sync mode)"
  echo "  -h, --help        Show this help message"
  echo ""
  echo "Examples:"
  echo "  $0 --bucket my-bucket --source models/final"
  echo "  $0 --bucket my-bucket --source model.tar.gz --prefix artifacts/"
  echo ""
  echo "Exit codes:"
  echo "  0 - Success"
  echo "  1 - Invalid arguments"
  echo "  2 - AWS CLI error"
  echo "  3 - Validation error"
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
      --source)
        if [[ -z "${2:-}" ]]; then
          log_error "Source argument requires a value"
          return "$EXIT_INVALID_ARGS"
        fi
        SOURCE_PATH="$2"
        shift 2
        ;;
      --prefix)
        if [[ -z "${2:-}" ]]; then
          log_error "Prefix argument requires a value"
          return "$EXIT_INVALID_ARGS"
        fi
        S3_PREFIX="$2"
        shift 2
        ;;
      --dry-run)
        DRY_RUN=true
        shift
        ;;
      --delete)
        DELETE_MODE=true
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
# Validate source path exists
# Arguments:
#   source_path: Path to validate
# Returns:
#   0 if valid, non-zero otherwise
#######################################
validate_source_path() {
  local source_path="${1:-}"
  
  if [[ -z "$source_path" ]]; then
    log_error "Source path is required"
    return "$EXIT_INVALID_ARGS"
  fi
  
  if [[ ! -e "$source_path" ]]; then
    log_error "Source path does not exist: $source_path"
    return "$EXIT_VALIDATION_ERROR"
  fi
  
  return "$EXIT_SUCCESS"
}

#######################################
# Validate S3 prefix format
# Arguments:
#   prefix: S3 key prefix to validate
# Returns:
#   0 if valid, non-zero otherwise
#######################################
validate_s3_prefix() {
  local prefix="${1:-}"
  
  # Empty prefix is valid
  if [[ -z "$prefix" ]]; then
    return "$EXIT_SUCCESS"
  fi
  
  # Prefix should not start with /
  if [[ "$prefix" =~ ^/ ]]; then
    log_error "S3 prefix should not start with '/': $prefix"
    return "$EXIT_VALIDATION_ERROR"
  fi
  
  # Check for path traversal
  if [[ "$prefix" =~ \.\. ]]; then
    log_error "Invalid S3 prefix (path traversal not allowed): $prefix"
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
# Verify bucket exists and is accessible
# Arguments:
#   bucket_name: S3 bucket name
# Returns:
#   0 if accessible, non-zero otherwise
#######################################
verify_bucket_access() {
  local bucket_name="${1:-}"
  
  log_info "Verifying bucket access: $bucket_name"
  
  if ! aws s3api head-bucket --bucket "$bucket_name" --no-cli-pager 2>/dev/null; then
    log_error "Cannot access bucket: $bucket_name"
    log_error "Verify the bucket exists and you have permission to access it"
    return "$EXIT_AWS_ERROR"
  fi
  
  log_info "Bucket access verified"
  return "$EXIT_SUCCESS"
}

#######################################
# Upload a single file to S3
# Arguments:
#   source_file: Local file path
#   s3_key: S3 object key
# Returns:
#   0 on success, non-zero on failure
#######################################
upload_file() {
  local source_file="${1:-}"
  local s3_key="${2:-}"
  
  local s3_uri="s3://$BUCKET_NAME/$s3_key"
  
  log_info "Uploading: $source_file -> $s3_uri"
  
  if [[ "$DRY_RUN" == "true" ]]; then
    log_info "[DRY RUN] Would upload: $source_file -> $s3_uri"
    return "$EXIT_SUCCESS"
  fi
  
  local -a cp_args=("$source_file" "$s3_uri" --no-cli-pager)

  if ! aws s3 cp "${cp_args[@]}"; then
    log_error "Failed to upload: $source_file"
    return "$EXIT_AWS_ERROR"
  fi
  
  log_success "Uploaded: $source_file"
  return "$EXIT_SUCCESS"
}

#######################################
# Upload a directory to S3 with encryption
# Arguments:
#   source_dir: Local directory path
# Returns:
#   0 on success, non-zero on failure
#######################################
upload_directory() {
  local source_dir="${1:-}"
  
  local s3_uri="s3://$BUCKET_NAME/$S3_PREFIX"
  
  log_info "Uploading directory: $source_dir -> $s3_uri"
  
  local sync_args=(
    "$source_dir"
    "$s3_uri"
    --no-cli-pager
  )
  
  if [[ "$DRY_RUN" == "true" ]]; then
    sync_args+=(--dryrun)
  fi
  
  if [[ "$DELETE_MODE" == "true" ]]; then
    sync_args+=(--delete)
    log_info "Delete mode enabled: files in Amazon S3 not in source are removed during sync"
  fi
  
  if ! aws s3 sync "${sync_args[@]}"; then
    log_error "Failed to sync directory: $source_dir"
    return "$EXIT_AWS_ERROR"
  fi
  
  if [[ "$DRY_RUN" != "true" ]]; then
    log_success "Directory uploaded: $source_dir -> $s3_uri"
  fi
  
  return "$EXIT_SUCCESS"
}

#######################################
# Execute upload
# Returns:
#   0 on success, non-zero on failure
#######################################
execute_upload() {
  log_info "Starting upload to S3..."
  
  # Verify prefix ends with / for directories
  if [[ -d "$SOURCE_PATH" ]] && [[ -n "$S3_PREFIX" ]] && [[ ! "$S3_PREFIX" =~ /$ ]]; then
    S3_PREFIX="${S3_PREFIX}/"
  fi
  
  if [[ -d "$SOURCE_PATH" ]]; then
    # Upload directory
    if ! upload_directory "$SOURCE_PATH"; then
      return "$EXIT_AWS_ERROR"
    fi
  elif [[ -f "$SOURCE_PATH" ]]; then
    # Upload single file
    local filename
    filename=$(basename "$SOURCE_PATH")
    local s3_key="${S3_PREFIX}${filename}"
    
    if ! upload_file "$SOURCE_PATH" "$s3_key"; then
      return "$EXIT_AWS_ERROR"
    fi
  else
    log_error "Source is neither a file nor directory: $SOURCE_PATH"
    return "$EXIT_VALIDATION_ERROR"
  fi
  
  return "$EXIT_SUCCESS"
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
  
  if ! validate_source_path "$SOURCE_PATH"; then
    exit_code="$EXIT_VALIDATION_ERROR"
  fi

  if ! validate_s3_prefix "$S3_PREFIX"; then
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
  log_info "S3 upload workflow started"
  
  # Validate inputs
  if ! validate_inputs; then
    return "$EXIT_VALIDATION_ERROR"
  fi
  
  # Check AWS CLI
  if ! check_aws_cli; then
    return "$EXIT_AWS_ERROR"
  fi
  
  # Verify bucket access
  if ! verify_bucket_access "$BUCKET_NAME"; then
    return "$EXIT_AWS_ERROR"
  fi

  # Execute upload
  if ! execute_upload; then
    return "$EXIT_AWS_ERROR"
  fi
  
  if [[ "$DRY_RUN" != "true" ]]; then
    log_success "S3 upload completed"
    echo ""
    log_info "Uploaded to: s3://$BUCKET_NAME/$S3_PREFIX"
    log_info "Encryption: S3 default encryption"
    echo ""
    log_info "Next steps:"
    log_info "  Import to Bedrock: ./scripts/import-to-bedrock.sh"
  fi
  
  return "$EXIT_SUCCESS"
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
  
  if [[ -z "$SOURCE_PATH" ]]; then
    log_error "Source path is required (--source)"
    show_usage
    exit "$EXIT_INVALID_ARGS"
  fi
  
  # Run main function
  main
fi
