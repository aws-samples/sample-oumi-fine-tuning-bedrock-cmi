# Threat Model: Oumi Fine-Tuning to Amazon Bedrock Deployment

> **Important**: This threat model provides a framework for security analysis of this solution. Security is a shared responsibility between AWS and the customer.
>
> **Customer responsibilities include:**
> - Conducting independent threat assessments for specific deployments
> - Implementing appropriate security controls for specific use cases
> - Regularly reviewing and updating threat assessments
>
> See the [AWS Shared Responsibility Model](https://aws.amazon.com/compliance/shared-responsibility-model/) for more information.

## Document Information

| Field | Value |
|-------|-------|
| System Name | Oumi Fine-tuning to Bedrock Deployment |
| Version | 1.0 |
| Last Updated | 2025 |
| Classification | Internal |

## 1. System Overview

This threat model analyzes the security risks associated with fine-tuning AI models using the Oumi framework on Amazon Elastic Compute Cloud (Amazon EC2) and deploying them to Amazon Bedrock via Custom Model Import (CMI).

### 1.1 System Description

The system enables:
- Fine-tuning of foundation models using the Oumi framework on Amazon EC2
- Storage of training data and model artifacts in Amazon Simple Storage Service (Amazon S3)
- Import of fine-tuned models into Amazon Bedrock
- Inference via Amazon Bedrock Runtime API

## 2. System Assets and Classification

### 2.1 Asset Inventory

| Asset | Classification | Location | Owner |
|-------|---------------|----------|-------|
| Training Data | Confidential | Amazon S3 | Data Team |
| Model Weights (Pre-trained) | Confidential | Amazon S3 | ML Team |
| Model Weights (Fine-tuned) | Confidential | Amazon S3, Amazon Bedrock | ML Team |
| Model Checkpoints | Confidential | Amazon S3 | ML Team |
| Configuration Files | Internal | Amazon EC2, Amazon S3 | DevOps |
| AWS Credentials | Secret | IAM Instance Profile | Security Team |
| Training Logs | Internal | Amazon CloudWatch | ML Team |
| API Keys/Tokens | Secret | AWS Secrets Manager | Security Team |

### 2.2 Data Flow Diagram

```
┌─────────────────────────────────────────────────────────────────────────────┐
│                              Data Flow Overview                              │
├─────────────────────────────────────────────────────────────────────────────┤
│                                                                              │
│  ┌──────────────┐                                                            │
│  │   Training   │                                                            │
│  │    Data      │                                                            │
│  │  (Source)    │                                                            │
│  └──────┬───────┘                                                            │
│         │ (1) Upload                                                         │
│         │ [TLS + SSE-S3]                                                    │
│         ▼                                                                    │
│  ┌──────────────┐     (2) Download      ┌──────────────┐                     │
│  │   Amazon S3  │────────────────────▶  │  Amazon EC2  │                     │
│  │   (Storage)  │     [TLS + IAM]       │ (Fine-tuning)│                     │
│  │              │                       │              │                     │
│  │  - Training  │     (3) Upload        │  - Oumi      │                     │
│  │    Data      │◀────────────────────  │    Framework │                     │
│  │  - Model     │     [TLS + SSE-S3]   │  - GPU       │                     │
│  │    Artifacts │                       │    Compute   │                     │
│  └──────┬───────┘                       └──────────────┘                     │
│         │                                                                    │
│         │ (4) Read Artifacts                                                 │
│         │ [TLS + IAM]                                                        │
│         ▼                                                                    │
│  ┌──────────────┐     (5) Inference     ┌──────────────┐                     │
│  │   Amazon     │◀────────────────────  │   Client     │                     │
│  │   Bedrock    │     [TLS + IAM]       │ Application  │                     │
│  │   (CMI)      │────────────────────▶  │              │                     │
│  └──────────────┘     (6) Response      └──────────────┘                     │
│                       [TLS]                                                  │
│                                                                              │
└─────────────────────────────────────────────────────────────────────────────┘
```

## 3. Threat Categories

This threat model uses the STRIDE methodology to categorize threats:

- **S**poofing - Identity impersonation
- **T**ampering - Unauthorized data modification
- **R**epudiation - Denying actions without proof
- **I**nformation Disclosure - Unauthorized data exposure
- **D**enial of Service - Disrupting availability
- **E**levation of Privilege - Gaining unauthorized access

## 4. Identified Threats and Mitigations

### 4.1 Information Disclosure

#### T1: Unauthorized Access to Training Data

| Field | Description |
|-------|-------------|
| **Threat ID** | T1 |
| **Category** | Information Disclosure |
| **Description** | Unauthorized users or services access sensitive training data stored in Amazon S3 |
| **Attack Vector** | Misconfigured S3 bucket policies, overly permissive IAM roles, public bucket access |
| **Impact** | High - Exposure of proprietary or sensitive training data |
| **Likelihood** | Medium |
| **Risk Level** | High |

**Mitigations:**
- Enable S3 Block Public Access on all buckets
- Implement least-privilege IAM policies with resource-level permissions
- Enable S3 access logging for audit trails
- Encrypt data at rest using S3 default encryption
- Enforce TLS via bucket policy with `aws:SecureTransport` condition

#### T2: Model Artifact Exposure

| Field | Description |
|-------|-------------|
| **Threat ID** | T2 |
| **Category** | Information Disclosure |
| **Description** | Fine-tuned model weights are exposed to unauthorized parties |
| **Attack Vector** | S3 bucket misconfiguration, credential theft, insider threat |
| **Impact** | High - Loss of intellectual property, competitive advantage |
| **Likelihood** | Medium |
| **Risk Level** | High |

**Mitigations:**
- Encrypt model artifacts using S3 default encryption
- Implement strict IAM policies for model artifact access
- Enable S3 versioning to track changes
- Use VPC endpoints for S3 access to keep traffic within AWS network

### 4.2 Tampering

#### T3: Training Data Poisoning

| Field | Description |
|-------|-------------|
| **Threat ID** | T3 |
| **Category** | Tampering |
| **Description** | Malicious modification of training data to influence model behavior |
| **Attack Vector** | Compromised data pipeline, insider threat, supply chain attack |
| **Impact** | High - Model produces biased or malicious outputs |
| **Likelihood** | Low |
| **Risk Level** | Medium |

**Mitigations:**
- Implement data provenance tracking
- Enable S3 versioning for training data
- Use checksums to verify data integrity
- Implement access controls limiting who can modify training data
- Review and validate training data before use

#### T4: Model Artifact Tampering

| Field | Description |
|-------|-------------|
| **Threat ID** | T4 |
| **Category** | Tampering |
| **Description** | Unauthorized modification of model weights or checkpoints |
| **Attack Vector** | Compromised EC2 instance, credential theft, insider threat |
| **Impact** | High - Model produces incorrect or malicious outputs |
| **Likelihood** | Low |
| **Risk Level** | Medium |

**Mitigations:**
- Enable S3 versioning for model artifacts
- Implement integrity verification using checksums
- Use IAM policies to restrict write access
- Enable CloudTrail logging for all S3 operations
- Implement MFA delete for critical artifacts

### 4.3 Elevation of Privilege

#### T5: Credential Theft

| Field | Description |
|-------|-------------|
| **Threat ID** | T5 |
| **Category** | Elevation of Privilege |
| **Description** | AWS credentials are stolen and used for unauthorized access |
| **Attack Vector** | Hardcoded credentials, compromised EC2 instance, phishing |
| **Impact** | Critical - Full access to AWS resources |
| **Likelihood** | Medium |
| **Risk Level** | Critical |

**Mitigations:**
- Use IAM instance profiles instead of hardcoded credentials
- Implement least-privilege IAM policies
- Enable AWS CloudTrail for credential usage monitoring
- Use AWS Secrets Manager for any required secrets
- Implement credential rotation policies
- Enable MFA for IAM users

#### T6: IAM Role Escalation

| Field | Description |
|-------|-------------|
| **Threat ID** | T6 |
| **Category** | Elevation of Privilege |
| **Description** | Attacker escalates privileges through overly permissive IAM roles |
| **Attack Vector** | Wildcard permissions, iam:PassRole abuse, trust policy misconfiguration |
| **Impact** | Critical - Unauthorized access to additional AWS resources |
| **Likelihood** | Medium |
| **Risk Level** | High |

**Mitigations:**
- Avoid wildcard (*) actions in IAM policies
- Use resource-level permissions
- Implement strict trust policies for IAM roles
- Regular IAM policy audits using AWS IAM Access Analyzer
- Follow principle of least privilege

### 4.4 Denial of Service

#### T7: Resource Exhaustion

| Field | Description |
|-------|-------------|
| **Threat ID** | T7 |
| **Category** | Denial of Service |
| **Description** | Excessive API calls or compute usage disrupts service availability |
| **Attack Vector** | Compromised credentials, misconfigured automation, malicious actors |
| **Impact** | Medium - Service disruption, increased costs |
| **Likelihood** | Low |
| **Risk Level** | Low |

**Mitigations:**
- Implement AWS Service Quotas
- Set up billing alerts and budgets
- Use Amazon CloudWatch alarms for anomaly detection
- Implement rate limiting for API calls

### 4.5 Repudiation

#### T8: Untracked Actions

| Field | Description |
|-------|-------------|
| **Threat ID** | T8 |
| **Category** | Repudiation |
| **Description** | Actions performed without adequate logging, preventing forensic analysis |
| **Attack Vector** | Disabled logging, log tampering, insufficient log retention |
| **Impact** | Medium - Inability to investigate security incidents |
| **Likelihood** | Medium |
| **Risk Level** | Medium |

**Mitigations:**
- Enable AWS CloudTrail for all regions
- Enable Amazon S3 access logging
- Configure Amazon CloudWatch Logs for Amazon EC2 instances
- Implement log integrity validation
- Set appropriate log retention periods
- Store logs in a separate, protected Amazon S3 bucket

### 4.6 AI/ML-Specific Threats

#### T9: Prompt Injection Attacks

| Field | Description |
|-------|-------------|
| **Threat ID** | T9 |
| **Category** | Tampering |
| **Description** | Malicious prompts designed to manipulate model behavior, bypass safety controls, or extract sensitive information |
| **Attack Vector** | Crafted user inputs containing instructions that override system prompts or exploit model vulnerabilities |
| **Impact** | High - Model produces unintended outputs, leaks training data, or bypasses content filters |
| **Likelihood** | Medium |
| **Risk Level** | High |

**Mitigations:**
- Implement input validation and sanitization for all prompts
- Use system prompts that are resistant to override attempts
- Monitor model outputs for anomalous patterns
- Implement output filtering for sensitive content
- Consider using Amazon Bedrock Guardrails for content filtering
- Log all prompts and responses for audit purposes

#### T10: Model Jailbreaking

| Field | Description |
|-------|-------------|
| **Threat ID** | T10 |
| **Category** | Elevation of Privilege |
| **Description** | Attempts to bypass model safety constraints through adversarial prompting techniques |
| **Attack Vector** | Role-playing scenarios, encoding tricks, multi-turn conversations designed to circumvent safety measures |
| **Impact** | High - Model generates harmful, biased, or policy-violating content |
| **Likelihood** | Medium |
| **Risk Level** | High |

**Mitigations:**
- Implement robust system prompts with clear boundaries
- Use Amazon Bedrock Guardrails to enforce content policies
- Monitor for known jailbreak patterns
- Implement rate limiting to prevent automated attacks
- Conduct regular red team testing of deployed models
- Maintain incident response procedures for jailbreak discoveries

#### T11: Adversarial Input Attacks

| Field | Description |
|-------|-------------|
| **Threat ID** | T11 |
| **Category** | Tampering |
| **Description** | Specially crafted inputs designed to cause model misclassification or unexpected behavior |
| **Attack Vector** | Perturbations to input data that are imperceptible to humans but cause model errors |
| **Impact** | Medium - Model produces incorrect or unreliable outputs |
| **Likelihood** | Low |
| **Risk Level** | Medium |

**Mitigations:**
- Implement input validation and normalization
- Monitor for unusual input patterns
- Consider adversarial training during fine-tuning
- Implement confidence thresholds for model outputs
- Log and analyze edge cases for model improvement

#### T12: Training Data Extraction

| Field | Description |
|-------|-------------|
| **Threat ID** | T12 |
| **Category** | Information Disclosure |
| **Description** | Attempts to extract memorized training data from the fine-tuned model through targeted queries |
| **Attack Vector** | Repeated queries designed to elicit verbatim training data, membership inference attacks |
| **Impact** | High - Exposure of sensitive or proprietary training data |
| **Likelihood** | Low |
| **Risk Level** | Medium |

**Mitigations:**
- Implement differential privacy techniques during training when applicable
- Monitor for repetitive or suspicious query patterns
- Implement rate limiting on model invocations
- Avoid including sensitive PII in training data
- Use data deduplication to reduce memorization risk
- Conduct regular audits for data leakage

## 5. Security Controls Summary

### 5.1 Preventive Controls

| Control | Implementation | Threats Addressed |
|---------|---------------|-------------------|
| Amazon S3 Block Public Access | Enable on all buckets | T1, T2 |
| S3 Default Encryption | Server-side encryption | T1, T2, T4 |
| Least-Privilege IAM | Resource-level permissions | T5, T6 |
| TLS Enforcement | Bucket policy condition | T1, T2 |
| Instance Profiles | No hardcoded credentials | T5 |
| Input Validation | Prompt sanitization | T9, T10, T11 |
| Output Filtering | Content policy enforcement | T9, T10 |
| Rate Limiting | API throttling | T10, T12 |

### 5.2 Detective Controls

| Control | Implementation | Threats Addressed |
|---------|---------------|-------------------|
| AWS CloudTrail | All regions, all events | T3, T4, T5, T6, T8 |
| Amazon S3 Access Logging | All buckets | T1, T2, T3, T4, T8 |
| Amazon CloudWatch Logs | Amazon EC2 and Amazon Bedrock | T7, T8 |
| IAM Access Analyzer | Regular audits | T6 |
| Prompt/Response Logging | Audit trail for model usage | T9, T10, T12 |
| Anomaly Detection | Unusual query pattern monitoring | T10, T11, T12 |

### 5.3 Corrective Controls

| Control | Implementation | Threats Addressed |
|---------|---------------|-------------------|
| Amazon S3 Versioning | All artifact buckets | T3, T4 |
| Incident Response | Documented procedures | All |
| Backup and Recovery | Regular backups | T3, T4, T7 |
| Model Rollback | Version control for models | T3, T4, T9 |

## 6. Risk Assessment Matrix

| Threat ID | Threat Name | Likelihood | Impact | Risk Level | Mitigation Status |
|-----------|-------------|------------|--------|------------|-------------------|
| T1 | Unauthorized Data Access | Medium | High | High | Mitigated |
| T2 | Model Artifact Exposure | Medium | High | High | Mitigated |
| T3 | Training Data Poisoning | Low | High | Medium | Mitigated |
| T4 | Model Artifact Tampering | Low | High | Medium | Mitigated |
| T5 | Credential Theft | Medium | Critical | Critical | Mitigated |
| T6 | IAM Role Escalation | Medium | Critical | High | Mitigated |
| T7 | Resource Exhaustion | Low | Medium | Low | Mitigated |
| T8 | Untracked Actions | Medium | Medium | Medium | Mitigated |
| T9 | Prompt Injection Attacks | Medium | High | High | Mitigated |
| T10 | Model Jailbreaking | Medium | High | High | Mitigated |
| T11 | Adversarial Input Attacks | Low | Medium | Medium | Mitigated |
| T12 | Training Data Extraction | Low | High | Medium | Mitigated |

## 7. Recommendations

### 7.1 Immediate Actions (Priority 1)

1. Enable Amazon S3 Block Public Access on all buckets
2. Enable S3 default encryption for all data at rest
3. Review and restrict IAM policies to least privilege
4. Enable AWS CloudTrail logging in all regions

### 7.2 Short-Term Actions (Priority 2)

1. Implement Amazon S3 versioning for all artifact buckets
2. Configure Amazon CloudWatch alarms for anomaly detection
3. Set up billing alerts and budgets
4. Conduct IAM policy audit using IAM Access Analyzer

### 7.3 Long-Term Actions (Priority 3)

1. Implement automated security scanning in CI/CD pipeline
2. Conduct regular penetration testing
3. Establish security training program for team members
4. Implement infrastructure as code for security configurations

## 8. References

- [AWS Shared Responsibility Model](https://aws.amazon.com/compliance/shared-responsibility-model/)
- [AWS Security Best Practices](https://docs.aws.amazon.com/wellarchitected/latest/security-pillar/welcome.html)
- [Amazon S3 Security Best Practices](https://docs.aws.amazon.com/AmazonS3/latest/userguide/security-best-practices.html)
- [Amazon Bedrock Security](https://docs.aws.amazon.com/bedrock/latest/userguide/security.html)
- [STRIDE Threat Modeling](https://docs.microsoft.com/en-us/azure/security/develop/threat-modeling-tool-threats)

## 9. Document History

| Version | Date | Author | Changes |
|---------|------|--------|---------|
| 1.0 | 2025 | Security Team | Initial threat model |
