#!/bin/bash
# Copyright Amazon.com, Inc. or its affiliates. All Rights Reserved.
# SPDX-License-Identifier: MIT-0
# Setup Environment Script for Amazon Bedrock Fine-Tuning
#
# This script installs the Oumi framework and dependencies, configures AWS Command Line Interface (AWS CLI),
# and validates prerequisites for the fine-tuning workflow.
#
# Security Validations:
#   - AWS CLI credential verification (no hardcoded credentials)
#   - GPU availability check for compute requirements
#   - Python environment isolation
#
# Requirements: 5.1, 5.2, 5.3
#
# Usage:
#   ./setup-environment.sh [OPTIONS]
#
# Options:
#   --skip-oumi       Skip Oumi framework installation
#   --skip-aws-check  Skip AWS CLI configuration check
#   --python-version  Specify Python version (default: 3.11)
#   --use-pip         Fall back to pip instead of uv
#   --skip-hf-auth    Skip Hugging Face authentication
#   -h, --help        Show this help message

set -euo pipefail

# Exit codes
readonly EXIT_SUCCESS=0
readonly EXIT_INVALID_ARGS=1
readonly EXIT_AWS_ERROR=2
readonly EXIT_VALIDATION_ERROR=3
readonly EXIT_INSTALL_ERROR=4

# Color codes for output
readonly RED='\033[0;31m'
readonly GREEN='\033[0;32m'
readonly YELLOW='\033[1;33m'
readonly NC='\033[0m' # No Color

# Default values
DEFAULT_PYTHON_VERSION="3.11"
SKIP_OUMI=false
SKIP_AWS_CHECK=false
PYTHON_VERSION=""
USE_UV=true
HF_AUTH_REQUIRED=true

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
  echo "Setup Environment Script"
  echo ""
  echo "Usage:"
  echo "  $0 [OPTIONS]"
  echo ""
  echo "Options:"
  echo "  --skip-oumi         Skip Oumi framework installation"
  echo "  --skip-aws-check    Skip AWS CLI configuration check"
  echo "  --python-version    Specify Python version (default: $DEFAULT_PYTHON_VERSION)"
  echo "  --use-pip           Fall back to pip instead of uv"
  echo "  --skip-hf-auth      Skip Hugging Face authentication"
  echo "  -h, --help          Show this help message"
  echo ""
  echo "Exit codes:"
  echo "  0 - Success"
  echo "  1 - Invalid arguments"
  echo "  2 - AWS CLI error"
  echo "  3 - Validation error"
  echo "  4 - Installation error"
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
      --skip-oumi)
        SKIP_OUMI=true
        shift
        ;;
      --skip-aws-check)
        SKIP_AWS_CHECK=true
        shift
        ;;
      --python-version)
        if [[ -z "${2:-}" ]]; then
          log_error "Python version argument requires a value"
          return "$EXIT_INVALID_ARGS"
        fi
        PYTHON_VERSION="$2"
        shift 2
        ;;
      --use-pip)
        USE_UV=false
        shift
        ;;
      --skip-hf-auth)
        HF_AUTH_REQUIRED=false
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
  
  # Set default Python version if not specified
  if [[ -z "$PYTHON_VERSION" ]]; then
    PYTHON_VERSION="$DEFAULT_PYTHON_VERSION"
  fi
  
  return "$EXIT_SUCCESS"
}

#######################################
# Validate Python version format
# Arguments:
#   version: Python version string (e.g., "3.10")
# Returns:
#   0 if valid, non-zero otherwise
#######################################
validate_python_version() {
  local version="${1:-}"
  
  if [[ -z "$version" ]]; then
    log_error "Python version is required"
    return "$EXIT_INVALID_ARGS"
  fi
  
  # Validate version format (major.minor)
  if [[ ! "$version" =~ ^[0-9]+\.[0-9]+$ ]]; then
    log_error "Invalid Python version format: $version (expected format: X.Y)"
    return "$EXIT_VALIDATION_ERROR"
  fi
  
  # Extract major and minor versions
  local major="${version%%.*}"
  local minor="${version#*.}"
  
  # Validate Python 3.8+ is required for Oumi
  if [[ "$major" -lt 3 ]] || { [[ "$major" -eq 3 ]] && [[ "$minor" -lt 8 ]]; }; then
    log_error "Python version must be 3.8 or higher for Oumi framework"
    return "$EXIT_VALIDATION_ERROR"
  fi
  
  return "$EXIT_SUCCESS"
}

#######################################
# Check if a command exists
# Arguments:
#   command_name: Name of the command to check
# Returns:
#   0 if command exists, non-zero otherwise
#######################################
command_exists() {
  local command_name="${1:-}"
  
  if [[ -z "$command_name" ]]; then
    return "$EXIT_INVALID_ARGS"
  fi
  
  command -v "$command_name" &> /dev/null
}

#######################################
# Check Python installation
# Returns:
#   0 if Python is installed, non-zero otherwise
#######################################
check_python() {
  log_info "Checking Python installation..."
  
  local python_cmd=""
  
  # Try python3 first, then python
  if command_exists "python3"; then
    python_cmd="python3"
  elif command_exists "python"; then
    python_cmd="python"
  else
    log_error "Python is not installed or not in PATH"
    return "$EXIT_VALIDATION_ERROR"
  fi
  
  # Get installed Python version
  local installed_version
  installed_version=$($python_cmd --version 2>&1 | grep -oE '[0-9]+\.[0-9]+' | head -1)
  
  if [[ -z "$installed_version" ]]; then
    log_error "Could not determine Python version"
    return "$EXIT_VALIDATION_ERROR"
  fi
  
  log_info "Found Python version: $installed_version"
  
  # Validate version meets requirements
  local major="${installed_version%%.*}"
  local minor="${installed_version#*.}"
  minor="${minor%%.*}"
  
  if [[ "$major" -lt 3 ]] || { [[ "$major" -eq 3 ]] && [[ "$minor" -lt 8 ]]; }; then
    log_error "Python 3.8+ is required, found: $installed_version"
    return "$EXIT_VALIDATION_ERROR"
  fi
  
  log_success "Python $installed_version meets requirements"
  return "$EXIT_SUCCESS"
}

#######################################
# Check pip installation
# Returns:
#   0 if pip is installed, non-zero otherwise
#######################################
check_pip() {
  log_info "Checking pip installation..."
  
  local pip_cmd=""
  
  # Try pip3 first, then pip
  if command_exists "pip3"; then
    pip_cmd="pip3"
  elif command_exists "pip"; then
    pip_cmd="pip"
  else
    log_error "pip is not installed or not in PATH"
    return "$EXIT_VALIDATION_ERROR"
  fi
  
  local pip_version
  pip_version=$($pip_cmd --version 2>&1 | grep -oE '[0-9]+\.[0-9]+' | head -1)
  
  log_success "pip $pip_version is installed"
  return "$EXIT_SUCCESS"
}

#######################################
# Check AWS CLI installation and configuration
# Returns:
#   0 if AWS CLI is configured, non-zero otherwise
#######################################
check_aws_cli() {
  log_info "Checking AWS CLI installation..."
  
  if ! command_exists "aws"; then
    log_error "AWS CLI is not installed or not in PATH"
    log_info "Install AWS CLI: https://docs.aws.amazon.com/cli/latest/userguide/getting-started-install.html"
    return "$EXIT_AWS_ERROR"
  fi
  
  local aws_version
  aws_version=$(aws --version 2>&1 | grep -oE 'aws-cli/[0-9]+\.[0-9]+' | head -1)
  log_info "Found $aws_version"
  
  log_info "Checking AWS credentials..."
  
  if ! aws sts get-caller-identity --no-cli-pager &> /dev/null; then
    log_error "AWS credentials are not configured or invalid"
    log_info "Configure credentials: aws configure"
    return "$EXIT_AWS_ERROR"
  fi
  
  local account_id
  local region
  account_id=$(aws sts get-caller-identity --query 'Account' --output text --no-cli-pager)
  region=$(aws configure get region --no-cli-pager 2>/dev/null || echo "not set")
  
  log_success "AWS CLI configured for account: $account_id, region: $region"
  return "$EXIT_SUCCESS"
}

#######################################
# Check CUDA/GPU availability (optional for fine-tuning)
# Returns:
#   0 if GPU is available, non-zero otherwise
#######################################
check_gpu() {
  log_info "Checking GPU availability..."
  
  if command_exists "nvidia-smi"; then
    local gpu_info
    gpu_info=$(nvidia-smi --query-gpu=name,memory.total --format=csv,noheader 2>/dev/null || echo "")
    
    if [[ -n "$gpu_info" ]]; then
      log_success "GPU detected: $gpu_info"
      return "$EXIT_SUCCESS"
    fi
  fi
  
  log_info "No NVIDIA GPU detected (fine-tuning will use CPU, which is slower)"
  return "$EXIT_SUCCESS"  # Not a failure, just informational
}

#######################################
# Detect OS type
# Returns:
#   Outputs: "amazon-linux", "ubuntu", "macos", or "other"
#######################################
detect_os_type() {
  if [[ "$(uname)" == "Darwin" ]]; then
    echo "macos"
  elif [[ -f /etc/os-release ]]; then
    local os_id
    os_id=$(grep -oP '(?<=^ID=).+' /etc/os-release | tr -d '"')
    case "$os_id" in
      amzn)
        echo "amazon-linux"
        ;;
      ubuntu)
        echo "ubuntu"
        ;;
      *)
        echo "other"
        ;;
    esac
  else
    echo "other"
  fi
}

#######################################
# Install uv package manager
# Returns:
#   0 on success, non-zero on failure
#######################################
install_uv() {
  log_info "Installing uv package manager..."

  if command_exists "uv"; then
    local uv_version
    uv_version=$(uv --version 2>&1 | head -1)
    log_success "uv is already installed: $uv_version"
    return "$EXIT_SUCCESS"
  fi

  if ! curl -LsSf https://astral.sh/uv/install.sh | sh; then
    log_error "Failed to install uv"
    return "$EXIT_INSTALL_ERROR"
  fi

  # Source the shell config to make uv available
  if [[ -f "$HOME/.local/bin/uv" ]]; then
    export PATH="$HOME/.local/bin:$PATH"
  fi

  if ! command_exists "uv"; then
    log_error "uv installation completed but command not found in PATH"
    return "$EXIT_INSTALL_ERROR"
  fi

  local uv_version
  uv_version=$(uv --version 2>&1 | head -1)
  log_success "uv installed: $uv_version"
  return "$EXIT_SUCCESS"
}

#######################################
# Create Python virtual environment with uv
# Returns:
#   0 on success, non-zero on failure
#######################################
create_uv_venv() {
  log_info "Creating Python virtual environment with uv..."

  if [[ -d ".venv" ]]; then
    log_info "Virtual environment already exists at .venv"
    return "$EXIT_SUCCESS"
  fi

  if ! uv venv --python "$PYTHON_VERSION" 2>&1; then
    log_error "Failed to create virtual environment with Python $PYTHON_VERSION"
    return "$EXIT_INSTALL_ERROR"
  fi

  log_success "Virtual environment created at .venv"
  log_info "Activate with: source .venv/bin/activate"
  return "$EXIT_SUCCESS"
}

#######################################
# Install system dependencies based on OS
# Returns:
#   0 on success, non-zero on failure
#######################################
install_system_dependencies() {
  log_info "Installing system dependencies..."

  local os_type
  os_type=$(detect_os_type)

  case "$os_type" in
    amazon-linux)
      log_info "Detected Amazon Linux, installing packages with yum..."
      local packages_to_install=()
      for pkg in git curl tar gzip; do
        if ! command_exists "$pkg"; then
          packages_to_install+=("$pkg")
        fi
      done
      if [[ ${#packages_to_install[@]} -gt 0 ]]; then
        if command_exists "sudo"; then
          sudo yum install -y "${packages_to_install[@]}" || {
            log_error "Failed to install system packages"
            return "$EXIT_INSTALL_ERROR"
          }
        else
          yum install -y "${packages_to_install[@]}" || {
            log_error "Failed to install system packages"
            return "$EXIT_INSTALL_ERROR"
          }
        fi
      else
        log_info "All required system packages already installed"
      fi
      ;;
    ubuntu)
      log_info "Detected Ubuntu, installing packages with apt..."
      if command_exists "sudo"; then
        sudo apt-get update && sudo apt-get install -y git curl || {
          log_error "Failed to install system packages"
          return "$EXIT_INSTALL_ERROR"
        }
      else
        apt-get update && apt-get install -y git curl || {
          log_error "Failed to install system packages"
          return "$EXIT_INSTALL_ERROR"
        }
      fi
      ;;
    macos)
      log_info "Detected macOS, skipping system package installation"
      ;;
    *)
      log_info "Unknown OS type, skipping system package installation"
      ;;
  esac

  log_success "System dependencies check completed"
  return "$EXIT_SUCCESS"
}

#######################################
# Set up Hugging Face authentication
# Returns:
#   0 on success, non-zero on failure
#######################################
setup_huggingface_auth() {
  log_info "Checking Hugging Face authentication..."

  # Check for HF_TOKEN environment variable
  if [[ -n "${HF_TOKEN:-}" ]]; then
    log_success "HF_TOKEN environment variable is set"
    return "$EXIT_SUCCESS"
  fi

  # Check for cached token
  local hf_token_file="$HOME/.cache/huggingface/token"
  if [[ -f "$hf_token_file" ]]; then
    log_success "Hugging Face token found in cache"
    return "$EXIT_SUCCESS"
  fi

  log_info "No Hugging Face token found"
  log_info "Please run 'hf auth login' to authenticate"
  log_info "This is required for downloading gated models like Llama"

  if command_exists "hf"; then
    echo ""
    read -p "Would you like to login now? (y/N): " -r response
    if [[ "$response" =~ ^[Yy]$ ]]; then
      hf auth login
      return $?
    fi
  fi

  log_info "Skipping Hugging Face login for now"
  return "$EXIT_SUCCESS"
}

#######################################
# Install Oumi framework
# Returns:
#   0 on success, non-zero on failure
#######################################
install_oumi() {
  log_info "Installing Oumi framework..."

  local pip_cmd=""
  if [[ "$USE_UV" == "true" ]] && command_exists "uv"; then
    pip_cmd="uv pip"
  elif command_exists "pip3"; then
    pip_cmd="pip3"
  else
    pip_cmd="pip"
  fi

  # Install Oumi with GPU extra and s3fs for direct S3 access
  # Pin lm-eval to 0.4.5: newer versions (0.4.11) pass dtype= to transformers
  # from_pretrained(), which is incompatible with transformers 4.45.x pinned by Oumi.
  log_info "Installing oumi[gpu], lm-eval==0.4.5, and s3fs..."
  if ! $pip_cmd install --upgrade "oumi[gpu]" "lm-eval[wandb]==0.4.5" s3fs 2>&1; then
    log_error "Failed to install Oumi framework"
    return "$EXIT_INSTALL_ERROR"
  fi

  # Verify installation
  local show_cmd=""
  if [[ "$USE_UV" == "true" ]] && command_exists "uv"; then
    show_cmd="uv pip show"
  elif command_exists "pip3"; then
    show_cmd="pip3 show"
  else
    show_cmd="pip show"
  fi

  if ! $show_cmd oumi &> /dev/null; then
    log_error "Oumi installation verification failed"
    return "$EXIT_INSTALL_ERROR"
  fi

  local oumi_version
  oumi_version=$($show_cmd oumi 2>/dev/null | grep -E '^Version:' | awk '{print $2}')

  log_success "Oumi framework installed: version $oumi_version"
  return "$EXIT_SUCCESS"
}

#######################################
# Create project directory structure
# Returns:
#   0 on success, non-zero on failure
#######################################
create_directory_structure() {
  log_info "Creating project directory structure..."
  
  local directories=(
    "data/raw"
    "data/processed"
    "models/checkpoints"
    "models/final"
    "logs"
    "configs"
  )
  
  for dir in "${directories[@]}"; do
    if [[ ! -d "$dir" ]]; then
      if ! mkdir -p "$dir"; then
        log_error "Failed to create directory: $dir"
        return "$EXIT_VALIDATION_ERROR"
      fi
      log_info "Created directory: $dir"
    fi
  done
  
  log_success "Project directory structure created"
  return "$EXIT_SUCCESS"
}

#######################################
# Validate all prerequisites
# Returns:
#   0 if all prerequisites are met, non-zero otherwise
#######################################
validate_prerequisites() {
  log_info "Validating prerequisites..."
  
  local exit_code=0
  
  # Check Python
  if ! check_python; then
    exit_code="$EXIT_VALIDATION_ERROR"
  fi
  
  # Check pip
  if ! check_pip; then
    exit_code="$EXIT_VALIDATION_ERROR"
  fi
  
  # Check AWS CLI (unless skipped)
  if [[ "$SKIP_AWS_CHECK" != "true" ]]; then
    if ! check_aws_cli; then
      exit_code="$EXIT_AWS_ERROR"
    fi
  else
    log_info "Skipping AWS CLI check (--skip-aws-check)"
  fi
  
  # Check GPU (informational only)
  check_gpu
  
  if [[ "$exit_code" -eq 0 ]]; then
    log_success "All prerequisites validated"
  else
    log_error "Some prerequisites are not met"
  fi
  
  return "$exit_code"
}

#######################################
# Main setup function
# Returns:
#   0 on success, non-zero on failure
#######################################
main() {
  log_info "Starting environment setup..."

  local exit_code=0

  # Install system dependencies first
  if ! install_system_dependencies; then
    log_error "System dependencies installation failed"
    return "$EXIT_INSTALL_ERROR"
  fi

  # Install uv if enabled (with fallback to pip on failure)
  if [[ "$USE_UV" == "true" ]]; then
    if ! install_uv; then
      log_info "uv installation failed, falling back to pip"
      USE_UV=false
    fi
  fi

  # Create virtual environment with uv if enabled
  if [[ "$USE_UV" == "true" ]]; then
    if ! create_uv_venv; then
      log_error "Virtual environment creation failed"
      return "$EXIT_INSTALL_ERROR"
    fi
    # Activate the virtual environment for subsequent commands
    if [[ -f ".venv/bin/activate" ]]; then
      source .venv/bin/activate
    fi
  fi

  # Validate prerequisites
  if ! validate_prerequisites; then
    log_error "Prerequisites validation failed"
    return "$EXIT_VALIDATION_ERROR"
  fi

  # Set up Hugging Face authentication if required
  if [[ "$HF_AUTH_REQUIRED" == "true" ]]; then
    if ! setup_huggingface_auth; then
      log_info "Hugging Face authentication not configured (may be needed for gated models)"
    fi
  else
    log_info "Skipping Hugging Face authentication (--skip-hf-auth)"
  fi

  # Install Oumi (unless skipped)
  if [[ "$SKIP_OUMI" != "true" ]]; then
    if ! install_oumi; then
      log_error "Oumi installation failed"
      exit_code="$EXIT_INSTALL_ERROR"
    fi

  else
    log_info "Skipping Oumi installation (--skip-oumi)"
  fi

  # Create directory structure
  if ! create_directory_structure; then
    log_error "Failed to create directory structure"
    exit_code="$EXIT_VALIDATION_ERROR"
  fi

  if [[ "$exit_code" -eq 0 ]]; then
    log_success "Environment setup completed successfully"
    echo ""
    log_info "Next steps:"
    log_info "  1. Activate the virtual environment: source .venv/bin/activate"
    log_info "  2. Set up S3 environment variables:"
    log_info "     export S3_PREFIX=s3://<BUCKET_NAME>/training-data"
    log_info "     export TRAIN_S3_URI=\$S3_PREFIX/train.jsonl"
    log_info "     export TEST_S3_URI=\$S3_PREFIX/test.jsonl"
    log_info "  3. Prepare your training data in data/raw/"
    log_info "  4. Configure training parameters in configs/"
    log_info "  5. Run fine-tuning with: ./scripts/fine-tune.sh"
  else
    log_error "Environment setup completed with errors"
  fi

  return "$exit_code"
}

# Main execution
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
  # Parse command line arguments
  if ! parse_arguments "$@"; then
    exit "$EXIT_INVALID_ARGS"
  fi
  
  # Validate Python version if specified
  if ! validate_python_version "$PYTHON_VERSION"; then
    exit "$EXIT_VALIDATION_ERROR"
  fi
  
  # Run main setup
  main
fi
