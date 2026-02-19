# Security Guidelines: Oumi Fine-Tuning to Amazon Bedrock Deployment

> **Important**: This document provides security guidance for this solution. Security is a shared responsibility between AWS and the customer.
>
> **Customer responsibilities include:**
> - Conducting independent security assessments
> - Implementing controls appropriate for specific use cases
> - Maintaining compliance with organizational requirements
>
> This document: (a) is for informational purposes only, (b) represents current AWS product offerings and practices, which are subject to change without notice, and (c) does not create any commitments or assurances from AWS and its affiliates, suppliers, or licensors.
>
> Copyright Amazon.com, Inc. or its affiliates. All Rights Reserved.
> SPDX-License-Identifier: MIT-0

## Overview

This document provides comprehensive security guidelines for deploying the Oumi fine-tuning solution with Amazon Bedrock. It covers security configurations for each AWS service, data classification, and incident response procedures.

## Security Scanning

This repository has been scanned for security vulnerabilities using AWS Automated Security Helper (ASH). See [SECURITY_SCAN_RESULTS.md](SECURITY_SCAN_RESULTS.md) for:
- Scanner results and findings
- Files scanned
- Instructions for running security scans

## Table of Contents

1. [AWS Shared Responsibility Model](#1-aws-shared-responsibility-model)
2. [Data Classification Guidelines](#2-data-classification-guidelines)
3. [Service-Specific Security Guidelines](#3-service-specific-security-guidelines)
4. [Network Security](#4-network-security)
5. [Monitoring and Logging](#5-monitoring-and-logging)
6. [Incident Response Procedures](#6-incident-response-procedures)
7. [Security Checklist](#7-security-checklist)
8. [AI/ML Security Considerations](#8-aiml-security-considerations)
9. [Security Implementation Priority](#9-security-implementation-priority)

---

## 1. AWS Shared Responsibility Model

Understanding the AWS Shared Responsibility Model is critical for this deployment:

### AWS Responsibilities (Security OF the Cloud)
- Physical security of data centers
- Hardware and software infrastructure
- Network infrastructure
- Virtualization layer

### Customer Responsibilities (Security IN the Cloud)
- IAM configuration and access management
- Data encryption (at rest and in transit)
- Network configuration (security groups, NACLs)
- Operating system and application security
- Training data and model artifact protection

### Workflow-Specific Responsibility Matrix

This table maps security responsibilities to specific workflow phases:

| Phase | Component | AWS Responsibility | Customer Responsibility |
|-------|-----------|-------------------|------------------------|
| **EC2 Fine-Tuning** | EC2 Instance | Hypervisor, physical security | OS patching, security groups, instance configuration |
| | EBS Volumes | Storage infrastructure | Encryption configuration, access controls |
| | IAM Instance Profile | IAM service availability | Policy design, least privilege |
| **S3 Storage** | S3 Service | Durability, availability | Bucket policies, encryption, access logging |
| | Data at Rest | Storage encryption infrastructure | S3 default encryption configuration |
| | Data in Transit | TLS termination | TLS enforcement via bucket policy |
| **Bedrock Inference** | Bedrock Service | Model hosting infrastructure | IAM permissions, input validation |
| | Custom Model Import | Import job execution | Model artifact integrity, role configuration |
| | Model Invocation | API availability | Request authentication, output handling |
| **Logging & Monitoring** | CloudTrail | Log delivery infrastructure | Trail configuration, log retention |
| | CloudWatch | Metrics/logs infrastructure | Alarm configuration, log group setup |

For more information, see the [AWS Shared Responsibility Model](https://aws.amazon.com/compliance/shared-responsibility-model/).

---

## 2. Data Classification Guidelines

### 2.1 Classification Levels

| Level | Description | Examples | Handling Requirements |
|-------|-------------|----------|----------------------|
| **Secret** | Highly sensitive credentials | AWS credentials, API keys | Secrets Manager, no logging, MFA required |
| **Confidential** | Sensitive business data | Training data, model weights | Encryption required, access logging, least privilege |
| **Internal** | Internal use only | Configuration files, logs | Access controls, encryption recommended |
| **Public** | Publicly available | Documentation, public datasets | No special handling required |

### 2.2 Data Handling Procedures

#### Training Data (Confidential)
- Store in encrypted S3 buckets (S3 default encryption)
- Enable S3 access logging
- Implement least-privilege access
- Validate data integrity before training
- Document data provenance

#### Model Artifacts (Confidential)
- Encrypt at rest using S3 default encryption
- Enable S3 versioning for rollback capability
- Implement integrity verification (checksums)
- Restrict access to authorized roles only
- Log all access and modifications

#### Credentials (Secret)
- Do not hardcode in scripts or configuration
- Use IAM instance profiles for Amazon EC2
- Store secrets in AWS Secrets Manager
- Implement automatic rotation
- Enable MFA for human access

#### Configuration Files (Internal)
- Store in version control
- Review for sensitive data before committing
- Use parameter substitution for secrets
- Encrypt if containing sensitive paths

---

## 3. Service-Specific Security Guidelines

### 3.1 Amazon Simple Storage Service (Amazon S3)

#### Required Security Configurations

```bash
# Enable Block Public Access
aws s3api put-public-access-block \
    --bucket <BUCKET_NAME> \
    --public-access-block-configuration \
    "BlockPublicAcls=true,IgnorePublicAcls=true,BlockPublicPolicy=true,RestrictPublicBuckets=true"

# Enable versioning
aws s3api put-bucket-versioning \
    --bucket <BUCKET_NAME> \
    --versioning-configuration Status=Enabled

# Enable access logging
aws s3api put-bucket-logging \
    --bucket <BUCKET_NAME> \
    --bucket-logging-status '{
        "LoggingEnabled": {
            "TargetBucket": "<LOG_BUCKET>",
            "TargetPrefix": "s3-access-logs/"
        }
    }'
```

#### TLS Version Enforcement

All Amazon S3 operations in this solution require TLS 1.2 or higher through:

1. **Bucket Policy Enforcement**: The `iam/s3-bucket-policy.json` includes:
   - `EnforceTLSRequestsOnly` statement blocking non-HTTPS requests via `aws:SecureTransport: "false"`
   - `EnforceTLSVersion` statement blocking requests with TLS < 1.2 via `s3:TlsVersion` condition

2. **AWS CLI Default Behavior**: AWS CLI v2 uses TLS 1.2+ by default

3. **Verification**: Run the following to verify TLS enforcement:
   ```bash
   aws s3api get-bucket-policy --bucket <BUCKET_NAME> --query Policy --output text | jq '.Statement[] | select(.Sid | contains("TLS"))'
   ```

#### Bucket Policy Requirements
- Enforce TLS 1.2+ using `s3:TlsVersion` condition (see policy for implementation)
- Enforce HTTPS using `aws:SecureTransport` condition
- Restrict access to specific IAM roles
- See `iam/s3-bucket-policy.json` for reference

#### Complete Bucket Policy Example

```json
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Sid": "EnforceTLSRequestsOnly",
      "Effect": "Deny",
      "Principal": "*",
      "Action": "s3:*",
      "Resource": [
        "arn:aws:s3:::<BUCKET_NAME>",
        "arn:aws:s3:::<BUCKET_NAME>/*"
      ],
      "Condition": {
        "Bool": {
          "aws:SecureTransport": "false"
        }
      }
    },
    {
      "Sid": "EnforceTLSVersion",
      "Effect": "Deny",
      "Principal": "*",
      "Action": "s3:*",
      "Resource": [
        "arn:aws:s3:::<BUCKET_NAME>",
        "arn:aws:s3:::<BUCKET_NAME>/*"
      ],
      "Condition": {
        "NumericLessThan": {
          "s3:TlsVersion": "1.2"
        }
      }
    },
  ]
}
```

### 3.2 Amazon Elastic Compute Cloud (Amazon EC2)

#### Instance Security
- Use IAM instance profiles (no hardcoded credentials)
- Apply security groups with minimal required ports
- Keep AMI and packages updated
- Enable detailed monitoring
- Use encrypted EBS volumes

#### IMDSv2 Configuration (Required)

Instance Metadata Service Version 2 (IMDSv2) should be enforced to prevent SSRF attacks:

```bash
# Launch instance with IMDSv2 required
aws ec2 run-instances \
    --image-id <AMI_ID> \
    --instance-type g5.xlarge \
    --metadata-options "HttpTokens=required,HttpPutResponseHopLimit=1,HttpEndpoint=enabled" \
    --iam-instance-profile Name=<INSTANCE_PROFILE_NAME> \
    ...

# Modify existing instance to require IMDSv2
aws ec2 modify-instance-metadata-options \
    --instance-id <INSTANCE_ID> \
    --http-tokens required \
    --http-put-response-hop-limit 1 \
    --http-endpoint enabled
```

#### Security Group Configuration

```bash
# Create security group for fine-tuning instance
aws ec2 create-security-group \
    --group-name oumi-fine-tuning-sg \
    --description "Security group for Oumi fine-tuning EC2 instances" \
    --vpc-id <VPC_ID>

# Inbound: Allow SSH only from specific CIDR (or use Session Manager with no inbound)
aws ec2 authorize-security-group-ingress \
    --group-id <SECURITY_GROUP_ID> \
    --protocol tcp \
    --port 22 \
    --cidr <YOUR_IP_CIDR>/32

# Outbound: Allow HTTPS for AWS API calls
aws ec2 authorize-security-group-egress \
    --group-id <SECURITY_GROUP_ID> \
    --protocol tcp \
    --port 443 \
    --cidr 0.0.0.0/0
```

#### Recommended Practices
- Use AWS Systems Manager Session Manager instead of SSH
- Enable Amazon Inspector for vulnerability scanning
- Implement automatic patching via Systems Manager
- Use dedicated VPC with private subnets

### 3.3 Amazon Bedrock

#### Custom Model Import Security
- Use dedicated IAM role with minimal permissions
- Verify model artifact integrity before import
- Enable CloudTrail logging for Bedrock API calls
- Implement resource-based policies where applicable

#### VPC Endpoint Configuration

For private connectivity to Amazon Bedrock without traversing the public internet:

```bash
# Create VPC endpoint for Bedrock Runtime
aws ec2 create-vpc-endpoint \
    --vpc-id <VPC_ID> \
    --service-name com.amazonaws.<REGION>.bedrock-runtime \
    --vpc-endpoint-type Interface \
    --subnet-ids <SUBNET_ID_1> <SUBNET_ID_2> \
    --security-group-ids <SECURITY_GROUP_ID> \
    --private-dns-enabled

# Create VPC endpoint for Bedrock (management operations)
aws ec2 create-vpc-endpoint \
    --vpc-id <VPC_ID> \
    --service-name com.amazonaws.<REGION>.bedrock \
    --vpc-endpoint-type Interface \
    --subnet-ids <SUBNET_ID_1> <SUBNET_ID_2> \
    --security-group-ids <SECURITY_GROUP_ID> \
    --private-dns-enabled
```

#### Inference Security
- Implement input validation for prompts
- Consider output filtering for sensitive content
- Monitor for anomalous usage patterns
- Implement rate limiting at application level

### 3.4 AWS Identity and Access Management (IAM)

#### Policy Design Principles
1. **Least Privilege**: Grant only required permissions
2. **Resource-Level Permissions**: Avoid wildcards
3. **Condition Keys**: Use conditions to restrict access
4. **Separation of Duties**: Different roles for different functions

#### Role Structure
```
EC2 Instance Profile Role:
├── S3 read/write for training data and artifacts
└── CloudWatch Logs for monitoring

Bedrock Import Role:
├── Bedrock CreateModelImportJob, GetModelImportJob
└── S3 read for model artifacts
```

---

## 4. Network Security

### 4.1 VPC Configuration

```
Recommended VPC Architecture:
┌─────────────────────────────────────────────────────────────┐
│                         VPC                                  │
├─────────────────────────────────────────────────────────────┤
│  ┌─────────────────────┐    ┌─────────────────────┐        │
│  │   Private Subnet    │    │   Private Subnet    │        │
│  │   (Fine-tuning)     │    │   (Backup AZ)       │        │
│  │                     │    │                     │        │
│  │   ┌─────────────┐   │    │                     │        │
│  │   │    EC2      │   │    │                     │        │
│  │   │  Instance   │   │    │                     │        │
│  │   └─────────────┘   │    │                     │        │
│  └─────────────────────┘    └─────────────────────┘        │
│              │                                              │
│              ▼                                              │
│  ┌─────────────────────────────────────────────────────┐   │
│  │              VPC Endpoints                           │   │
│  │  - S3 Gateway Endpoint                               │   │
│  │  - Bedrock Interface Endpoint                        │   │
│  │  - CloudWatch Logs Interface Endpoint                │   │
│  └─────────────────────────────────────────────────────┘   │
└─────────────────────────────────────────────────────────────┘
```

### 4.2 VPC Endpoints

Use VPC endpoints to keep traffic within AWS network:

| Service | Endpoint Type | Purpose |
|---------|--------------|---------|
| Amazon S3 | Gateway | Training data and artifact access |
| Amazon Bedrock | Interface | Model import and inference |
| Amazon CloudWatch Logs | Interface | Log delivery |
| AWS Secrets Manager | Interface | Secret retrieval |

---

## 5. Monitoring and Logging

### 5.1 Required Logging

| Log Type | Service | Retention | Purpose |
|----------|---------|-----------|---------|
| AWS CloudTrail | All AWS API calls | 90 days minimum | Security audit |
| Amazon S3 Access Logs | Amazon S3 buckets | 90 days minimum | Data access audit |
| Amazon CloudWatch Logs | Amazon EC2, Amazon Bedrock | 30 days minimum | Operational monitoring |
| VPC Flow Logs | VPC | 14 days minimum | Network monitoring |

### 5.2 Amazon CloudWatch Alarms

Configure alarms for:
- Unauthorized API calls (AWS CloudTrail)
- Amazon S3 bucket policy changes
- IAM policy changes
- Unusual data transfer volumes
- Amazon EC2 instance state changes

### 5.3 Security Monitoring

```bash
# Example CloudWatch alarm for unauthorized API calls
aws cloudwatch put-metric-alarm \
    --alarm-name "UnauthorizedAPICalls" \
    --metric-name "UnauthorizedAttemptCount" \
    --namespace "CloudTrailMetrics" \
    --statistic Sum \
    --period 300 \
    --threshold 1 \
    --comparison-operator GreaterThanOrEqualToThreshold \
    --evaluation-periods 1 \
    --alarm-actions "<SNS_TOPIC_ARN>"
```

### 5.4 AWS CloudTrail Log Integrity Validation

Verify AWS CloudTrail log integrity to detect tampering:

```bash
# Validate log file integrity for a specific time range
aws cloudtrail validate-logs \
    --trail-arn arn:aws:cloudtrail:<REGION>:<ACCOUNT_ID>:trail/<TRAIL_NAME> \
    --start-time 2025-01-01T00:00:00Z \
    --end-time 2025-01-31T23:59:59Z

# Verify a specific digest file
aws cloudtrail validate-logs \
    --trail-arn arn:aws:cloudtrail:<REGION>:<ACCOUNT_ID>:trail/<TRAIL_NAME> \
    --start-time 2025-01-15T00:00:00Z \
    --verbose
```

Expected output for valid logs:
```
Validating log files for trail arn:aws:cloudtrail:us-east-1:123456789012:trail/my-trail between 2025-01-01T00:00:00Z and 2025-01-31T23:59:59Z
Results requested for 2025-01-01T00:00:00Z to 2025-01-31T23:59:59Z
Results found for 2025-01-01T00:00:00Z to 2025-01-31T23:59:59Z:
31/31 digest files valid
248/248 log files valid
```

---

## 6. Incident Response Procedures

### 6.1 Incident Classification

| Severity | Description | Response Time | Examples |
|----------|-------------|---------------|----------|
| Critical | Active breach, data exfiltration | Immediate | Credential compromise, unauthorized access |
| High | Potential breach, policy violation | 1 hour | Misconfigured bucket, failed auth attempts |
| Medium | Security concern, anomaly detected | 4 hours | Unusual API patterns, policy drift |
| Low | Minor issue, improvement needed | 24 hours | Missing logs, outdated configurations |

### 6.2 Response Procedures

#### Credential Compromise (Critical)

1. **Contain**
   - Immediately revoke compromised credentials
   - Disable affected IAM users/roles
   - Block suspicious IP addresses

2. **Investigate**
   - Review CloudTrail logs for unauthorized actions
   - Identify scope of access
   - Document timeline of events

3. **Remediate**
   - Rotate all potentially affected credentials
   - Review and update IAM policies
   - Patch any exploited vulnerabilities

4. **Recover**
   - Restore from known-good backups if needed
   - Re-enable services with new credentials
   - Verify system integrity

5. **Learn**
   - Conduct post-incident review
   - Update security controls
   - Document lessons learned

#### Data Exposure (Critical)

1. **Contain**
   - Enable S3 Block Public Access immediately
   - Revoke public permissions
   - Preserve evidence (logs, configurations)

2. **Investigate**
   - Determine what data was exposed
   - Identify duration of exposure
   - Review access logs for downloads

3. **Remediate**
   - Apply correct bucket policies
   - Review all bucket configurations
   - Implement preventive controls

4. **Notify**
   - Follow data breach notification procedures
   - Engage legal/compliance teams as needed

### 6.3 Contact Information

| Role | Responsibility | Escalation |
|------|---------------|------------|
| Security Team | Initial response, investigation | security@example.com |
| DevOps Team | Infrastructure remediation | devops@example.com |
| Management | Decision authority, communications | management@example.com |
| Legal | Compliance, notifications | legal@example.com |

---

## 7. Security Checklist

### Pre-Deployment

- [ ] Amazon S3 Block Public Access enabled on all buckets
- [ ] S3 default encryption enabled for all buckets
- [ ] Amazon S3 bucket policies enforce TLS
- [ ] Amazon S3 versioning enabled for artifact buckets
- [ ] Amazon S3 access logging enabled
- [ ] IAM policies follow least privilege
- [ ] No wildcard actions in IAM policies
- [ ] IAM instance profiles configured (no hardcoded credentials)
- [ ] AWS CloudTrail enabled in all regions
- [ ] Amazon CloudWatch Logs configured
- [ ] VPC endpoints configured (if using VPC)
- [ ] Security groups restrict access appropriately

### Post-Deployment

- [ ] Verify encryption is working (test upload/download)
- [ ] Verify logging is capturing events
- [ ] Test IAM permissions (verify least privilege)
- [ ] Run security scan (no high-severity findings)
- [ ] Document any exceptions or deviations
- [ ] Schedule regular security reviews

### Ongoing

- [ ] Review CloudTrail logs weekly
- [ ] Review IAM Access Analyzer findings monthly
- [ ] Rotate credentials as scheduled
- [ ] Update security configurations as needed
- [ ] Conduct security training for team members

---

## 8. AI/ML Security Considerations

### 8.1 Training Data Bias Assessment

When fine-tuning language models, assess training data for potential biases:

#### Pre-Training Assessment
- **Data Source Review**: Document the origin and composition of training datasets
- **Demographic Representation**: Analyze whether training data represents diverse perspectives
- **Label Quality**: Verify labels are consistent and free from annotator bias
- **Sensitive Content**: Identify and handle content that may reinforce stereotypes

#### Assessment Checklist
- [ ] Training data sources documented
- [ ] Data licensing and attribution verified (see `docs/DATASET_COMPLIANCE.md`)
- [ ] Demographic distribution analyzed
- [ ] Sensitive content flagged and reviewed
- [ ] Data quality metrics established

### 8.2 Fairness Evaluation

Evaluate fine-tuned models for fairness before deployment:

#### Evaluation Approaches
1. **Benchmark Testing**: Test model outputs against fairness benchmarks
2. **Demographic Parity**: Verify similar performance across demographic groups
3. **Output Auditing**: Sample and review model outputs for biased patterns
4. **Red Team Testing**: Conduct adversarial testing for harmful outputs

#### Monitoring Post-Deployment
- Implement logging for model inputs and outputs (respecting privacy)
- Establish feedback mechanisms for reporting problematic outputs
- Schedule regular fairness audits
- Document and track bias-related incidents

### 8.3 Responsible AI Practices

#### Model Documentation
- Document model capabilities and limitations
- Specify intended use cases and out-of-scope applications
- Provide guidance for downstream users
- Maintain model cards with performance metrics

#### Deployment Safeguards
- Implement content filtering for harmful outputs
- Add rate limiting to prevent misuse
- Configure monitoring for anomalous usage patterns
- Establish clear escalation paths for issues

---

## 9. Security Implementation Priority

Implement security controls in the following priority order. Priority is determined by:
- **Impact**: Severity of potential security incident prevented
- **Effort**: Implementation complexity
- **Dependencies**: Whether other controls depend on this one

### Priority 1: Critical (Implement First)

These controls prevent the most severe security incidents and must be implemented before any production use.

| Control | Rationale | Success Metric | Verification Method |
|---------|-----------|----------------|---------------------|
| IAM Least-Privilege Roles | Limits blast radius of credential compromise | 0 wildcard actions in policies | `aws accessanalyzer validate-policy` |
| Amazon S3 Block Public Access | Prevents accidental data exposure | All buckets show "Block all public access: On" | `aws s3api get-public-access-block` |
| No Hardcoded Credentials | Prevents credential theft from code | 0 secrets detected in scans | Security scanning tools |
| S3 Default Encryption | Protects data at rest | 100% of Amazon S3 objects encrypted | `aws s3api get-bucket-encryption` |

**Implementation Timeline**: Complete before first deployment

### Priority 2: High (Implement Early)

These controls provide significant security benefits and should be implemented within the first week of deployment.

| Control | Rationale | Success Metric | Verification Method |
|---------|-----------|----------------|---------------------|
| TLS 1.2+ Enforcement | Protects data in transit | Bucket policy includes TLS version condition | `aws s3api get-bucket-policy` |
| Amazon S3 Versioning | Enables recovery from tampering | Versioning status = "Enabled" | `aws s3api get-bucket-versioning` |
| IMDSv2 Required | Prevents SSRF credential theft | HttpTokens = "required" | `aws ec2 describe-instances` |
| Security Groups | Reduces network attack surface | Only required ports open | Security group audit |

**Implementation Timeline**: Complete within first week of deployment

### Priority 3: Medium (Implement Soon)

These controls support audit and compliance requirements and should be implemented within the first month.

| Control | Rationale | Success Metric | Verification Method |
|---------|-----------|----------------|---------------------|
| AWS CloudTrail Logging | Provides audit trail for incidents | Trail status = "Logging" | `aws cloudtrail get-trail-status` |
| Amazon S3 Access Logging | Tracks data access patterns | Logging configuration present | `aws s3api get-bucket-logging` |
| Amazon CloudWatch Alarms | Enables rapid incident detection | Alarms configured for key metrics | `aws cloudwatch describe-alarms` |
| Log Integrity | Detects log tampering | LogFileValidationEnabled = true | `aws cloudtrail describe-trails` |

**Implementation Timeline**: Complete within first month of deployment

### Priority 4: Lower (Implement as Resources Allow)

These controls provide defense-in-depth and should be implemented as resources and time allow.

| Control | Rationale | Success Metric | Verification Method |
|---------|-----------|----------------|---------------------|
| VPC Isolation | Network segmentation | Amazon EC2 in private subnets | VPC configuration review |
| VPC Endpoints | Keeps traffic on AWS network | Endpoints configured for S3, Bedrock | `aws ec2 describe-vpc-endpoints` |
| MFA Delete | Prevents accidental deletion | MFADelete = "Enabled" | `aws s3api get-bucket-versioning` |

**Implementation Timeline**: Complete within first quarter

---

## References

- [AWS Well-Architected Framework - Security Pillar](https://docs.aws.amazon.com/wellarchitected/latest/security-pillar/welcome.html)
- [Amazon S3 Security Guidelines](https://docs.aws.amazon.com/AmazonS3/latest/userguide/security-best-practices.html)
- [AWS IAM Security Recommendations](https://docs.aws.amazon.com/IAM/latest/UserGuide/best-practices.html)
- [Amazon Bedrock Security](https://docs.aws.amazon.com/bedrock/latest/userguide/security.html)
- [Responsible AI Practices](https://aws.amazon.com/machine-learning/responsible-ai/)
- [Amazon Bedrock Model Evaluation](https://docs.aws.amazon.com/bedrock/latest/userguide/model-evaluation.html)
