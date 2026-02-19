# IAM Policies for Oumi Fine-Tuning and Bedrock CMI

This directory contains IAM policy documents for the Oumi fine-tuning to Amazon Bedrock Custom Model Import (CMI) workflow.

## AWS Shared Responsibility Model

Security in AWS operates under the [Shared Responsibility Model](https://aws.amazon.com/compliance/shared-responsibility-model/):

| Responsibility | AWS | Customer |
|----------------|-----|----------|
| Physical security of data centers | ✓ | |
| Network and hypervisor security | ✓ | |
| IAM policy configuration | | ✓ |
| S3 bucket policies and encryption | | ✓ |
| Application-level access controls | | ✓ |
| Data classification and handling | | ✓ |
| Compliance validation for your workload | | ✓ |

**Your responsibilities when using these policies:**

1. **Review and customize**: These policies are templates. Review each permission and tailor to your specific requirements.
2. **Replace placeholders**: Substitute all `<PLACEHOLDER>` values with your actual resource identifiers.
3. **Validate before deployment**: Use IAM Access Analyzer to verify policies meet your security requirements.
4. **Monitor and audit**: Enable CloudTrail logging and regularly review IAM Access Advisor for unused permissions.
5. **Periodic review**: Schedule regular reviews of IAM permissions to ensure least-privilege is maintained.

## Overview

The policies follow AWS security recommendations:
- **Least-privilege access**: Each role has only the permissions required for its function
- **Resource-level permissions**: Policies specify exact resource ARNs rather than wildcards
- **Condition keys**: Where applicable, conditions restrict access further

## Policy Files

| File | Purpose |
|------|---------|
| `ec2-instance-profile.json` | IAM policy for the EC2 instance profile (S3, Bedrock, CloudWatch) |
| `bedrock-import-role.json` | IAM policy for the Bedrock import role (S3 read only) |
| `s3-bucket-policy.json` | S3 bucket policy enforcing TLS and encryption |

---

## EC2 Instance Profile (`ec2-instance-profile.json`)

This policy attaches to an EC2 instance profile for fine-tuning workloads. It grants S3 access for training data and model artifacts, Bedrock permissions for import and invocation, and CloudWatch for logging.

### Permissions Breakdown

| Statement ID | Actions | Resources | Purpose |
|--------------|---------|-----------|---------|
| `S3ModelArtifactsRead` | GetObject, GetObjectVersion | S3 bucket objects | Download training data and base models |
| `S3ModelArtifactsWrite` | PutObject | S3 bucket objects | Upload fine-tuned model artifacts |
| `S3BucketList` | ListBucket | S3 bucket | List bucket contents |
| `BedrockImportJob` | CreateModelImportJob, GetModelImportJob, ListModelImportJobs | Model import jobs | Create and monitor import jobs |
| `BedrockCustomModel` | GetCustomModel, ListCustomModels, InvokeModel | Custom models | Access and invoke imported models |
| `BedrockPassRole` | iam:PassRole | BedrockModelImportRole | Pass the Bedrock import role when creating import jobs |
| `CloudWatchLogging` | CreateLogStream, PutLogEvents | CloudWatch log group | Send training logs |

### Trust Policy for EC2 Instance Profile

```json
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Effect": "Allow",
      "Principal": {
        "Service": "ec2.amazonaws.com"
      },
      "Action": "sts:AssumeRole"
    }
  ]
}
```

### Production Hardening

The `BedrockCustomModel` statement uses `custom-model/*` because the model name is unknown at setup time. After importing your model, replace the wildcard with the specific model ARN:

```
arn:aws:bedrock:<REGION>:<ACCOUNT_ID>:custom-model/<MODEL_ID>
```

See `iam/NOTICE` for full wildcard justifications.

### S3 Permissions Scoped to Specific Paths

For tighter security, scope S3 permissions to specific prefixes:

```json
{
  "Sid": "S3TrainingDataRead",
  "Effect": "Allow",
  "Action": ["s3:GetObject"],
  "Resource": "arn:aws:s3:::<BUCKET_NAME>/training-data/*"
},
{
  "Sid": "S3ModelArtifactsWrite",
  "Effect": "Allow",
  "Action": ["s3:PutObject"],
  "Resource": "arn:aws:s3:::<BUCKET_NAME>/model-artifacts/*"
}
```

---

## Bedrock Import Role (`bedrock-import-role.json`)

This role is assumed by the Amazon Bedrock service during model import. It needs only S3 read access to retrieve model artifacts from your bucket.

### Permissions Breakdown

| Statement ID | Actions | Resources | Purpose |
|--------------|---------|-----------|---------|
| `S3ReadModelArtifacts` | GetObject, GetObjectVersion | S3 bucket objects | Read model files during import |
| `S3ListBucket` | ListBucket | S3 bucket | List bucket contents during import |

### Trust Policy

The Bedrock import role requires a trust policy allowing Amazon Bedrock to assume it:

```json
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Effect": "Allow",
      "Principal": {
        "Service": "bedrock.amazonaws.com"
      },
      "Action": "sts:AssumeRole",
      "Condition": {
        "StringEquals": {
          "aws:SourceAccount": "<ACCOUNT_ID>"
        },
        "ArnLike": {
          "aws:SourceArn": "arn:aws:bedrock:<REGION>:<ACCOUNT_ID>:model-import-job/*"
        }
      }
    }
  ]
}
```

### KMS Encryption (Optional)

If your S3 bucket uses SSE-KMS encryption, KMS permissions are added to both roles by `security/encryption-setup.sh` after you create a KMS key. The base policy templates do not include KMS permissions.

### Policy Validation

Validate your customized policies before deployment:

```bash
# Validate policy syntax and security findings
aws accessanalyzer validate-policy \
  --policy-document file://bedrock-import-role.json \
  --policy-type IDENTITY_POLICY

# Simulate permissions to verify expected access
aws iam simulate-principal-policy \
  --policy-source-arn arn:aws:iam::<ACCOUNT_ID>:role/BedrockModelImportRole \
  --action-names s3:GetObject \
  --resource-arns arn:aws:s3:::<BUCKET_NAME>/*
```

---

## S3 Bucket Policy (`s3-bucket-policy.json`)

This bucket policy enforces security requirements at the bucket level.

### Policy Statements

| Statement ID | Effect | Purpose |
|--------------|--------|---------|
| `EnforceTLSRequestsOnly` | Deny | Block non-HTTPS requests |
| `EnforceTLSVersion` | Deny | Require TLS 1.2 or higher |
| `AllowEC2InstanceProfileAccess` | Allow | Grant EC2 role access |
| `AllowBedrockImportRoleAccess` | Allow | Grant Bedrock role read access |

### TLS Enforcement Example

```json
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
}
```

---

## Resource ARN Patterns

### Amazon S3
| Pattern | Description |
|---------|-------------|
| `arn:aws:s3:::<BUCKET_NAME>` | Bucket-level operations (ListBucket) |
| `arn:aws:s3:::<BUCKET_NAME>/*` | All objects in bucket |
| `arn:aws:s3:::<BUCKET_NAME>/prefix/*` | Objects under specific prefix |

### Amazon Bedrock
| Pattern | Description |
|---------|-------------|
| `arn:aws:bedrock:<REGION>:<ACCOUNT_ID>:model-import-job/*` | All import jobs |
| `arn:aws:bedrock:<REGION>:<ACCOUNT_ID>:custom-model/*` | All custom models |
| `arn:aws:bedrock:<REGION>:<ACCOUNT_ID>:custom-model/<MODEL_ID>` | Specific custom model |

### Amazon CloudWatch Logs
| Pattern | Description |
|---------|-------------|
| `arn:aws:logs:<REGION>:<ACCOUNT_ID>:log-group:<LOG_GROUP_NAME>:*` | Log group and streams |

---

## Creating the Roles

### 1. Create the EC2 Instance Profile Role

```bash
# Create the role with trust policy
aws iam create-role \
  --role-name OumiFineTuningRole \
  --assume-role-policy-document file://trust-policies/ec2-trust-policy.json

# Attach the permissions policy
aws iam put-role-policy \
  --role-name OumiFineTuningRole \
  --policy-name OumiFineTuningPolicy \
  --policy-document file://ec2-instance-profile.json

# Create instance profile and add role
aws iam create-instance-profile \
  --instance-profile-name OumiFineTuningInstanceProfile

aws iam add-role-to-instance-profile \
  --instance-profile-name OumiFineTuningInstanceProfile \
  --role-name OumiFineTuningRole
```

### 2. Create the Bedrock Import Role

```bash
# Create the role with trust policy
aws iam create-role \
  --role-name BedrockModelImportRole \
  --assume-role-policy-document file://trust-policies/bedrock-trust-policy.json

# Attach the permissions policy
aws iam put-role-policy \
  --role-name BedrockModelImportRole \
  --policy-name BedrockModelImportPolicy \
  --policy-document file://bedrock-import-role.json
```

---

## Placeholder Reference

Replace these placeholders in the policy files before use:

| Placeholder | Description | Example |
|-------------|-------------|---------|
| `<ACCOUNT_ID>` | Your 12-digit AWS account ID | `123456789012` |
| `<REGION>` | AWS region | `us-east-1` |
| `<BUCKET_NAME>` | S3 bucket name | `my-oumi-training-bucket` |

---

## Validation

After creating roles, validate permissions:

```bash
# Simulate EC2 role permissions
aws iam simulate-principal-policy \
  --policy-source-arn arn:aws:iam::<ACCOUNT_ID>:role/OumiFineTuningRole \
  --action-names s3:GetObject s3:PutObject \
  --resource-arns arn:aws:s3:::<BUCKET_NAME>/*

# Use IAM Access Analyzer for policy validation
aws accessanalyzer validate-policy \
  --policy-document file://ec2-instance-profile.json \
  --policy-type IDENTITY_POLICY
```

---

## References

- [AWS IAM documentation](https://docs.aws.amazon.com/IAM/latest/UserGuide/introduction.html)
- [Amazon Bedrock IAM permissions](https://docs.aws.amazon.com/bedrock/latest/userguide/security-iam.html)
- [Amazon S3 bucket policies](https://docs.aws.amazon.com/AmazonS3/latest/userguide/bucket-policies.html)
