# Architecture: Oumi Fine-Tuning to Amazon Bedrock Deployment

> **Important**: This architecture document describes one approach for deploying fine-tuned models to Amazon Bedrock. Security is a shared responsibility between AWS and the customer.
>
> **Customer responsibilities include:**
> - Conducting independent assessments of this architecture
> - Implementing controls appropriate for specific use cases
> - Verifying the architecture meets organizational security requirements
>
> See the [AWS Shared Responsibility Model](https://aws.amazon.com/compliance/shared-responsibility-model/) for more information.

## Overview

This document describes the architecture for fine-tuning AI models using the Oumi framework on Amazon Elastic Compute Cloud (Amazon EC2) and deploying them to Amazon Bedrock via Custom Model Import (CMI).

## Table of Contents

1. [High-Level Architecture](#1-high-level-architecture)
2. [Security Architecture](#2-security-architecture)
3. [Component Details](#3-component-details)
4. [Data Flow](#4-data-flow)
5. [Deployment Architecture](#5-deployment-architecture)

---

## 1. High-Level Architecture

### 1.1 System Overview Diagram

```
┌─────────────────────────────────────────────────────────────────────────────────────┐
│                    Oumi Fine-Tuning to Amazon Bedrock Architecture                   │
├─────────────────────────────────────────────────────────────────────────────────────┤
│                                                                                      │
│  ┌─────────────┐                                                                     │
│  │   User /    │                                                                     │
│  │  Developer  │                                                                     │
│  └──────┬──────┘                                                                     │
│         │                                                                            │
│         │ (1) Configure & Launch                                                     │
│         ▼                                                                            │
│  ┌─────────────────────────────────────────────────────────────────────────────┐    │
│  │                              AWS Cloud                                       │    │
│  │  ┌─────────────────────────────────────────────────────────────────────┐    │    │
│  │  │                         VPC (Optional)                               │    │    │
│  │  │                                                                      │    │    │
│  │  │   ┌─────────────────┐         ┌─────────────────────────────────┐   │    │    │
│  │  │   │   Amazon EC2    │         │         Amazon S3               │   │    │    │
│  │  │   │   (GPU Instance)│         │                                 │   │    │    │
│  │  │   │                 │         │  ┌───────────┐  ┌───────────┐   │   │    │    │
│  │  │   │  ┌───────────┐  │  (2)    │  │ Training  │  │  Model    │   │   │    │    │
│  │  │   │  │   Oumi    │──┼────────▶│  │   Data    │  │ Artifacts │   │   │    │    │
│  │  │   │  │ Framework │  │  Read   │  │  Bucket   │  │  Bucket   │   │   │    │    │
│  │  │   │  └───────────┘  │         │  └───────────┘  └─────┬─────┘   │   │    │    │
│  │  │   │        │        │         │                       │         │   │    │    │
│  │  │   │        │ (3)    │         └───────────────────────┼─────────┘   │    │    │
│  │  │   │        │ Write  │                                 │             │    │    │
│  │  │   │        ▼        │                                 │             │    │    │
│  │  │   │  ┌───────────┐  │                                 │             │    │    │
│  │  │   │  │  Model    │  │                                 │             │    │    │
│  │  │   │  │ Artifacts │──┼─────────────────────────────────┘             │    │    │
│  │  │   │  └───────────┘  │                                               │    │    │
│  │  │   └─────────────────┘                                               │    │    │
│  │  │                                                                      │    │    │
│  │  └──────────────────────────────────────────────────────────────────────┘    │    │
│  │                                           │                                   │    │
│  │                                           │ (4) Import Model                  │    │
│  │                                           ▼                                   │    │
│  │  ┌─────────────────────────────────────────────────────────────────────┐    │    │
│  │  │                        Amazon Bedrock                                │    │    │
│  │  │                                                                      │    │    │
│  │  │   ┌─────────────────┐         ┌─────────────────────────────────┐   │    │    │
│  │  │   │  Custom Model   │         │      Bedrock Runtime            │   │    │    │
│  │  │   │     Import      │────────▶│                                 │   │    │    │
│  │  │   │     (CMI)       │         │   ┌───────────────────────┐     │   │    │    │
│  │  │   └─────────────────┘         │   │   Imported Model      │     │   │    │    │
│  │  │                               │   │   (Fine-tuned)        │     │   │    │    │
│  │  │                               │   └───────────────────────┘     │   │    │    │
│  │  │                               │              │                  │   │    │    │
│  │  │                               └──────────────┼──────────────────┘   │    │    │
│  │  │                                              │                      │    │    │
│  │  └──────────────────────────────────────────────┼──────────────────────┘    │    │
│  │                                                 │                           │    │
│  └─────────────────────────────────────────────────┼───────────────────────────┘    │
│                                                    │                                 │
│                                                    │ (5) Inference                   │
│                                                    ▼                                 │
│  ┌─────────────────────────────────────────────────────────────────────────────┐    │
│  │                           Client Application                                 │    │
│  │                                                                              │    │
│  │   ┌─────────────┐    ┌─────────────┐    ┌─────────────┐                     │    │
│  │   │   Web App   │    │   Mobile    │    │   Backend   │                     │    │
│  │   │             │    │    App      │    │   Service   │                     │    │
│  │   └─────────────┘    └─────────────┘    └─────────────┘                     │    │
│  │                                                                              │    │
│  └─────────────────────────────────────────────────────────────────────────────┘    │
│                                                                                      │
└─────────────────────────────────────────────────────────────────────────────────────┘
```


### 1.2 Component Summary

| Component | AWS Service | Purpose |
|-----------|-------------|---------|
| Fine-tuning Compute | Amazon Elastic Compute Cloud (Amazon EC2) with GPU | Execute Oumi fine-tuning workloads |
| Data Storage | Amazon Simple Storage Service (Amazon S3) | Store training data and model artifacts |
| Model Hosting | Amazon Bedrock | Host and serve fine-tuned models |
| Identity Management | AWS Identity and Access Management (IAM) | Control access to resources |
| Encryption | Amazon S3 Default Encryption | Encrypt data at rest |
| Monitoring | Amazon CloudWatch | Logs and metrics |
| Audit | AWS CloudTrail | API activity logging |

---

## 2. Security Architecture

### 2.1 Security Architecture Diagram

```
┌─────────────────────────────────────────────────────────────────────────────────────┐
│                              Security Architecture                                   │
├─────────────────────────────────────────────────────────────────────────────────────┤
│                                                                                      │
│  ┌─────────────────────────────────────────────────────────────────────────────┐    │
│  │                           Identity & Access Layer                            │    │
│  │                                                                              │    │
│  │   ┌─────────────────┐    ┌─────────────────┐    ┌─────────────────┐        │    │
│  │   │  EC2 Instance   │    │    Bedrock      │    │   S3 Bucket     │        │    │
│  │   │    Profile      │    │  Import Role    │    │    Policy       │        │    │
│  │   │                 │    │                 │    │                 │        │    │
│  │   │ • s3:GetObject  │    │ • bedrock:*     │    │ • Deny HTTP     │        │    │
│  │   │ • s3:PutObject  │    │   (scoped)      │    │ • Enforce TLS   │        │    │
│  │   │ • logs:*        │    │ • s3:GetObject  │    │   1.2+          │        │    │
│  │   └─────────────────┘    └─────────────────┘    └─────────────────┘        │    │
│  │                                                                              │    │
│  └─────────────────────────────────────────────────────────────────────────────┘    │
│                                        │                                             │
│                                        ▼                                             │
│  ┌─────────────────────────────────────────────────────────────────────────────┐    │
│  │                            Encryption Layer                                  │    │
│  │                                                                              │    │
│  │   ┌─────────────────────────────────────────────────────────────────────┐   │    │
│  │   │                   S3 Default Encryption (SSE-S3)                     │   │    │
│  │   │                                                                      │   │    │
│  │   │   ┌─────────────┐    ┌─────────────┐                               │   │    │
│  │   │   │ S3 SSE-S3   │    │ EBS Volume  │                               │   │    │
│  │   │   │ Encryption  │    │ Encryption  │                               │   │    │
│  │   │   └─────────────┘    └─────────────┘                               │   │    │
│  │   │                                                                      │   │    │
│  │   └─────────────────────────────────────────────────────────────────────┘   │    │
│  │                                                                              │    │
│  │   ┌─────────────────────────────────────────────────────────────────────┐   │    │
│  │   │                      TLS 1.2+ (In Transit)                           │   │    │
│  │   │                                                                      │   │    │
│  │   │   • All S3 operations via HTTPS                                      │   │    │
│  │   │   • All API calls via HTTPS                                          │   │    │
│  │   │   • Enforced via bucket policy                                       │   │    │
│  │   │                                                                      │   │    │
│  │   └─────────────────────────────────────────────────────────────────────┘   │    │
│  │                                                                              │    │
│  └─────────────────────────────────────────────────────────────────────────────┘    │
│                                        │                                             │
│                                        ▼                                             │
│  ┌─────────────────────────────────────────────────────────────────────────────┐    │
│  │                           Network Security Layer                             │    │
│  │                                                                              │    │
│  │   ┌─────────────────┐    ┌─────────────────┐    ┌─────────────────┐        │    │
│  │   │  Security       │    │  VPC Endpoints  │    │  Network ACLs   │        │    │
│  │   │  Groups         │    │  (Optional)     │    │  (Optional)     │        │    │
│  │   │                 │    │                 │    │                 │        │    │
│  │   │ • Minimal       │    │ • S3 Gateway    │    │ • Subnet-level  │        │    │
│  │   │   inbound       │    │ • Bedrock       │    │   filtering     │        │    │
│  │   │ • Restricted    │    │ • CloudWatch    │    │                 │        │    │
│  │   │   outbound      │    │                 │    │                 │        │    │
│  │   └─────────────────┘    └─────────────────┘    └─────────────────┘        │    │
│  │                                                                              │    │
│  └─────────────────────────────────────────────────────────────────────────────┘    │
│                                        │                                             │
│                                        ▼                                             │
│  ┌─────────────────────────────────────────────────────────────────────────────┐    │
│  │                         Monitoring & Audit Layer                             │    │
│  │                                                                              │    │
│  │   ┌─────────────────┐    ┌─────────────────┐    ┌─────────────────┐        │    │
│  │   │  CloudTrail     │    │  CloudWatch     │    │  S3 Access      │        │    │
│  │   │                 │    │  Logs           │    │  Logs           │        │    │
│  │   │ • API activity  │    │ • Application   │    │ • Bucket        │        │    │
│  │   │ • All regions   │    │   logs          │    │   operations    │        │    │
│  │   │ • S3 delivery   │    │ • Metrics       │    │ • Access audit  │        │    │
│  │   └─────────────────┘    └─────────────────┘    └─────────────────┘        │    │
│  │                                                                              │    │
│  └─────────────────────────────────────────────────────────────────────────────┘    │
│                                                                                      │
└─────────────────────────────────────────────────────────────────────────────────────┘
```

### 2.2 Security Controls Matrix

| Layer | Control | Implementation | Responsibility |
|-------|---------|----------------|----------------|
| Identity | Least Privilege | Resource-level IAM policies | Customer |
| Identity | No Hardcoded Credentials | IAM instance profiles | Customer |
| Encryption | At Rest | S3 default encryption, encrypted Amazon EBS | Customer (configuration), AWS (infrastructure) |
| Encryption | In Transit | TLS 1.2+ enforced via policy | Customer (policy), AWS (TLS termination) |
| Network | Access Control | Security groups, VPC endpoints | Customer |
| Network | Traffic Isolation | Private subnets (optional) | Customer |
| Monitoring | API Logging | AWS CloudTrail all regions | Customer (configuration), AWS (service) |
| Monitoring | Access Logging | Amazon S3 access logs | Customer (configuration), AWS (delivery) |
| Data | Public Access Prevention | Amazon S3 Block Public Access | Customer |
| Data | Versioning | Amazon S3 versioning for artifacts | Customer |

> **Note**: "Customer" responsibility indicates controls you must configure and maintain. "AWS" responsibility indicates infrastructure and service-level controls managed by AWS. See the [AWS Shared Responsibility Model](https://aws.amazon.com/compliance/shared-responsibility-model/) for details.

---

## 3. Component Details

### 3.1 Amazon EC2 (Fine-tuning Compute)

**Purpose**: Execute Oumi fine-tuning workloads on GPU-enabled instances.

**Configuration**:
- Instance Type: GPU-enabled (e.g., g6.12xlarge, p4d.24xlarge)
- AMI: Deep Learning AMI with CUDA support
- Storage: Encrypted EBS volumes
- IAM: Instance profile with least-privilege permissions

**Interactions**:
- Reads training data from S3
- Writes model artifacts to S3
- Sends logs to CloudWatch
- Relies on S3 default encryption for data at rest

### 3.2 Amazon S3 (Data Storage)

**Purpose**: Store training data, model artifacts, and checkpoints.

**Bucket Structure**:
```
<BUCKET_NAME>/
├── training-data/
│   ├── alpaca_data.json
│   └── custom_data/
├── model-artifacts/
│   ├── checkpoints/
│   └── final/
│       ├── model.safetensors
│       ├── config.json
│       └── tokenizer/
└── logs/
    └── training-logs/
```

**Security Configuration**:
- Block Public Access: Enabled
- Encryption: S3 default encryption (SSE-S3)
- Versioning: Enabled
- Access Logging: Enabled
- Bucket Policy: TLS 1.2+ required

### 3.3 Amazon Bedrock (Model Hosting)

**Purpose**: Host and serve fine-tuned models via Custom Model Import.

**Components**:
- Custom Model Import (CMI): Imports model artifacts from S3
- Bedrock Runtime: Serves inference requests

**Integration**:
- Reads model artifacts from S3
- Uses IAM role for S3 access
- Provides InvokeModel API for inference

### 3.4 AWS IAM (Identity Management)

**Roles**:

1. **EC2 Instance Profile Role**
   - S3 read/write for training data and artifacts
   - CloudWatch Logs for monitoring

2. **Bedrock Import Role**
   - Bedrock CreateModelImportJob, GetModelImportJob
   - S3 read for model artifacts

---

## 4. Data Flow

### 4.1 Training Data Flow

```
┌─────────────┐     ┌─────────────┐     ┌─────────────┐
│   Source    │     │  Amazon S3  │     │  Amazon EC2 │
│   Data      │────▶│  (Encrypted)│────▶│  (Training) │
└─────────────┘     └─────────────┘     └─────────────┘
      │                    │                    │
      │                    │                    │
      ▼                    ▼                    ▼
   Upload              Storage              Processing
   (TLS)               (SSE-S3)            (In-memory)
```

### 4.2 Model Artifact Flow

```
┌─────────────┐     ┌─────────────┐     ┌─────────────┐
│  Amazon EC2 │     │  Amazon S3  │     │   Amazon    │
│  (Training) │────▶│  (Artifacts)│────▶│   Bedrock   │
└─────────────┘     └─────────────┘     └─────────────┘
      │                    │                    │
      │                    │                    │
      ▼                    ▼                    ▼
   Generate            Storage              Import
   (Local)             (SSE-S3)            (CMI)
```

### 4.3 Inference Flow

```
┌─────────────┐     ┌─────────────┐     ┌─────────────┐
│   Client    │     │   Amazon    │     │   Model     │
│ Application │────▶│   Bedrock   │────▶│  Response   │
└─────────────┘     └─────────────┘     └─────────────┘
      │                    │                    │
      │                    │                    │
      ▼                    ▼                    ▼
   Request             Processing           Response
   (TLS)               (Inference)          (TLS)
```

---

## 5. Deployment Architecture

### 5.1 Deployment Workflow

```
┌─────────────────────────────────────────────────────────────────────────────┐
│                          Deployment Workflow                                 │
├─────────────────────────────────────────────────────────────────────────────┤
│                                                                              │
│  ┌─────────┐    ┌─────────┐    ┌─────────┐    ┌─────────┐    ┌─────────┐   │
│  │  Setup  │───▶│  Fine-  │───▶│ Upload  │───▶│ Import  │───▶│ Invoke  │   │
│  │  Env    │    │  Tune   │    │  to S3  │    │   to    │    │  Model  │   │
│  │         │    │         │    │         │    │ Bedrock │    │         │   │
│  └─────────┘    └─────────┘    └─────────┘    └─────────┘    └─────────┘   │
│       │              │              │              │              │         │
│       ▼              ▼              ▼              ▼              ▼         │
│  ┌─────────┐    ┌─────────┐    ┌─────────┐    ┌─────────┐    ┌─────────┐   │
│  │ setup-  │    │ fine-   │    │ upload- │    │ import- │    │ invoke- │   │
│  │ environ │    │ tune.sh │    │ to-s3   │    │ to-     │    │ model   │   │
│  │ ment.sh │    │         │    │ .sh     │    │ bedrock │    │ .sh     │   │
│  │         │    │         │    │         │    │ .sh     │    │         │   │
│  └─────────┘    └─────────┘    └─────────┘    └─────────┘    └─────────┘   │
│                                                                              │
└─────────────────────────────────────────────────────────────────────────────┘
```

### 5.2 Script Dependencies

| Script | Prerequisites | Outputs |
|--------|--------------|---------|
| setup-environment.sh | AWS CLI, Python | Configured environment |
| fine-tune.sh | Oumi framework, GPU | Model artifacts |
| upload-to-s3.sh | S3 bucket | Uploaded artifacts |
| import-to-bedrock.sh | Bedrock role, artifacts | Imported model |
| invoke-model.sh | Imported model | Inference response |

### 5.3 Resource Requirements

| Resource | Minimum | Recommended |
|----------|---------|-------------|
| EC2 Instance | g6.12xlarge (4x L4) | p4d.24xlarge or larger |
| GPU Memory | 96 GB (4x 24 GB L4) | 320+ GB |
| Storage | 100 GB EBS | 500+ GB EBS |
| S3 Storage | 50 GB | 200+ GB |

---

## References

- [Amazon Bedrock Custom Model Import](https://docs.aws.amazon.com/bedrock/latest/userguide/model-customization-import.html)
- [Oumi Framework Documentation](https://github.com/oumi-ai/oumi)
- [AWS Well-Architected Framework - Security Pillar](https://docs.aws.amazon.com/wellarchitected/latest/security-pillar/welcome.html)
- [Amazon EC2 GPU Instances](https://aws.amazon.com/ec2/instance-types/#Accelerated_Computing)
