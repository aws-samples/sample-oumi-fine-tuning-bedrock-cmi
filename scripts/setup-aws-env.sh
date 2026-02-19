#!/bin/bash
# Copyright Amazon.com, Inc. or its affiliates. All Rights Reserved.
# SPDX-License-Identifier: MIT-0
# AWS Environment Setup Script for Oumi Fine-Tuning
#
# This script automates the creation of AWS resources required for the
# fine-tuning workflow: IAM roles, S3 bucket, and a GPU-optimized EC2 instance.
#
# If you do not have permissions to create IAM roles or launch EC2 instances,
# share this repository with your IT administrator and ask them to complete
# this section to set up your AWS environment.
#
# Usage:
#   ./setup-aws-env.sh [OPTIONS]
#
# Options:
#   --dry-run         Show all commands that would be executed without running them
#   -h, --help        Show this help message

set -euo pipefail

# Exit codes (consistent with other scripts in this repo)
readonly EXIT_SUCCESS=0
readonly EXIT_INVALID_ARGS=1
readonly EXIT_AWS_ERROR=2
readonly EXIT_VALIDATION_ERROR=3

# Temp files tracked for cleanup on any exit
TEMP_FILES=()

cleanup() {
  for f in "${TEMP_FILES[@]}"; do
    rm -f "$f"
  done
}

trap cleanup EXIT SIGINT SIGTERM ERR

# Color codes for output
readonly RED='\033[0;31m'
readonly GREEN='\033[0;32m'
readonly YELLOW='\033[1;33m'
readonly BLUE='\033[0;34m'
readonly NC='\033[0m' # No Color

# Script directory for resolving relative paths to iam/ policy files
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

# Default values
DRY_RUN=false
AWS_REGION=""
AWS_ACCOUNT_ID=""
S3_BUCKET=""
KEY_PAIR_NAME=""
SECURITY_GROUP_ID=""
INSTANCE_TYPE="g6.12xlarge"
AMI_ID="ami-0ec23af273ff2b818"
STORAGE_SIZE="100"

# IAM resource names
readonly EC2_ROLE_NAME="OumiFineTuningRole"
readonly EC2_INSTANCE_PROFILE_NAME="OumiFineTuningInstanceProfile"
readonly BEDROCK_ROLE_NAME="BedrockModelImportRole"

log_error() {
  echo -e "${RED}[ERROR]${NC} $1" >&2
}

log_success() {
  echo -e "${GREEN}[SUCCESS]${NC} $1"
}

log_info() {
  echo -e "${YELLOW}[INFO]${NC} $1"
}

log_step() {
  echo -e "${BLUE}[STEP]${NC} $1"
}

show_usage() {
  echo "AWS Environment Setup Script"
  echo ""
  echo "Creates IAM roles, an S3 bucket, and launches a GPU-optimized EC2 instance"
  echo "for the Oumi fine-tuning workflow."
  echo ""
  echo "Usage:"
  echo "  $0 [OPTIONS]"
  echo ""
  echo "Options:"
  echo "  --dry-run         Show all commands that would be executed without running them"
  echo "  -h, --help        Show this help message"
  echo ""
  echo "The script prompts for required values interactively."
  echo ""
  echo "Exit codes:"
  echo "  0 - Success"
  echo "  1 - Invalid arguments"
  echo "  2 - AWS CLI/API error"
  echo "  3 - Validation error"
}

parse_arguments() {
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --dry-run)
        DRY_RUN=true
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
# Run or print an AWS CLI command depending on --dry-run
# Arguments:
#   All arguments are passed to aws CLI
# Returns:
#   0 on success, non-zero on failure
#######################################
run_aws() {
  if [[ "$DRY_RUN" == "true" ]]; then
    echo "  aws $*"
    return "$EXIT_SUCCESS"
  fi
  aws "$@"
}

#######################################
# Prompt user for a value with an optional default
# Arguments:
#   $1 - prompt text
#   $2 - default value (empty string if none)
# Outputs:
#   The user's input (or default) to stdout
#######################################
prompt_value() {
  local prompt_text="$1"
  local default_value="${2:-}"
  local input=""

  if [[ -n "$default_value" ]]; then
    read -rp "$prompt_text [$default_value]: " input
    echo "${input:-$default_value}"
  else
    while [[ -z "$input" ]]; do
      read -rp "$prompt_text: " input
      if [[ -z "$input" ]]; then
        log_error "This value is required"
      fi
    done
    echo "$input"
  fi
}

#######################################
# Validate S3 bucket name format
#######################################
validate_bucket_name() {
  local bucket_name="$1"

  if [[ ! "$bucket_name" =~ ^[a-z0-9][a-z0-9.-]{1,61}[a-z0-9]$ ]]; then
    log_error "Invalid bucket name format: $bucket_name"
    log_error "Bucket names must be 3-63 characters, lowercase letters, numbers, and hyphens"
    return "$EXIT_VALIDATION_ERROR"
  fi

  if [[ "$bucket_name" =~ ^xn-- ]] || [[ "$bucket_name" =~ -s3alias$ ]]; then
    log_error "Invalid bucket name: cannot start with 'xn--' or end with '-s3alias'"
    return "$EXIT_VALIDATION_ERROR"
  fi

  return "$EXIT_SUCCESS"
}

#######################################
# Validate security group ID format
#######################################
validate_security_group_id() {
  local sg_id="$1"

  if [[ ! "$sg_id" =~ ^sg-[a-f0-9]{8,17}$ ]]; then
    log_error "Invalid security group ID format: $sg_id (expected sg-xxxxxxxx)"
    return "$EXIT_VALIDATION_ERROR"
  fi

  return "$EXIT_SUCCESS"
}

#######################################
# Check AWS CLI is installed and credentials are valid
#######################################
check_aws_cli() {
  if ! command -v aws &> /dev/null; then
    log_error "AWS CLI is not installed or not in PATH"
    log_info "Install AWS CLI: https://docs.aws.amazon.com/cli/latest/userguide/getting-started-install.html"
    return "$EXIT_AWS_ERROR"
  fi

  local sts_region="${AWS_REGION:-${AWS_DEFAULT_REGION:-us-west-2}}"
  local sts_error
  if ! sts_error=$(aws sts get-caller-identity --region "$sts_region" --no-cli-pager 2>&1); then
    log_error "AWS credentials are not configured or invalid"
    log_error "$sts_error"
    log_info "Configure credentials: aws configure"
    return "$EXIT_AWS_ERROR"
  fi

  return "$EXIT_SUCCESS"
}

#######################################
# Check if an IAM role already exists
# Arguments:
#   $1 - role name
# Returns:
#   0 if role exists, non-zero otherwise
#######################################
role_exists() {
  aws iam get-role --role-name "$1" --no-cli-pager &> /dev/null
}

#######################################
# Check if an IAM instance profile already exists
# Arguments:
#   $1 - instance profile name
# Returns:
#   0 if instance profile exists, non-zero otherwise
#######################################
instance_profile_exists() {
  aws iam get-instance-profile --instance-profile-name "$1" --no-cli-pager &> /dev/null
}

#######################################
# Check if an S3 bucket already exists and is owned by the caller
# Arguments:
#   $1 - bucket name
# Returns:
#   0 if bucket exists, non-zero otherwise
#######################################
bucket_exists() {
  aws s3api head-bucket --bucket "$1" --no-cli-pager 2>/dev/null
}

#######################################
# Replace placeholders in a policy file and write to a temp file.
# Replacement values (bucket name, region, account ID) are validated
# before reaching this function and contain only [a-z0-9.-] characters.
#
# Arguments:
#   $1 - source policy file path
#   $2 - output temp file path
#######################################
prepare_policy_file() {
  local source_file="$1"
  local output_file="$2"

  sed \
    -e "s/<BUCKET_NAME>/${S3_BUCKET}/g" \
    -e "s/<REGION>/${AWS_REGION}/g" \
    -e "s/<ACCOUNT_ID>/${AWS_ACCOUNT_ID}/g" \
    "$source_file" > "$output_file"
}

#######################################
# Gather all required values from the user
#######################################
gather_inputs() {
  echo ""
  echo "========================================="
  echo "  AWS Environment Setup for Oumi"
  echo "========================================="
  echo ""
  echo "This script creates IAM roles, an S3 bucket, and launches a GPU-optimized"
  echo "EC2 instance for the Oumi fine-tuning workflow."
  echo ""
  echo "If you do not have permissions to create IAM roles or launch EC2 instances,"
  echo "share this repository with your IT administrator and ask them to complete"
  echo "this section to set up your AWS environment."
  echo ""

  # Auto-detect account ID
  local sts_region="${AWS_REGION:-${AWS_DEFAULT_REGION:-us-west-2}}"
  local detected_account_id
  detected_account_id=$(aws sts get-caller-identity --region "$sts_region" --query 'Account' --output text --no-cli-pager)

  log_info "Detected AWS account: $detected_account_id"
  echo ""

  AWS_REGION=$(prompt_value "AWS region" "us-west-2")
  AWS_ACCOUNT_ID=$(prompt_value "AWS account ID" "$detected_account_id")

  echo ""
  while true; do
    S3_BUCKET=$(prompt_value "S3 bucket name (for model artifacts)" "")
    if validate_bucket_name "$S3_BUCKET"; then
      break
    fi
  done

  echo ""
  log_info "An EC2 key pair is required for SSH access to the training instance."
  log_info "Enter the key pair name without the .pem extension (e.g. 'mykey' not 'mykey.pem')."
  log_info "Create one: https://docs.aws.amazon.com/AWSEC2/latest/UserGuide/create-key-pairs.html"
  KEY_PAIR_NAME=$(prompt_value "EC2 key pair name" "")

  echo ""
  log_info "A security group with SSH (port 22) inbound access from your IP is required."
  log_info "Create one: https://docs.aws.amazon.com/AWSEC2/latest/UserGuide/creating-security-group.html"
  while true; do
    SECURITY_GROUP_ID=$(prompt_value "Security group ID (e.g. sg-xxxxxxxx)" "")
    if validate_security_group_id "$SECURITY_GROUP_ID"; then
      break
    fi
  done

  echo ""
  log_info "Instance type should match model size and fine-tuning method."
  log_info "Default g6.12xlarge provides 4x L4 GPUs (96 GB VRAM) for Llama 3.2 1B full fine-tuning."
  INSTANCE_TYPE=$(prompt_value "EC2 instance type" "$INSTANCE_TYPE")

  AMI_ID=$(prompt_value "AMI ID (Deep Learning Base AMI with Single CUDA, Amazon Linux 2023)" "$AMI_ID")
  STORAGE_SIZE=$(prompt_value "EBS volume size in GB (gp3)" "$STORAGE_SIZE")
}

#######################################
# Display a summary and ask for confirmation
#######################################
confirm_inputs() {
  echo ""
  echo "========================================="
  echo "  Resource Summary"
  echo "========================================="
  echo ""
  echo "  AWS Region:          $AWS_REGION"
  echo "  Account ID:          $AWS_ACCOUNT_ID"
  echo "  S3 Bucket:           $S3_BUCKET"
  echo "  Key Pair:            $KEY_PAIR_NAME"
  echo "  Security Group:      $SECURITY_GROUP_ID"
  echo "  Instance Type:       $INSTANCE_TYPE"
  echo "  AMI ID:              $AMI_ID"
  echo "  Storage:             ${STORAGE_SIZE} GB (gp3)"
  echo ""
  echo "  IAM Roles:"
  echo "    - $EC2_ROLE_NAME (EC2 instance profile)"
  echo "    - $BEDROCK_ROLE_NAME (Bedrock import role)"
  echo ""
  echo "  Bedrock Role ARN:   arn:aws:iam::${AWS_ACCOUNT_ID}:role/${BEDROCK_ROLE_NAME}"
  echo ""

  if [[ "$DRY_RUN" == "true" ]]; then
    log_info "DRY RUN mode: commands will be printed but not executed"
    echo ""
    return "$EXIT_SUCCESS"
  fi

  read -rp "Proceed with resource creation? (y/N): " confirm
  if [[ ! "$confirm" =~ ^[Yy]$ ]]; then
    log_info "Aborted by user"
    exit "$EXIT_SUCCESS"
  fi
}

#######################################
# Create the EC2 instance profile role and attach its policy
#######################################
create_ec2_role() {
  log_step "Creating EC2 instance profile role: $EC2_ROLE_NAME"

  if [[ "$DRY_RUN" != "true" ]] && role_exists "$EC2_ROLE_NAME"; then
    log_info "Role $EC2_ROLE_NAME already exists, skipping creation"
  else
    run_aws iam create-role \
      --role-name "$EC2_ROLE_NAME" \
      --assume-role-policy-document '{
        "Version": "2012-10-17",
        "Statement": [{
          "Effect": "Allow",
          "Principal": {"Service": "ec2.amazonaws.com"},
          "Action": "sts:AssumeRole"
        }]
      }' \
      --no-cli-pager
    if [[ "$DRY_RUN" != "true" ]]; then
      log_success "Created role: $EC2_ROLE_NAME"
    fi
  fi

  # Prepare policy file with placeholders replaced
  local tmp_policy
  tmp_policy=$(mktemp)
  TEMP_FILES+=("$tmp_policy")

  prepare_policy_file "$REPO_ROOT/iam/ec2-instance-profile.json" "$tmp_policy"

  if [[ "$DRY_RUN" == "true" ]]; then
    log_info "Would attach policy from iam/ec2-instance-profile.json (with placeholders replaced)"
    run_aws iam put-role-policy \
      --role-name "$EC2_ROLE_NAME" \
      --policy-name OumiFineTuningPolicy \
      --policy-document "file://$tmp_policy"
  else
    aws iam put-role-policy \
      --role-name "$EC2_ROLE_NAME" \
      --policy-name OumiFineTuningPolicy \
      --policy-document "file://$tmp_policy" \
      --no-cli-pager
    log_success "Attached policy to role: $EC2_ROLE_NAME"
  fi
}

#######################################
# Create the EC2 instance profile and add the role to it
#######################################
create_instance_profile() {
  log_step "Creating EC2 instance profile: $EC2_INSTANCE_PROFILE_NAME"

  if [[ "$DRY_RUN" != "true" ]] && instance_profile_exists "$EC2_INSTANCE_PROFILE_NAME"; then
    log_info "Instance profile $EC2_INSTANCE_PROFILE_NAME already exists, skipping creation"
  else
    run_aws iam create-instance-profile \
      --instance-profile-name "$EC2_INSTANCE_PROFILE_NAME" \
      --no-cli-pager

    run_aws iam add-role-to-instance-profile \
      --instance-profile-name "$EC2_INSTANCE_PROFILE_NAME" \
      --role-name "$EC2_ROLE_NAME" \
      --no-cli-pager

    if [[ "$DRY_RUN" != "true" ]]; then
      log_success "Created instance profile: $EC2_INSTANCE_PROFILE_NAME"
      # Instance profile needs a few seconds to propagate before it can be used
      log_info "Waiting for instance profile to propagate..."
      sleep 10
    fi
  fi
}

#######################################
# Create the Bedrock import role and attach its policy
#######################################
create_bedrock_role() {
  log_step "Creating Bedrock import role: $BEDROCK_ROLE_NAME"

  local trust_policy
  trust_policy=$(cat <<TRUST_EOF
{
  "Version": "2012-10-17",
  "Statement": [{
    "Effect": "Allow",
    "Principal": {"Service": "bedrock.amazonaws.com"},
    "Action": "sts:AssumeRole",
    "Condition": {
      "StringEquals": {"aws:SourceAccount": "$AWS_ACCOUNT_ID"},
      "ArnLike": {"aws:SourceArn": "arn:aws:bedrock:${AWS_REGION}:${AWS_ACCOUNT_ID}:model-import-job/*"}
    }
  }]
}
TRUST_EOF
  )

  if [[ "$DRY_RUN" != "true" ]] && role_exists "$BEDROCK_ROLE_NAME"; then
    log_info "Role $BEDROCK_ROLE_NAME already exists, skipping creation"
  else
    if [[ "$DRY_RUN" == "true" ]]; then
      run_aws iam create-role \
        --role-name "$BEDROCK_ROLE_NAME" \
        --assume-role-policy-document "'...trust policy with account $AWS_ACCOUNT_ID and region $AWS_REGION...'" \
        --no-cli-pager
    else
      aws iam create-role \
        --role-name "$BEDROCK_ROLE_NAME" \
        --assume-role-policy-document "$trust_policy" \
        --no-cli-pager
      log_success "Created role: $BEDROCK_ROLE_NAME"
    fi
  fi

  # Prepare policy file with placeholders replaced
  local tmp_policy
  tmp_policy=$(mktemp)
  TEMP_FILES+=("$tmp_policy")

  prepare_policy_file "$REPO_ROOT/iam/bedrock-import-role.json" "$tmp_policy"

  if [[ "$DRY_RUN" == "true" ]]; then
    log_info "Would attach policy from iam/bedrock-import-role.json (with placeholders replaced)"
    run_aws iam put-role-policy \
      --role-name "$BEDROCK_ROLE_NAME" \
      --policy-name BedrockModelImportPolicy \
      --policy-document "file://$tmp_policy"
  else
    aws iam put-role-policy \
      --role-name "$BEDROCK_ROLE_NAME" \
      --policy-name BedrockModelImportPolicy \
      --policy-document "file://$tmp_policy" \
      --no-cli-pager
    log_success "Attached policy to role: $BEDROCK_ROLE_NAME"
  fi
}

#######################################
# Create the S3 bucket
#######################################
create_s3_bucket() {
  log_step "Creating S3 bucket: $S3_BUCKET"

  if [[ "$DRY_RUN" != "true" ]] && bucket_exists "$S3_BUCKET"; then
    log_info "Bucket $S3_BUCKET already exists, skipping creation"
    return "$EXIT_SUCCESS"
  fi

  # us-east-1 does not support LocationConstraint
  if [[ "$AWS_REGION" == "us-east-1" ]]; then
    run_aws s3api create-bucket \
      --bucket "$S3_BUCKET" \
      --region "$AWS_REGION" \
      --no-cli-pager
  else
    run_aws s3api create-bucket \
      --bucket "$S3_BUCKET" \
      --region "$AWS_REGION" \
      --create-bucket-configuration "LocationConstraint=$AWS_REGION" \
      --no-cli-pager
  fi

  if [[ "$DRY_RUN" != "true" ]]; then
    log_success "Created S3 bucket: $S3_BUCKET"
    log_info "For optional security hardening (SSE-KMS, bucket policies, TLS enforcement), see security/"
  fi
}

#######################################
# Launch the EC2 instance
#######################################
launch_ec2_instance() {
  log_step "Launching EC2 instance: $INSTANCE_TYPE with $AMI_ID"

  local instance_id=""

  if [[ "$DRY_RUN" == "true" ]]; then
    run_aws ec2 run-instances \
      --image-id "$AMI_ID" \
      --instance-type "$INSTANCE_TYPE" \
      --key-name "$KEY_PAIR_NAME" \
      --security-group-ids "$SECURITY_GROUP_ID" \
      --iam-instance-profile "Name=$EC2_INSTANCE_PROFILE_NAME" \
      --block-device-mappings "DeviceName=/dev/xvda,Ebs={VolumeSize=${STORAGE_SIZE},VolumeType=gp3}" \
      --tag-specifications "'ResourceType=instance,Tags=[{Key=Name,Value=OumiFineTuning},{Key=Project,Value=oumi-fine-tuning}]'" \
      --region "$AWS_REGION" \
      --query "'Instances[0].InstanceId'" \
      --output text
    return "$EXIT_SUCCESS"
  fi

  instance_id=$(aws ec2 run-instances \
    --image-id "$AMI_ID" \
    --instance-type "$INSTANCE_TYPE" \
    --key-name "$KEY_PAIR_NAME" \
    --security-group-ids "$SECURITY_GROUP_ID" \
    --iam-instance-profile "Name=$EC2_INSTANCE_PROFILE_NAME" \
    --block-device-mappings "DeviceName=/dev/xvda,Ebs={VolumeSize=${STORAGE_SIZE},VolumeType=gp3}" \
    --tag-specifications "ResourceType=instance,Tags=[{Key=Name,Value=OumiFineTuning},{Key=Project,Value=oumi-fine-tuning}]" \
    --region "$AWS_REGION" \
    --query 'Instances[0].InstanceId' \
    --output text \
    --no-cli-pager)

  log_success "Launched instance: $instance_id"
  log_info "Waiting for instance to enter running state..."

  aws ec2 wait instance-running \
    --instance-ids "$instance_id" \
    --region "$AWS_REGION" \
    --no-cli-pager

  local public_dns
  public_dns=$(aws ec2 describe-instances \
    --instance-ids "$instance_id" \
    --region "$AWS_REGION" \
    --query 'Reservations[0].Instances[0].PublicDnsName' \
    --output text \
    --no-cli-pager)

  local public_ip
  public_ip=$(aws ec2 describe-instances \
    --instance-ids "$instance_id" \
    --region "$AWS_REGION" \
    --query 'Reservations[0].Instances[0].PublicIpAddress' \
    --output text \
    --no-cli-pager)

  echo ""
  echo "========================================="
  echo "  Setup Complete"
  echo "========================================="
  echo ""
  echo "  Instance ID:         $instance_id"
  echo "  Public IP:           $public_ip"
  echo "  Public DNS:          $public_dns"
  echo "  Bedrock Role ARN:    arn:aws:iam::${AWS_ACCOUNT_ID}:role/${BEDROCK_ROLE_NAME}"
  echo ""
  echo "  Save the Bedrock Role ARN above — you will need it in Step 5 (import-to-bedrock.sh)."
  echo ""
  echo "  Connect to the instance:"
  echo ""
  echo "    ssh -i ${KEY_PAIR_NAME}.pem ec2-user@${public_dns}"
  echo ""
  echo "  Then continue with the Quick Start steps in README.md."
  echo ""
}

#######################################
# Main function
#######################################
main() {
  # Check AWS CLI first
  if ! check_aws_cli; then
    return "$EXIT_AWS_ERROR"
  fi

  # Gather user inputs
  gather_inputs

  # Show summary and confirm
  confirm_inputs

  echo ""
  if [[ "$DRY_RUN" == "true" ]]; then
    log_info "DRY RUN: The following commands would be executed:"
    echo ""
  fi

  # Create resources
  create_ec2_role
  create_instance_profile
  create_bedrock_role
  create_s3_bucket
  launch_ec2_instance

  if [[ "$DRY_RUN" == "true" ]]; then
    echo ""
    log_info "DRY RUN complete. No resources were created."
    echo ""
    echo "  Bedrock Role ARN (after creation): arn:aws:iam::${AWS_ACCOUNT_ID}:role/${BEDROCK_ROLE_NAME}"
    echo ""
    echo "  Save this ARN — you will need it in Step 5 (import-to-bedrock.sh)."
  fi

  return "$EXIT_SUCCESS"
}

# Main execution
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
  if ! parse_arguments "$@"; then
    exit "$EXIT_INVALID_ARGS"
  fi

  main
  exit $?
fi
