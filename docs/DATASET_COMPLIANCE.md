# Dataset and Framework Compliance

> **Disclaimer**: This document is provided for informational purposes only and does not constitute legal advice. You are responsible for conducting your own due diligence regarding dataset licensing and compliance requirements.

This document details the licensing and compliance requirements for datasets and frameworks used in the Oumi fine-tuning solution.

## Table of Contents

1. [Alpaca Dataset](#1-alpaca-dataset)
2. [Oumi Framework](#2-oumi-framework)
3. [Base Model Licensing](#3-base-model-licensing)
4. [Third-Party Legal Approval](#4-third-party-legal-approval)
5. [Amazon Bedrock Model Pre-Approval](#5-amazon-bedrock-model-pre-approval)
6. [AI/ML Security Controls](#6-aiml-security-controls)
7. [Compliance Verification](#7-compliance-verification)

---

## 1. Alpaca Dataset

### License Information

| Field | Value |
|-------|-------|
| Dataset Name | Stanford Alpaca |
| License | Apache License 2.0 |
| Source | Stanford University |
| Repository | https://github.com/tatsu-lab/stanford_alpaca |
| Dataset Size | ~52,000 instruction-following examples |

### License Summary

The Apache License 2.0 permits:
- **Commercial use**: The dataset can be used in commercial applications
- **Modification**: The dataset can be modified and adapted
- **Distribution**: The dataset can be redistributed
- **Patent use**: Contributors grant patent rights to users

### Requirements

When using the Alpaca dataset, you must:

1. **Include License**: Include a copy of the Apache 2.0 license with any distribution
2. **State Changes**: Document any modifications made to the dataset
3. **Preserve Notices**: Retain copyright, patent, trademark, and attribution notices
4. **No Trademark Use**: The license does not grant permission to use the licensor's trademarks

### Attribution

Include the following attribution when using the Alpaca dataset:

```
This project uses the Stanford Alpaca dataset, available at
https://github.com/tatsu-lab/stanford_alpaca, licensed under Apache License 2.0.

Citation:
@misc{alpaca,
  author = {Rohan Taori and Ishaan Gulrajani and Tianyi Zhang and Yann Dubois and Xuechen Li and Carlos Guestrin and Percy Liang and Tatsunori B. Hashimoto},
  title = {Stanford Alpaca: An Instruction-following LLaMA model},
  year = {2023},
  publisher = {GitHub},
  howpublished = {\url{https://github.com/tatsu-lab/stanford_alpaca}},
}
```

### Usage Considerations

- The Alpaca dataset was generated using the OpenAI API; verify OpenAI's terms of service for your use case
- The dataset is intended for research and educational purposes
- Evaluate the dataset for your specific compliance requirements

---

## 2. Oumi Framework

### License Information

| Field | Value |
|-------|-------|
| Framework Name | Oumi |
| License | Apache License 2.0 |
| Maintainer | Oumi AI |
| Repository | https://github.com/oumi-ai/oumi |
| Documentation | https://oumi.ai/docs |

### License Summary

The Oumi framework is released under Apache License 2.0, which permits:
- **Commercial use**: Can be used in production commercial systems
- **Modification**: Source code can be modified
- **Distribution**: Can be redistributed in source or binary form
- **Patent use**: Includes explicit patent grant

### Requirements

When using the Oumi framework, you must:

1. **Include License**: Distribute the Apache 2.0 license with any redistribution
2. **State Changes**: Note any modifications to the framework
3. **Preserve Notices**: Keep copyright and attribution notices intact
4. **NOTICE File**: Include the contents of any NOTICE file

### Attribution

Include the following in your project documentation:

```
This project uses the Oumi framework (https://github.com/oumi-ai/oumi),
licensed under Apache License 2.0.
```

---

## 3. Base Model Licensing

### Meta Llama Models

The default configuration uses Meta Llama 3.2 models:

| Field | Value |
|-------|-------|
| Model | Llama 3.2 1B-Instruct / 3B |
| License | Llama 3.2 Community License |
| Licensor | Meta Platforms, Inc. |
| License URL | https://llama.meta.com/llama3_2/license |

### License Requirements

The Llama 3.2 Community License has specific requirements:

1. **Acceptable Use Policy**: You must comply with Meta's Acceptable Use Policy
2. **Attribution**: Include "Built with Llama" in user-facing documentation
3. **Monthly Active Users**: If your product has >700M monthly active users, you must request a separate license from Meta
4. **No Competing Models**: Cannot use outputs to train models that compete with Llama

### Verification Steps

Before deploying a fine-tuned Llama model, copy this checklist and mark items as complete:

- [ ] Review the complete Llama 3.2 Community License
- [ ] Verify compliance with the Acceptable Use Policy
- [ ] Confirm monthly active user thresholds
- [ ] Add required attribution to user-facing materials

> **Template Note**: Check boxes above are intentionally unchecked. Copy this section to your project documentation and check items as you complete them.

---

## 4. Third-Party Legal Approval

Before using third-party frameworks in production, complete the following approval process.

### Oumi Framework Legal Verification

#### Legal Review Checklist
- [ ] Apache 2.0 license reviewed by legal counsel
- [ ] License compatibility verified with your organization's policies
- [ ] Third-party dependencies audited (review Oumi's requirements.txt)
- [ ] NOTICE file requirements documented
- [ ] Approval documented in project records

#### Approval Documentation Template

> **Template Instructions**: Copy this table and replace bracketed placeholders with actual values for your organization's records.

| Field | Value |
|-------|-------|
| Framework | Oumi |
| Version | `[VERSION]` - *Replace with actual version (e.g., 1.0.0)* |
| License | Apache-2.0 |
| Reviewed By | `[NAME/TEAM]` - *Replace with reviewer name or team* |
| Review Date | `[DATE]` - *Replace with review date (YYYY-MM-DD)* |
| Approval Status | `[Approved/Pending/Rejected]` - *Replace with status* |
| Conditions | `[Any conditions or limitations]` - *Replace or write "None"* |

> **Note**: This checklist is for your organization's internal tracking. Consult your legal team for specific requirements.

---

## 5. Amazon Bedrock Model Pre-Approval

### Llama 3.2 Pre-Approval Verification

Before using Llama 3.2 models via Amazon Bedrock, complete the following verification steps.

#### Bedrock Console Verification Steps

1. **Model Access Request**: Navigate to Amazon Bedrock > Model access in the AWS console
2. **Request Access**: Request access to Llama 3.2 models if not already enabled
3. **Verify Status**: Confirm model shows "Access granted" status
4. **Acceptable Use Policy**: Review and accept Meta's Acceptable Use Policy

#### Pre-Approval Checklist

Copy this checklist to your project documentation and mark items as complete:

- [ ] Amazon Bedrock model access requested through AWS console
- [ ] Model access status shows "Access granted"
- [ ] Meta Llama 3.2 Community License reviewed
- [ ] Meta Acceptable Use Policy accepted
- [ ] Monthly active user threshold evaluated (<700M MAU, or separate license obtained)
- [ ] "Built with Llama" attribution planned for user-facing materials

> **Template Note**: Check boxes above are intentionally unchecked. This is a template for your project's compliance tracking.

#### Verification Command

```bash
# Verify model access is enabled
aws bedrock list-foundation-models \
  --query "modelSummaries[?contains(modelId, 'llama')].{ModelId:modelId,Status:modelLifecycle.status}" \
  --output table
```

---

## 6. AI/ML Security Controls

### Input Validation Requirements

All model invocations must implement input validation to prevent prompt injection and other attacks.

#### Prompt Sanitization

Implement the following controls:
- Character encoding normalization (UTF-8)
- Maximum prompt length enforcement
- Pattern-based filtering for known attack vectors
- Rate limiting per user/session

#### Implementation Reference

See `scripts/invoke-model.sh` for the `sanitize_input()` function pattern demonstrating:
- Length validation
- Character filtering
- Encoding normalization

### Output Filtering

#### Content Policy Enforcement

- **Amazon Bedrock Guardrails**: Configure guardrails for automated content filtering
- **Application-Level Validation**: Implement output validation before presenting to users
- **Logging**: Log all prompts and responses for audit (respecting privacy requirements)

### Security Control Checklist

Before deploying your fine-tuned model:

- [ ] Input validation implemented for all user-provided prompts
- [ ] Maximum prompt length enforced
- [ ] Output filtering configured (consider Amazon Bedrock Guardrails)
- [ ] Rate limiting enabled to prevent abuse
- [ ] Anomaly detection monitoring active
- [ ] Prompt/response logging enabled for audit
- [ ] Incident response procedures documented for AI-specific issues

### Monitoring Requirements

Implement the following monitoring controls:
- Log all model invocations with timestamps and user identifiers
- Monitor for unusual query patterns (potential extraction attacks)
- Track response latency for anomaly detection
- Set up alerts for high-volume or suspicious activity

---

## 7. Compliance Verification

### Bias and Fairness Considerations

When fine-tuning AI/ML models, you must evaluate and mitigate potential biases:

#### Pre-Training Assessment
- [ ] Review training data for demographic representation
- [ ] Identify potential sources of bias in the dataset
- [ ] Document known limitations of the training data
- [ ] Evaluate whether the dataset reflects the intended use case population

#### Bias Mitigation Strategies
1. **Data Auditing**: Analyze training data distribution across protected attributes
2. **Balanced Sampling**: Verify representative sampling across demographic groups where applicable
3. **Output Monitoring**: Implement monitoring for biased model outputs in production
4. **Regular Evaluation**: Conduct periodic fairness assessments post-deployment

#### Fairness Metrics
Consider evaluating your fine-tuned model using appropriate fairness metrics:
- Demographic parity
- Equalized odds
- Calibration across groups
- Individual fairness measures

#### Documentation Requirements
Maintain records of:
- Bias assessment methodology used
- Identified biases and mitigation steps taken
- Limitations of the model related to fairness
- Ongoing monitoring procedures

> **Note**: Bias evaluation requirements may vary based on your use case, jurisdiction, and applicable regulations. Consult with appropriate stakeholders for your specific deployment context.

### Pre-Training Checklist

Complete this checklist before starting fine-tuning:

#### Dataset Compliance
- [ ] Training dataset license identified and documented
- [ ] License permits commercial use (if applicable)
- [ ] Attribution requirements documented
- [ ] Dataset source verified and trustworthy
- [ ] No personally identifiable information (PII) unless authorized
- [ ] No copyrighted content without license

#### Framework Compliance
- [ ] Framework license reviewed (Apache 2.0)
- [ ] Third-party dependency licenses checked
- [ ] No GPL-licensed code in dependencies (if incompatible with your use)

#### Base Model Compliance
- [ ] Model license reviewed and accepted
- [ ] Acceptable use policy reviewed
- [ ] Attribution requirements documented
- [ ] User threshold requirements evaluated

### Compliance Documentation Template

Maintain a compliance record for each fine-tuning job:

```yaml
fine_tuning_job:
  job_id: "example-job-2025-01"
  date: "2025-01-15"

base_model:
  name: "meta-llama/Llama-3.2-1B-Instruct"
  license: "Llama 3.2 Community License"
  license_url: "https://llama.meta.com/llama3_2/license"
  license_accepted: true
  acceptable_use_reviewed: true

training_dataset:
  name: "Stanford Alpaca"
  license: "Apache-2.0"
  source: "https://github.com/tatsu-lab/stanford_alpaca"
  modifications: "None"

framework:
  name: "Oumi"
  version: "1.0.0"
  license: "Apache-2.0"

compliance_notes: |
  - All licenses permit commercial use
  - Attribution added to documentation
  - No PII in training data
```

### Ongoing Compliance

1. **License Updates**: Monitor for license changes in dependencies
2. **Version Tracking**: Document versions of all components used
3. **Audit Trail**: Maintain records of compliance reviews
4. **Legal Review**: Consult legal counsel for production deployments

---

## References

- [Apache License 2.0 Full Text](https://www.apache.org/licenses/LICENSE-2.0)
- [Stanford Alpaca Repository](https://github.com/tatsu-lab/stanford_alpaca)
- [Oumi Framework](https://github.com/oumi-ai/oumi)
- [Llama 3.2 License](https://llama.meta.com/llama3_2/license)
- [Open Source Initiative - Apache 2.0](https://opensource.org/licenses/Apache-2.0)
