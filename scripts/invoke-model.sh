#!/bin/bash
# Copyright Amazon.com, Inc. or its affiliates. All Rights Reserved.
# SPDX-License-Identifier: MIT-0
# Amazon Bedrock Model Invocation Script
#
# This script invokes an imported model via the Amazon Bedrock Runtime API.
#
# Requirements: 5.1, 5.2, 5.3
#
# Usage:
#   ./invoke-model.sh --model-id <MODEL_ID> --prompt <PROMPT> [OPTIONS]
#
# Options:
#   --model-id        Model ID or ARN to invoke (required)
#   --prompt          Input prompt text (required unless --prompt-file is used)
#   --prompt-file     File containing the input prompt
#   --max-tokens      Maximum tokens to generate (default: 512)
#   --temperature     Temperature for generation (default: 0.7)
#   --top-p           Top-p sampling parameter (default: 0.9)
#   --output-file     File to save the response
#   --raw             Output raw JSON response
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
MODEL_ID=""
PROMPT=""
PROMPT_FILE=""
MAX_TOKENS=512
TEMPERATURE="0.7"
TOP_P="0.9"
OUTPUT_FILE=""
RAW_OUTPUT=false

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
  echo "Invoke Model Script"
  echo ""
  echo "Usage:"
  echo "  $0 --model-id <MODEL_ID> --prompt <PROMPT> [OPTIONS]"
  echo "  $0 --model-id <MODEL_ID> --prompt-file <FILE> [OPTIONS]"
  echo ""
  echo "Options:"
  echo "  --model-id        Model ID or ARN to invoke (required)"
  echo "  --prompt          Input prompt text (required unless --prompt-file is used)"
  echo "  --prompt-file     File containing the input prompt"
  echo "  --max-tokens      Maximum tokens to generate (default: $MAX_TOKENS)"
  echo "  --temperature     Temperature for generation (default: $TEMPERATURE)"
  echo "  --top-p           Top-p sampling parameter (default: $TOP_P)"
  echo "  --output-file     File to save the response"
  echo "  --raw             Output raw JSON response"
  echo "  -h, --help        Show this help message"
  echo ""
  echo "Examples:"
  echo "  $0 --model-id my-model --prompt 'What is machine learning?'"
  echo "  $0 --model-id my-model --prompt-file prompt.txt --output-file response.txt"
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
      --model-id)
        if [[ -z "${2:-}" ]]; then
          log_error "Model ID argument requires a value"
          return "$EXIT_INVALID_ARGS"
        fi
        MODEL_ID="$2"
        shift 2
        ;;
      --prompt)
        if [[ -z "${2:-}" ]]; then
          log_error "Prompt argument requires a value"
          return "$EXIT_INVALID_ARGS"
        fi
        PROMPT="$2"
        shift 2
        ;;
      --prompt-file)
        if [[ -z "${2:-}" ]]; then
          log_error "Prompt file argument requires a value"
          return "$EXIT_INVALID_ARGS"
        fi
        PROMPT_FILE="$2"
        shift 2
        ;;
      --max-tokens)
        if [[ -z "${2:-}" ]]; then
          log_error "Max tokens argument requires a value"
          return "$EXIT_INVALID_ARGS"
        fi
        MAX_TOKENS="$2"
        shift 2
        ;;
      --temperature)
        if [[ -z "${2:-}" ]]; then
          log_error "Temperature argument requires a value"
          return "$EXIT_INVALID_ARGS"
        fi
        TEMPERATURE="$2"
        shift 2
        ;;
      --top-p)
        if [[ -z "${2:-}" ]]; then
          log_error "Top-p argument requires a value"
          return "$EXIT_INVALID_ARGS"
        fi
        TOP_P="$2"
        shift 2
        ;;
      --output-file)
        if [[ -z "${2:-}" ]]; then
          log_error "Output file argument requires a value"
          return "$EXIT_INVALID_ARGS"
        fi
        OUTPUT_FILE="$2"
        shift 2
        ;;
      --raw)
        RAW_OUTPUT=true
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
# Validate model ID format
# Arguments:
#   model_id: Model ID to validate
# Returns:
#   0 if valid, non-zero otherwise
#######################################
validate_model_id() {
  local model_id="${1:-}"
  
  if [[ -z "$model_id" ]]; then
    log_error "Model ID is required"
    return "$EXIT_INVALID_ARGS"
  fi
  
  # Model ID can be a name or ARN
  # Name: alphanumeric, hyphens, underscores
  # ARN: arn:aws:bedrock:region:account:imported-model/name
  local name_pattern='^[a-zA-Z0-9][a-zA-Z0-9_-]{0,62}$'
  local arn_pattern='^arn:aws:bedrock:[a-z0-9-]+:[0-9]{12}:(imported-model|custom-model)/[a-zA-Z0-9_-]+$'
  
  if [[ ! "$model_id" =~ $name_pattern ]] && [[ ! "$model_id" =~ $arn_pattern ]]; then
    log_error "Invalid model ID format: $model_id"
    log_error "Expected: model name or ARN"
    return "$EXIT_VALIDATION_ERROR"
  fi
  
  return "$EXIT_SUCCESS"
}

#######################################
# Validate prompt is provided
# Returns:
#   0 if valid, non-zero otherwise
#######################################
validate_prompt() {
  if [[ -z "$PROMPT" ]] && [[ -z "$PROMPT_FILE" ]]; then
    log_error "Either --prompt or --prompt-file is required"
    return "$EXIT_INVALID_ARGS"
  fi
  
  if [[ -n "$PROMPT_FILE" ]]; then
    if [[ ! -f "$PROMPT_FILE" ]]; then
      log_error "Prompt file not found: $PROMPT_FILE"
      return "$EXIT_VALIDATION_ERROR"
    fi
    
    # Read prompt from file
    PROMPT=$(cat "$PROMPT_FILE")
    
    if [[ -z "$PROMPT" ]]; then
      log_error "Prompt file is empty: $PROMPT_FILE"
      return "$EXIT_VALIDATION_ERROR"
    fi
  fi
  
  return "$EXIT_SUCCESS"
}

#######################################
# Validate max tokens is a positive integer
# Arguments:
#   max_tokens: Max tokens value to validate
# Returns:
#   0 if valid, non-zero otherwise
#######################################
validate_max_tokens() {
  local max_tokens="${1:-}"
  
  if [[ ! "$max_tokens" =~ ^[0-9]+$ ]] || [[ "$max_tokens" -lt 1 ]]; then
    log_error "Max tokens must be a positive integer: $max_tokens"
    return "$EXIT_VALIDATION_ERROR"
  fi
  
  if [[ "$max_tokens" -gt 4096 ]]; then
    log_error "Max tokens cannot exceed 4096: $max_tokens"
    return "$EXIT_VALIDATION_ERROR"
  fi
  
  return "$EXIT_SUCCESS"
}

#######################################
# Validate temperature is a valid float
# Arguments:
#   temperature: Temperature value to validate
# Returns:
#   0 if valid, non-zero otherwise
#######################################
validate_temperature() {
  local temperature="${1:-}"
  
  if [[ ! "$temperature" =~ ^[0-9]*\.?[0-9]+$ ]]; then
    log_error "Temperature must be a number: $temperature"
    return "$EXIT_VALIDATION_ERROR"
  fi
  
  # Check range 0.0 to 1.0
  if ! python3 -c "exit(0 if 0.0 <= float('$temperature') <= 1.0 else 1)" 2>/dev/null; then
    log_error "Temperature must be between 0.0 and 1.0: $temperature"
    return "$EXIT_VALIDATION_ERROR"
  fi
  
  return "$EXIT_SUCCESS"
}

#######################################
# Validate top-p is a valid float
# Arguments:
#   top_p: Top-p value to validate
# Returns:
#   0 if valid, non-zero otherwise
#######################################
validate_top_p() {
  local top_p="${1:-}"
  
  if [[ ! "$top_p" =~ ^[0-9]*\.?[0-9]+$ ]]; then
    log_error "Top-p must be a number: $top_p"
    return "$EXIT_VALIDATION_ERROR"
  fi
  
  # Check range 0.0 to 1.0
  if ! python3 -c "exit(0 if 0.0 <= float('$top_p') <= 1.0 else 1)" 2>/dev/null; then
    log_error "Top-p must be between 0.0 and 1.0: $top_p"
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
# Sanitize input string to prevent command injection
# Arguments:
#   input: String to sanitize
# Returns:
#   Sanitized string via stdout
#######################################
sanitize_input() {
  local input="${1:-}"
  # Remove shell metacharacters that could enable command injection
  # Block dangerous characters: $ ` \ ! & | ; < > ( ) { } [ ] * ?
  # Allow only alphanumeric, spaces, and safe punctuation for prompts
  # Note: This is defense-in-depth; primary protection is stdin-based processing
  echo "$input" | tr -cd '[:alnum:][:space:].,!?:_@#%+=/"-'"'"
}

#######################################
# Escape string for JSON
# Arguments:
#   string: String to escape
# Returns:
#   Escaped string via stdout
#######################################
escape_json_string() {
  local string="${1:-}"

  # Sanitize input first to prevent command injection
  local sanitized
  sanitized=$(sanitize_input "$string")
  
  # Use stdin-based approach to prevent command injection
  printf '%s' "$sanitized" | python3 -c "import sys, json; print(json.dumps(sys.stdin.read())[1:-1])"
}

#######################################
# Build request payload
# Returns:
#   JSON payload via stdout
#######################################
build_request_payload() {
  # Sanitize and escape the prompt for JSON using stdin to prevent command injection
  local sanitized_prompt
  sanitized_prompt=$(sanitize_input "$PROMPT")
  
  local escaped_prompt
  escaped_prompt=$(printf '%s' "$sanitized_prompt" | python3 -c "import sys, json; print(json.dumps(sys.stdin.read()))")
  
  # Build the payload using the Llama model format expected by Bedrock imported models
  cat <<EOF
{
  "prompt": $escaped_prompt,
  "max_gen_len": $MAX_TOKENS,
  "temperature": $TEMPERATURE,
  "top_p": $TOP_P
}
EOF
}

#######################################
# Invoke the model
# Returns:
#   0 on success, non-zero on failure
#######################################
invoke_model() {
  log_info "Invoking model: $MODEL_ID"
  
  # Build request payload
  local payload
  payload=$(build_request_payload)
  
  log_info "Request parameters:"
  log_info "  Max tokens: $MAX_TOKENS"
  log_info "  Temperature: $TEMPERATURE"
  log_info "  Top-p: $TOP_P"
  
  # Create temporary file for payload
  local payload_file
  payload_file=$(mktemp)
  echo "$payload" > "$payload_file"
  
  # Create temporary file for response
  local response_file
  response_file=$(mktemp)
  
  # Invoke the model
  if ! aws bedrock-runtime invoke-model \
    --model-id "$MODEL_ID" \
    --body "fileb://$payload_file" \
    --content-type "application/json" \
    --accept "application/json" \
    "$response_file" \
    --no-cli-pager 2>&1; then
    log_error "Failed to invoke model"
    rm -f "$payload_file" "$response_file"
    return "$EXIT_AWS_ERROR"
  fi
  
  # Read and process response
  local response
  response=$(cat "$response_file")
  
  # Clean up temporary files
  rm -f "$payload_file" "$response_file"
  
  # Output response
  if [[ "$RAW_OUTPUT" == "true" ]]; then
    echo "$response"
  else
    # Try to extract the generated text from common response formats
    local generated_text
    generated_text=$(echo "$response" | python3 -c "
import sys, json
try:
    data = json.load(sys.stdin)
    # Try common response formats
    if 'completion' in data:
        print(data['completion'])
    elif 'generation' in data:
        print(data['generation'])
    elif 'generated_text' in data:
        print(data['generated_text'])
    elif 'outputs' in data and len(data['outputs']) > 0:
        print(data['outputs'][0].get('text', ''))
    elif 'results' in data and len(data['results']) > 0:
        print(data['results'][0].get('outputText', ''))
    else:
        # Fallback: print the whole response
        print(json.dumps(data, indent=2))
except Exception as e:
    print(f'Error parsing response: {e}', file=sys.stderr)
    sys.exit(1)
" 2>/dev/null) || generated_text="$response"
    
    echo ""
    echo "=== Model Response ==="
    echo "$generated_text"
    echo "======================"
  fi
  
  # Save to file if requested
  if [[ -n "$OUTPUT_FILE" ]]; then
    if [[ "$RAW_OUTPUT" == "true" ]]; then
      echo "$response" > "$OUTPUT_FILE"
    else
      echo "$generated_text" > "$OUTPUT_FILE"
    fi
    log_success "Response saved to: $OUTPUT_FILE"
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
  
  if ! validate_model_id "$MODEL_ID"; then
    exit_code="$EXIT_VALIDATION_ERROR"
  fi
  
  if ! validate_prompt; then
    exit_code="$EXIT_VALIDATION_ERROR"
  fi
  
  if ! validate_max_tokens "$MAX_TOKENS"; then
    exit_code="$EXIT_VALIDATION_ERROR"
  fi
  
  if ! validate_temperature "$TEMPERATURE"; then
    exit_code="$EXIT_VALIDATION_ERROR"
  fi
  
  if ! validate_top_p "$TOP_P"; then
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
  log_info "Model invocation started"
  
  # Validate inputs
  if ! validate_inputs; then
    return "$EXIT_VALIDATION_ERROR"
  fi
  
  # Check AWS CLI
  if ! check_aws_cli; then
    return "$EXIT_AWS_ERROR"
  fi
  
  # Invoke the model
  if ! invoke_model; then
    return "$EXIT_AWS_ERROR"
  fi
  
  log_success "Model invocation completed"
  return "$EXIT_SUCCESS"
}

# Main execution
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
  # Parse command line arguments
  if ! parse_arguments "$@"; then
    exit "$EXIT_INVALID_ARGS"
  fi
  
  # Check required arguments
  if [[ -z "$MODEL_ID" ]]; then
    log_error "Model ID is required (--model-id)"
    show_usage
    exit "$EXIT_INVALID_ARGS"
  fi
  
  if [[ -z "$PROMPT" ]] && [[ -z "$PROMPT_FILE" ]]; then
    log_error "Either --prompt or --prompt-file is required"
    show_usage
    exit "$EXIT_INVALID_ARGS"
  fi
  
  # Run main function
  main
fi
