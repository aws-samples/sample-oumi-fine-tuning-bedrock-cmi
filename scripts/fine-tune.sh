#!/bin/bash
# Copyright Amazon.com, Inc. or its affiliates. All Rights Reserved.
# SPDX-License-Identifier: MIT-0
# Fine-Tuning Script for Amazon Bedrock Custom Model Import
#
# This script executes Oumi fine-tuning with the specified configuration
# and provides progress monitoring.
#
# Requirements: 5.1, 5.2, 5.3
#
# Usage:
#   ./fine-tune.sh --config <CONFIG_FILE> [OPTIONS] [-- OUMI_OVERRIDES...]
#
# Options:
#   --config          Path to Oumi configuration file (required)
#   --output-dir      Output directory for model artifacts (default: models/final)
#   --checkpoint-dir  Directory for checkpoints (default: models/checkpoints)
#   --max-steps N     Limit training to N steps (default: full run)
#   --resume          Resume from latest checkpoint
#   --dry-run         Validate configuration without training
#   -h, --help        Show this help message
#
# Extra Oumi overrides can be passed after "--", e.g.:
#   ./fine-tune.sh --config configs/oumi-config.yaml -- --training.max_steps 50

set -euo pipefail

# Exit codes
readonly EXIT_SUCCESS=0
readonly EXIT_INVALID_ARGS=1
readonly EXIT_AWS_ERROR=2
readonly EXIT_VALIDATION_ERROR=3
readonly EXIT_TRAINING_ERROR=4

# Color codes for output
readonly RED='\033[0;31m'
readonly GREEN='\033[0;32m'
readonly YELLOW='\033[1;33m'
readonly BLUE='\033[0;34m'
readonly NC='\033[0m' # No Color

# Default values
CONFIG_FILE=""
OUTPUT_DIR="models/final"
CHECKPOINT_DIR="models/checkpoints"
MAX_STEPS=""
RESUME_TRAINING=false
DRY_RUN=false
OUMI_EXTRA_ARGS=""

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
  echo "Fine-Tuning Script"
  echo ""
  echo "Usage:"
  echo "  $0 --config <CONFIG_FILE> [OPTIONS]"
  echo ""
  echo "Options:"
  echo "  --config          Path to Oumi configuration file (required)"
  echo "  --output-dir      Output directory for model artifacts (default: $OUTPUT_DIR)"
  echo "  --checkpoint-dir  Directory for checkpoints (default: $CHECKPOINT_DIR)"
  echo "  --max-steps N     Limit training to N steps (default: full run)"
  echo "  --resume          Resume from latest checkpoint"
  echo "  --dry-run         Validate configuration without training"
  echo "  -h, --help        Show this help message"
  echo ""
  echo "Extra Oumi overrides can be passed after '--', e.g.:"
  echo "  $0 --config configs/oumi-config.yaml -- --training.max_steps 50"
  echo ""
  echo "Exit codes:"
  echo "  0 - Success"
  echo "  1 - Invalid arguments"
  echo "  2 - AWS CLI error"
  echo "  3 - Validation error"
  echo "  4 - Training error"
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
      --config)
        if [[ -z "${2:-}" ]]; then
          log_error "Config argument requires a value"
          return "$EXIT_INVALID_ARGS"
        fi
        CONFIG_FILE="$2"
        shift 2
        ;;
      --output-dir)
        if [[ -z "${2:-}" ]]; then
          log_error "Output directory argument requires a value"
          return "$EXIT_INVALID_ARGS"
        fi
        OUTPUT_DIR="$2"
        shift 2
        ;;
      --checkpoint-dir)
        if [[ -z "${2:-}" ]]; then
          log_error "Checkpoint directory argument requires a value"
          return "$EXIT_INVALID_ARGS"
        fi
        CHECKPOINT_DIR="$2"
        shift 2
        ;;
      --max-steps)
        if [[ -z "${2:-}" ]]; then
          log_error "Max steps argument requires a value"
          return "$EXIT_INVALID_ARGS"
        fi
        MAX_STEPS="$2"
        shift 2
        ;;
      --resume)
        RESUME_TRAINING=true
        shift
        ;;
      --dry-run)
        DRY_RUN=true
        shift
        ;;
      -h|--help)
        show_usage
        exit "$EXIT_SUCCESS"
        ;;
      --)
        shift
        OUMI_EXTRA_ARGS="$*"
        break
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
# Validate configuration file path
# Arguments:
#   config_file: Path to configuration file
# Returns:
#   0 if valid, non-zero otherwise
#######################################
validate_config_file() {
  local config_file="${1:-}"
  
  if [[ -z "$config_file" ]]; then
    log_error "Configuration file is required (--config)"
    return "$EXIT_INVALID_ARGS"
  fi
  
  if [[ ! -f "$config_file" ]]; then
    log_error "Configuration file not found: $config_file"
    return "$EXIT_VALIDATION_ERROR"
  fi
  
  # Validate file extension
  if [[ ! "$config_file" =~ \.(yaml|yml|json)$ ]]; then
    log_error "Configuration file must be YAML or JSON: $config_file"
    return "$EXIT_VALIDATION_ERROR"
  fi
  
  # Validate YAML/JSON syntax
  if [[ "$config_file" =~ \.(yaml|yml)$ ]]; then
    if command -v python3 &> /dev/null; then
      if ! python3 -c "import yaml; yaml.safe_load(open('$config_file'))" 2>/dev/null; then
        log_error "Invalid YAML syntax in configuration file: $config_file"
        return "$EXIT_VALIDATION_ERROR"
      fi
    fi
  elif [[ "$config_file" =~ \.json$ ]]; then
    if ! python3 -m json.tool "$config_file" > /dev/null 2>&1; then
      log_error "Invalid JSON syntax in configuration file: $config_file"
      return "$EXIT_VALIDATION_ERROR"
    fi
  fi
  
  log_info "Configuration file validated: $config_file"
  return "$EXIT_SUCCESS"
}

#######################################
# Validate directory path
# Arguments:
#   dir_path: Directory path to validate
#   dir_name: Name for error messages
# Returns:
#   0 if valid, non-zero otherwise
#######################################
validate_directory() {
  local dir_path="${1:-}"
  local dir_name="${2:-directory}"
  
  if [[ -z "$dir_path" ]]; then
    log_error "$dir_name path is required"
    return "$EXIT_INVALID_ARGS"
  fi
  
  # Check for path traversal attempts
  if [[ "$dir_path" =~ \.\. ]]; then
    log_error "Invalid $dir_name path (path traversal not allowed): $dir_path"
    return "$EXIT_VALIDATION_ERROR"
  fi
  
  return "$EXIT_SUCCESS"
}

#######################################
# Create directory if it doesn't exist
# Arguments:
#   dir_path: Directory path to create
# Returns:
#   0 on success, non-zero on failure
#######################################
ensure_directory() {
  local dir_path="${1:-}"
  
  if [[ ! -d "$dir_path" ]]; then
    log_info "Creating directory: $dir_path"
    if ! mkdir -p "$dir_path"; then
      log_error "Failed to create directory: $dir_path"
      return "$EXIT_VALIDATION_ERROR"
    fi
  fi
  
  return "$EXIT_SUCCESS"
}

#######################################
# Check if Oumi is installed
# Returns:
#   0 if installed, non-zero otherwise
#######################################
check_oumi_installed() {
  log_info "Checking Oumi installation..."

  # Activate the project venv if it exists and isn't already active
  if [[ -f ".venv/bin/activate" && -z "${VIRTUAL_ENV:-}" ]]; then
    log_info "Activating virtual environment at .venv"
    source .venv/bin/activate
  fi

  local pip_cmd=""
  if command -v uv &> /dev/null; then
    pip_cmd="uv pip"
  elif command -v pip3 &> /dev/null; then
    pip_cmd="pip3"
  elif command -v pip &> /dev/null; then
    pip_cmd="pip"
  else
    log_error "pip is not installed"
    return "$EXIT_VALIDATION_ERROR"
  fi

  if ! $pip_cmd show oumi &> /dev/null; then
    log_error "Oumi framework is not installed"
    log_info "Run: ./scripts/setup-environment.sh"
    return "$EXIT_VALIDATION_ERROR"
  fi

  local oumi_version
  oumi_version=$($pip_cmd show oumi 2>/dev/null | grep -E '^Version:' | awk '{print $2}')
  log_info "Oumi version: $oumi_version"

  return "$EXIT_SUCCESS"
}

#######################################
# Find latest checkpoint for resuming
# Arguments:
#   checkpoint_dir: Directory containing checkpoints
# Returns:
#   Path to latest checkpoint via stdout, or empty if none found
#######################################
find_latest_checkpoint() {
  local checkpoint_dir="${1:-}"
  
  if [[ ! -d "$checkpoint_dir" ]]; then
    return "$EXIT_SUCCESS"
  fi
  
  # Find the most recent checkpoint directory
  local latest
  latest=$(find "$checkpoint_dir" -maxdepth 1 -type d -name "checkpoint-*" 2>/dev/null | sort -V | tail -1)
  
  if [[ -n "$latest" ]]; then
    echo "$latest"
  fi
  
  return "$EXIT_SUCCESS"
}

#######################################
# Monitor training progress
# Arguments:
#   log_file: Path to training log file
#######################################
monitor_progress() {
  local log_file="${1:-}"
  
  if [[ ! -f "$log_file" ]]; then
    return
  fi
  
  # Extract and display progress information
  local last_step
  local total_steps
  local loss
  
  last_step=$(grep -oE 'step [0-9]+' "$log_file" 2>/dev/null | tail -1 | grep -oE '[0-9]+' || echo "0")
  total_steps=$(grep -oE 'total_steps[=:]\s*[0-9]+' "$log_file" 2>/dev/null | tail -1 | grep -oE '[0-9]+' || echo "unknown")
  loss=$(grep -oE 'loss[=:]\s*[0-9.]+' "$log_file" 2>/dev/null | tail -1 | grep -oE '[0-9.]+' || echo "N/A")
  
  log_progress "Step: $last_step / $total_steps, Loss: $loss"
}

#######################################
# Execute fine-tuning
# Returns:
#   0 on success, non-zero on failure
#######################################
execute_fine_tuning() {
  log_info "Starting fine-tuning..."
  
  # Build Oumi command
  local oumi_cmd="oumi train"
  oumi_cmd="$oumi_cmd -c $CONFIG_FILE"
  oumi_cmd="$oumi_cmd --training.output_dir $OUTPUT_DIR"

  # Limit training steps if requested
  if [[ -n "$MAX_STEPS" ]]; then
    oumi_cmd="$oumi_cmd --training.max_steps $MAX_STEPS"
  fi

  # Append extra Oumi overrides passed after "--"
  if [[ -n "$OUMI_EXTRA_ARGS" ]]; then
    oumi_cmd="$oumi_cmd $OUMI_EXTRA_ARGS"
  fi

  # Resume from checkpoint if requested
  if [[ "$RESUME_TRAINING" == "true" ]]; then
    local latest_checkpoint
    latest_checkpoint=$(find_latest_checkpoint "$CHECKPOINT_DIR")

    if [[ -n "$latest_checkpoint" ]]; then
      log_info "Resuming from checkpoint: $latest_checkpoint"
      oumi_cmd="$oumi_cmd --training.resume_from_checkpoint $latest_checkpoint"
    else
      log_info "No checkpoint found, starting fresh training"
    fi
  fi
  
  # Dry run mode
  if [[ "$DRY_RUN" == "true" ]]; then
    log_info "Dry run mode - command that would be executed:"
    echo "  $oumi_cmd"
    return "$EXIT_SUCCESS"
  fi
  
  # Create log file for progress monitoring
  local log_file="logs/training_$(date +%Y%m%d_%H%M%S).log"
  ensure_directory "logs"
  
  log_info "Training log: $log_file"
  log_info "Executing: $oumi_cmd"
  
  # Execute training with progress monitoring
  local start_time
  start_time=$(date +%s)
  
  # Run training and capture output
  if ! eval "$oumi_cmd" 2>&1 | tee "$log_file"; then
    log_error "Fine-tuning failed"
    log_error "Check log file for details: $log_file"
    return "$EXIT_TRAINING_ERROR"
  fi
  
  local end_time
  end_time=$(date +%s)
  local duration=$((end_time - start_time))
  
  log_success "Fine-tuning completed in $duration seconds"
  log_info "Model artifacts saved to: $OUTPUT_DIR"
  
  return "$EXIT_SUCCESS"
}

#######################################
# Validate all inputs
# Returns:
#   0 if all inputs are valid, non-zero otherwise
#######################################
validate_inputs() {
  local exit_code=0
  
  # Validate config file
  if ! validate_config_file "$CONFIG_FILE"; then
    exit_code="$EXIT_VALIDATION_ERROR"
  fi
  
  # Validate output directory
  if ! validate_directory "$OUTPUT_DIR" "Output"; then
    exit_code="$EXIT_VALIDATION_ERROR"
  fi
  
  # Validate checkpoint directory
  if ! validate_directory "$CHECKPOINT_DIR" "Checkpoint"; then
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
  log_info "Fine-tuning workflow started"
  
  # Validate inputs
  if ! validate_inputs; then
    return "$EXIT_VALIDATION_ERROR"
  fi
  
  # Check Oumi installation
  if ! check_oumi_installed; then
    return "$EXIT_VALIDATION_ERROR"
  fi
  
  # Create required directories if they do not exist
  if ! ensure_directory "$OUTPUT_DIR"; then
    return "$EXIT_VALIDATION_ERROR"
  fi
  
  if ! ensure_directory "$CHECKPOINT_DIR"; then
    return "$EXIT_VALIDATION_ERROR"
  fi
  
  # Execute fine-tuning
  if ! execute_fine_tuning; then
    return "$EXIT_TRAINING_ERROR"
  fi
  
  log_success "Fine-tuning workflow completed"
  echo ""
  log_info "Next steps:"
  log_info "  1. Verify model artifacts in: $OUTPUT_DIR"
  log_info "  2. Upload to S3: ./scripts/upload-to-s3.sh"
  log_info "  3. Import to Bedrock: ./scripts/import-to-bedrock.sh"
  
  return "$EXIT_SUCCESS"
}

# Main execution
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
  # Parse command line arguments
  if ! parse_arguments "$@"; then
    exit "$EXIT_INVALID_ARGS"
  fi
  
  # Check if config file is provided
  if [[ -z "$CONFIG_FILE" ]]; then
    log_error "Configuration file is required"
    show_usage
    exit "$EXIT_INVALID_ARGS"
  fi
  
  # Run main function
  main
fi
