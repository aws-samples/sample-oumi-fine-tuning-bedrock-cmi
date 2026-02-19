#!/bin/bash
# Copyright Amazon.com, Inc. or its affiliates. All Rights Reserved.
# SPDX-License-Identifier: MIT-0
# Amazon CloudWatch Security Alarms Script
#
# This script configures Amazon CloudWatch alarms for security monitoring including
# unauthorized API calls, AWS Identity and Access Management (IAM) policy changes,
# Amazon Simple Storage Service (Amazon S3) bucket policy changes, and root account usage.
#
# Security Controls and Measurable Outcomes:
#   - Unauthorized API Monitoring: Detects access denied events for early breach detection
#   - IAM Policy Change Alerts: Tracks privilege escalation attempts (CIS AWS 3.4)
#   - S3 Policy Change Alerts: Identifies data exposure risks (CIS AWS 3.8)
#   - Root Account Monitoring: Critical security event detection (CIS AWS 3.3)
#
# Implementation Priority: Priority 1 (Critical) - See docs/SECURITY.md Section 10
#
# Prerequisites:
#   - AWS CloudTrail must be enabled and sending logs to Amazon CloudWatch Logs
#   - A CloudWatch Log Group must exist for CloudTrail events
#   - An Amazon Simple Notification Service (Amazon SNS) topic must exist for alarm notifications
#
# Usage:
#   ./cloudwatch-alarms.sh all <LOG_GROUP_NAME> <SNS_TOPIC_ARN>
#   ./cloudwatch-alarms.sh unauthorized-api <LOG_GROUP_NAME> <SNS_TOPIC_ARN>
#   ./cloudwatch-alarms.sh iam-changes <LOG_GROUP_NAME> <SNS_TOPIC_ARN>
#   ./cloudwatch-alarms.sh s3-policy-changes <LOG_GROUP_NAME> <SNS_TOPIC_ARN>
#   ./cloudwatch-alarms.sh root-usage <LOG_GROUP_NAME> <SNS_TOPIC_ARN>
#   ./cloudwatch-alarms.sh --dry-run all <LOG_GROUP_NAME> <SNS_TOPIC_ARN>

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

# Default namespace for CloudTrail metrics
readonly METRIC_NAMESPACE="CloudTrailSecurityMetrics"

# Dry run flag
DRY_RUN=false

#######################################
# Log an error message to stderr
#######################################
log_error() {
  echo -e "${RED}[ERROR]${NC} $1" >&2
}

#######################################
# Log a success message
#######################################
log_success() {
  echo -e "${GREEN}[SUCCESS]${NC} $1"
}

#######################################
# Log an info message
#######################################
log_info() {
  echo -e "${YELLOW}[INFO]${NC} $1"
}

#######################################
# Log a dry run message
#######################################
log_dry_run() {
  echo -e "${YELLOW}[DRY-RUN]${NC} Would execute: $1"
}

#######################################
# Check if AWS CLI is available and configured
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
# Validate log group name
#######################################
validate_log_group() {
  local log_group_name="${1:-}"

  if [[ -z "$log_group_name" ]]; then
    log_error "Log group name is required"
    return "$EXIT_INVALID_ARGS"
  fi

  if [[ ! "$log_group_name" =~ ^[a-zA-Z0-9/_.-]+$ ]]; then
    log_error "Invalid log group name format: $log_group_name"
    return "$EXIT_VALIDATION_ERROR"
  fi

  return "$EXIT_SUCCESS"
}

#######################################
# Validate SNS topic ARN
#######################################
validate_sns_topic_arn() {
  local sns_topic_arn="${1:-}"

  if [[ -z "$sns_topic_arn" ]]; then
    log_error "SNS topic ARN is required"
    return "$EXIT_INVALID_ARGS"
  fi

  if [[ ! "$sns_topic_arn" =~ ^arn:aws:sns:[a-z0-9-]+:[0-9]{12}:[a-zA-Z0-9_-]+$ ]]; then
    log_error "Invalid SNS topic ARN format: $sns_topic_arn"
    return "$EXIT_VALIDATION_ERROR"
  fi

  return "$EXIT_SUCCESS"
}

#######################################
# Create metric filter
# Arguments:
#   filter_name: Name of the metric filter
#   log_group_name: CloudWatch Log Group name
#   filter_pattern: Filter pattern for matching log events
#   metric_name: Name for the metric
#   metric_value: Value to publish when filter matches
#######################################
create_metric_filter() {
  local filter_name="$1"
  local log_group_name="$2"
  local filter_pattern="$3"
  local metric_name="$4"
  local metric_value="${5:-1}"

  log_info "Creating metric filter: $filter_name"

  if [[ "$DRY_RUN" == "true" ]]; then
    log_dry_run "aws logs put-metric-filter --filter-name $filter_name ..."
    return "$EXIT_SUCCESS"
  fi

  if ! aws logs put-metric-filter \
    --log-group-name "$log_group_name" \
    --filter-name "$filter_name" \
    --filter-pattern "$filter_pattern" \
    --metric-transformations \
      "metricName=$metric_name,metricNamespace=$METRIC_NAMESPACE,metricValue=$metric_value,defaultValue=0" \
    --no-cli-pager; then
    log_error "Failed to create metric filter: $filter_name"
    return "$EXIT_AWS_ERROR"
  fi

  log_success "Metric filter created: $filter_name"
  return "$EXIT_SUCCESS"
}

#######################################
# Create CloudWatch alarm
# Arguments:
#   alarm_name: Name of the alarm
#   metric_name: Name of the metric to monitor
#   sns_topic_arn: SNS topic ARN for notifications
#   description: Alarm description
#   threshold: Threshold value (default: 1)
#   period: Evaluation period in seconds (default: 300)
#######################################
create_alarm() {
  local alarm_name="$1"
  local metric_name="$2"
  local sns_topic_arn="$3"
  local description="$4"
  local threshold="${5:-1}"
  local period="${6:-300}"

  log_info "Creating alarm: $alarm_name"

  if [[ "$DRY_RUN" == "true" ]]; then
    log_dry_run "aws cloudwatch put-metric-alarm --alarm-name $alarm_name ..."
    return "$EXIT_SUCCESS"
  fi

  if ! aws cloudwatch put-metric-alarm \
    --alarm-name "$alarm_name" \
    --alarm-description "$description" \
    --metric-name "$metric_name" \
    --namespace "$METRIC_NAMESPACE" \
    --statistic Sum \
    --period "$period" \
    --threshold "$threshold" \
    --comparison-operator GreaterThanOrEqualToThreshold \
    --evaluation-periods 1 \
    --alarm-actions "$sns_topic_arn" \
    --treat-missing-data notBreaching \
    --no-cli-pager; then
    log_error "Failed to create alarm: $alarm_name"
    return "$EXIT_AWS_ERROR"
  fi

  log_success "Alarm created: $alarm_name"
  return "$EXIT_SUCCESS"
}

#######################################
# Configure unauthorized API call monitoring
# Detects API calls that return "AccessDenied" or "UnauthorizedAccess"
#######################################
configure_unauthorized_api_alarm() {
  local log_group_name="$1"
  local sns_topic_arn="$2"

  log_info "Configuring unauthorized API call alarm"

  local filter_pattern='{ ($.errorCode = "*UnauthorizedAccess*") || ($.errorCode = "AccessDenied*") }'

  create_metric_filter \
    "UnauthorizedAPICalls" \
    "$log_group_name" \
    "$filter_pattern" \
    "UnauthorizedAPICallCount" || return $?

  create_alarm \
    "UnauthorizedAPICalls" \
    "UnauthorizedAPICallCount" \
    "$sns_topic_arn" \
    "Alarm for unauthorized API calls (AccessDenied or UnauthorizedAccess errors)" || return $?

  return "$EXIT_SUCCESS"
}

#######################################
# Configure IAM policy change monitoring
# Detects changes to IAM policies, roles, users, and groups
#######################################
configure_iam_changes_alarm() {
  local log_group_name="$1"
  local sns_topic_arn="$2"

  log_info "Configuring IAM policy changes alarm"

  local filter_pattern='{ ($.eventName = DeleteGroupPolicy) || ($.eventName = DeleteRolePolicy) || ($.eventName = DeleteUserPolicy) || ($.eventName = PutGroupPolicy) || ($.eventName = PutRolePolicy) || ($.eventName = PutUserPolicy) || ($.eventName = CreatePolicy) || ($.eventName = DeletePolicy) || ($.eventName = CreatePolicyVersion) || ($.eventName = DeletePolicyVersion) || ($.eventName = AttachRolePolicy) || ($.eventName = DetachRolePolicy) || ($.eventName = AttachUserPolicy) || ($.eventName = DetachUserPolicy) || ($.eventName = AttachGroupPolicy) || ($.eventName = DetachGroupPolicy) }'

  create_metric_filter \
    "IAMPolicyChanges" \
    "$log_group_name" \
    "$filter_pattern" \
    "IAMPolicyChangeCount" || return $?

  create_alarm \
    "IAMPolicyChanges" \
    "IAMPolicyChangeCount" \
    "$sns_topic_arn" \
    "Alarm for IAM policy changes (create, delete, attach, detach operations)" || return $?

  return "$EXIT_SUCCESS"
}

#######################################
# Configure S3 bucket policy change monitoring
# Detects changes to S3 bucket policies, ACLs, and public access settings
#######################################
configure_s3_policy_changes_alarm() {
  local log_group_name="$1"
  local sns_topic_arn="$2"

  log_info "Configuring S3 bucket policy changes alarm"

  local filter_pattern='{ ($.eventSource = s3.amazonaws.com) && (($.eventName = PutBucketAcl) || ($.eventName = PutBucketPolicy) || ($.eventName = PutBucketCors) || ($.eventName = PutBucketLifecycle) || ($.eventName = PutBucketReplication) || ($.eventName = DeleteBucketPolicy) || ($.eventName = DeleteBucketCors) || ($.eventName = DeleteBucketLifecycle) || ($.eventName = DeleteBucketReplication) || ($.eventName = PutBucketPublicAccessBlock) || ($.eventName = DeleteBucketPublicAccessBlock)) }'

  create_metric_filter \
    "S3BucketPolicyChanges" \
    "$log_group_name" \
    "$filter_pattern" \
    "S3BucketPolicyChangeCount" || return $?

  create_alarm \
    "S3BucketPolicyChanges" \
    "S3BucketPolicyChangeCount" \
    "$sns_topic_arn" \
    "Alarm for S3 bucket policy changes (policy, ACL, public access modifications)" || return $?

  return "$EXIT_SUCCESS"
}

#######################################
# Configure root account usage monitoring
# Detects any usage of the AWS root account
#######################################
configure_root_usage_alarm() {
  local log_group_name="$1"
  local sns_topic_arn="$2"

  log_info "Configuring root account usage alarm"

  local filter_pattern='{ $.userIdentity.type = "Root" && $.userIdentity.invokedBy NOT EXISTS && $.eventType != "AwsServiceEvent" }'

  create_metric_filter \
    "RootAccountUsage" \
    "$log_group_name" \
    "$filter_pattern" \
    "RootAccountUsageCount" || return $?

  create_alarm \
    "RootAccountUsage" \
    "RootAccountUsageCount" \
    "$sns_topic_arn" \
    "Alarm for AWS root account usage (high priority security event)" || return $?

  return "$EXIT_SUCCESS"
}

#######################################
# Configure all security alarms
#######################################
configure_all_alarms() {
  local log_group_name="$1"
  local sns_topic_arn="$2"

  log_info "Configuring all security alarms"

  local exit_code=0

  if ! configure_unauthorized_api_alarm "$log_group_name" "$sns_topic_arn"; then
    log_error "Failed to configure unauthorized API call alarm"
    exit_code="$EXIT_AWS_ERROR"
  fi

  if ! configure_iam_changes_alarm "$log_group_name" "$sns_topic_arn"; then
    log_error "Failed to configure IAM changes alarm"
    exit_code="$EXIT_AWS_ERROR"
  fi

  if ! configure_s3_policy_changes_alarm "$log_group_name" "$sns_topic_arn"; then
    log_error "Failed to configure S3 policy changes alarm"
    exit_code="$EXIT_AWS_ERROR"
  fi

  if ! configure_root_usage_alarm "$log_group_name" "$sns_topic_arn"; then
    log_error "Failed to configure root usage alarm"
    exit_code="$EXIT_AWS_ERROR"
  fi

  if [[ "$exit_code" -eq 0 ]]; then
    log_success "All security alarms configured successfully"
  else
    log_error "Some alarm configurations failed"
  fi

  return "$exit_code"
}

#######################################
# Display usage information
#######################################
show_usage() {
  echo "CloudWatch Security Alarms Script"
  echo ""
  echo "Usage:"
  echo "  $0 [--dry-run] <command> <LOG_GROUP_NAME> <SNS_TOPIC_ARN>"
  echo ""
  echo "Commands:"
  echo "  all               Configure all security alarms"
  echo "  unauthorized-api  Configure unauthorized API call alarm"
  echo "  iam-changes       Configure IAM policy changes alarm"
  echo "  s3-policy-changes Configure S3 bucket policy changes alarm"
  echo "  root-usage        Configure root account usage alarm"
  echo ""
  echo "Options:"
  echo "  --dry-run         Show what would be executed without making changes"
  echo ""
  echo "Arguments:"
  echo "  LOG_GROUP_NAME    CloudWatch Log Group receiving CloudTrail events"
  echo "  SNS_TOPIC_ARN     SNS topic ARN for alarm notifications"
  echo ""
  echo "Exit codes:"
  echo "  0 - Success"
  echo "  1 - Invalid arguments"
  echo "  2 - AWS CLI error"
  echo "  3 - Validation error"
  echo ""
  echo "Prerequisites:"
  echo "  - CloudTrail must be configured to send events to CloudWatch Logs"
  echo "  - The specified CloudWatch Log Group must exist"
  echo "  - The specified SNS topic must exist and be configured for notifications"
  echo ""
  echo "Example:"
  echo "  $0 all /aws/cloudtrail/my-trail arn:aws:sns:us-east-1:123456789012:security-alerts"
}

# Main execution
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
  if [[ $# -eq 0 ]]; then
    show_usage
    exit "$EXIT_INVALID_ARGS"
  fi

  # Check for dry-run flag
  if [[ "${1:-}" == "--dry-run" ]]; then
    DRY_RUN=true
    log_info "Dry run mode enabled - no changes are made"
    shift
  fi

  if [[ $# -lt 1 ]]; then
    show_usage
    exit "$EXIT_INVALID_ARGS"
  fi

  command="${1:-}"
  shift

  case "$command" in
    all|unauthorized-api|iam-changes|s3-policy-changes|root-usage)
      # Validate arguments
      if [[ $# -lt 2 ]]; then
        log_error "Missing required arguments: LOG_GROUP_NAME and SNS_TOPIC_ARN"
        show_usage
        exit "$EXIT_INVALID_ARGS"
      fi

      log_group_name="$1"
      sns_topic_arn="$2"

      # Validate inputs
      if ! validate_log_group "$log_group_name"; then
        exit "$EXIT_INVALID_ARGS"
      fi

      if ! validate_sns_topic_arn "$sns_topic_arn"; then
        exit "$EXIT_INVALID_ARGS"
      fi

      # Check AWS CLI
      if ! check_aws_cli; then
        exit "$EXIT_AWS_ERROR"
      fi

      case "$command" in
        all)
          configure_all_alarms "$log_group_name" "$sns_topic_arn"
          ;;
        unauthorized-api)
          configure_unauthorized_api_alarm "$log_group_name" "$sns_topic_arn"
          ;;
        iam-changes)
          configure_iam_changes_alarm "$log_group_name" "$sns_topic_arn"
          ;;
        s3-policy-changes)
          configure_s3_policy_changes_alarm "$log_group_name" "$sns_topic_arn"
          ;;
        root-usage)
          configure_root_usage_alarm "$log_group_name" "$sns_topic_arn"
          ;;
      esac
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
