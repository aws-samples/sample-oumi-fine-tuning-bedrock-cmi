# Fine-Tune LLMs with Oumi and Deploy to Amazon Bedrock

> **Important**: This sample solution demonstrates one approach for fine-tuning LLMs and deploying them to Amazon Bedrock. Security is a shared responsibility between AWS and the customer.
>
> **Customer responsibilities include:**
> - Conducting independent security assessments of this solution
> - Implementing controls appropriate for specific use cases and data classification requirements
> - Maintaining compliance with organizational security requirements
>
> See the [AWS Shared Responsibility Model](https://aws.amazon.com/compliance/shared-responsibility-model/) for more information.

This repository is a companion to the AWS Blog post **"Accelerate custom AI model deployment: Fine-tune with Oumi and deploy to Amazon Bedrock."** It contains the scripts, configurations, and automation needed to execute the end-to-end workflow described in the blog.

## Architecture

```
+----------------+      +----------------+      +----------------+      +----------------+
|   EC2 (GPU)    |      |   Amazon S3    |      |    Amazon      |      |    Client      |
|                |      |                |      |    Bedrock     |      |  Applications  |
|  +---------+   |      |  +---------+   |      |                |      |                |
|  |  Oumi   |---+----->|  | Model   |---+----->|  +---------+   |      |  +---------+   |
|  |         |   |      |  |Artifacts|   |      |  |Imported |---+----->|  | Web/API |   |
|  +---------+   |      |  +---------+   |      |  | Model   |   |      |  +---------+   |
+----------------+      +----------------+      |  +---------+   |      +----------------+
                                               +----------------+
```

| Component | AWS Service | Purpose |
|-----------|-------------|---------|
| Fine-tuning Compute | Amazon EC2 with GPU | Execute Oumi fine-tuning workloads |
| Data Storage | Amazon S3 | Store training data and model artifacts |
| Model Hosting | Amazon Bedrock | Host and serve fine-tuned models |
| Identity Management | AWS IAM | Control access to resources |
| Monitoring | Amazon CloudWatch | Logs and metrics |
| Audit | AWS CloudTrail | API activity logging |

## Prerequisites

- [ ] **AWS account** with permissions to create EC2 instances, IAM roles, and S3 buckets
- [ ] **AWS CLI v2** installed and configured
- [ ] **Hugging Face account** with an access token — required for gated models like Llama 3.2 (request access at [huggingface.co/meta-llama](https://huggingface.co/meta-llama))
- [ ] **EC2 key pair** for SSH access to the training instance — use an existing one or [follow instructions here to create one](https://docs.aws.amazon.com/AWSEC2/latest/UserGuide/create-key-pairs.html)
- [ ] **Security group** allowing SSH (port 22) from your IP — use an existing one or [follow instructions here to create one](https://docs.aws.amazon.com/AWSEC2/latest/UserGuide/creating-security-group.html)

## Set Up AWS Resources

Clone this repository on your local machine:

```bash
git clone https://github.com/aws-samples/sample-oumi-fine-tuning-bedrock-cmi
cd sample-oumi-fine-tuning-bedrock-cmi
```

Run the setup script to create IAM roles, an S3 bucket, and launch a GPU-optimized EC2 instance:

```bash
./scripts/setup-aws-env.sh
```

The script prompts for your AWS region, S3 bucket name, EC2 key pair name, and security group ID, then creates all required resources. Defaults: `g6.12xlarge` instance (4x L4 GPUs), Deep Learning Base AMI with Single CUDA (Amazon Linux 2023), 100 GB gp3 storage.

Use `--dry-run` to preview all commands without executing them:

```bash
./scripts/setup-aws-env.sh --dry-run
```

> If you do not have permissions to create IAM roles or launch EC2 instances, share this repository with your IT administrator and ask them to complete this section to set up your AWS environment.

Once the instance is running, the script outputs the SSH command and the Bedrock import role ARN (needed in Step 5). SSH into the instance and continue with the Quick Start below.

See [iam/README.md](iam/README.md) for IAM policy details, scoping guidance, and validation steps.

## Quick Start

### Step 1. Setup EC2 Environment

On the EC2 instance (Amazon Linux 2023), update the system and install base dependencies:

```bash
sudo yum update -y
sudo yum install python3 python3-pip git -y
```

Clone this repository:

```bash
git clone https://github.com/aws-samples/sample-oumi-fine-tuning-bedrock-cmi
cd sample-oumi-fine-tuning-bedrock-cmi
```

Configure environment variables (replace the values with your actual region and bucket name from the setup script):

```bash
export AWS_REGION=us-west-2
export S3_BUCKET=your-bucket-name
export S3_PREFIX=oumi_llama32_1b_run_01
aws configure set default.region "$AWS_REGION"
```

Run the setup script to create a Python virtual environment and install Oumi:

```bash
./scripts/setup-environment.sh
source .venv/bin/activate
```

Authenticate with Hugging Face to access gated model weights. Generate an access token at [huggingface.co/settings/tokens](https://huggingface.co/settings/tokens), then run:

```bash
hf auth login
```

### Step 2. Configure Training

The default training dataset is `tatsu-lab/alpaca`. To use a different dataset, update `data.train.datasets[0].dataset_name` in `configs/oumi-config.yaml`. See the [Oumi dataset docs](https://oumi.ai/docs/en/latest/resources/datasets/datasets.html) for supported formats.

**(Optional) Generate synthetic training data with Oumi:**

To generate synthetic data using Amazon Bedrock as the inference backend, update the `model_name` placeholder in `configs/synthesis-config.yaml` with a Bedrock model ID you have access to (e.g. `anthropic.claude-sonnet-4-6`), then run:

```bash
oumi synth -c configs/synthesis-config.yaml
```

Output is written to `data/synthetic_geography.jsonl`. Your EC2 instance role must allow `bedrock:InvokeModel` on the foundation model you choose. See [Oumi data synthesis docs](https://oumi.ai/docs/en/latest/user_guides/data_synthesis/data_synthesis.html) for details.

### Step 3. Fine-Tune Model

Use `--dry-run` to validate the configuration without starting training:

```bash
./scripts/fine-tune.sh --config configs/oumi-config.yaml --dry-run
```

Run Oumi fine-tuning with your configuration:

```bash
./scripts/fine-tune.sh --config configs/oumi-config.yaml --output-dir models/final
```

For a quick validation run, use `--max-steps` to limit training to a small number of steps:

```bash
./scripts/fine-tune.sh --config configs/oumi-config.yaml --output-dir models/final --max-steps 50
# Or with oumi directly:
oumi train -c configs/oumi-training.yaml --training.max_steps 50
```

### Step 4. Evaluate Model (Optional)

Run Oumi evaluation to check model quality before deployment:

```bash
oumi evaluate -c configs/evaluation-config.yaml
```

To limit the number of samples per subtask (for a faster run), uncomment `num_samples` in `configs/evaluation-config.yaml`.

### Step 5. Deploy to Bedrock

Still on the EC2 instance, upload model artifacts to S3:

```bash
./scripts/upload-to-s3.sh --bucket $S3_BUCKET --source models/final --prefix $S3_PREFIX
```

Import the model into Amazon Bedrock. Set `BEDROCK_ROLE_ARN` to the Bedrock Role ARN from the `setup-aws-env.sh` output (format: `arn:aws:iam::<ACCOUNT_ID>:role/BedrockModelImportRole`):

```bash
./scripts/import-to-bedrock.sh \
  --model-name my-fine-tuned-llama \
  --s3-uri s3://$S3_BUCKET/$S3_PREFIX \
  --role-arn $BEDROCK_ROLE_ARN \
  --wait
```

Test the deployed model using the model ARN or ID returned by the import:

```bash
./scripts/invoke-model.sh --model-id $MODEL_ARN --prompt "Your test prompt here"
```

> **ModelNotReadyException?** Imported models go through a cold start on first invocation. Retry after a few minutes — warmup typically completes within 10 minutes.

### Step 6. Clean Up

When you are done, clean up resources to avoid ongoing charges:

1. **Terminate the EC2 instance** (use the instance ID from the `setup-aws-env.sh` output) from the [EC2 console](https://console.aws.amazon.com/ec2/) or CLI:
   ```bash
   aws ec2 terminate-instances --instance-ids $INSTANCE_ID
   ```

2. **Delete S3 model artifacts** (if no longer needed):
   ```bash
   aws s3 rm s3://$S3_BUCKET/$S3_PREFIX --recursive
   ```

3. **Delete the imported Bedrock model** from the [Bedrock console](https://console.aws.amazon.com/bedrock/) under Custom models > Imported models.

4. **Delete IAM roles and instance profile** created by the setup script:
   ```bash
   aws iam remove-role-from-instance-profile \
     --instance-profile-name OumiFineTuningInstanceProfile \
     --role-name OumiFineTuningRole
   aws iam delete-instance-profile \
     --instance-profile-name OumiFineTuningInstanceProfile
   aws iam delete-role-policy --role-name OumiFineTuningRole \
     --policy-name OumiFineTuningPolicy
   aws iam delete-role --role-name OumiFineTuningRole
   aws iam delete-role-policy --role-name BedrockModelImportRole \
     --policy-name BedrockModelImportPolicy
   aws iam delete-role --role-name BedrockModelImportRole
   ```

5. **Delete the S3 bucket** (if no longer needed). The bucket must be empty first:
   ```bash
   aws s3 rb s3://$S3_BUCKET
   ```

6. **Delete optional security resources** (if you ran the security scripts):
   - CloudWatch log groups: delete via the [CloudWatch console](https://console.aws.amazon.com/cloudwatch/) under Log groups
   - CloudTrail trails: delete via the [CloudTrail console](https://console.aws.amazon.com/cloudtrail/) under Trails

## Project Structure

```
scripts/     Core workflow automation (setup, fine-tune, upload, import, invoke)
security/    S3 security, CloudWatch/CloudTrail logging, optional KMS encryption setup
configs/     Oumi and training configuration (YAML)
iam/         IAM policy documents and trust policies
tests/       Deployment validation scripts
docs/        Detailed architecture and security documentation
```

## Configuration

| File | Description |
|------|-------------|
| `configs/oumi-config.yaml` | Llama-3.2-1B-Instruct, full fine-tuning parameters, dataset configuration |
| `configs/training-config.yaml` | Hyperparameters, data paths, checkpointing settings |
| `iam/*.json` | IAM policies for EC2 instance profile and Bedrock import role |

## Security

- S3 default encryption (SSE-S3)
- IAM instance profiles (no hardcoded credentials)
- TLS 1.2+ enforced via bucket policy
- Trust remote code enabled for Llama 3.2 tokenizer compatibility

See [Security Guidelines](docs/SECURITY.md) and [Threat Model](docs/THREAT_MODEL.md) for detailed security documentation.

## Troubleshooting

Most scripts support `--dry-run` for validation without execution.

**Exit codes:**

| Code | Meaning |
|------|---------|
| 0 | Success |
| 1 | Invalid arguments |
| 2 | AWS CLI/API error |
| 3 | Validation error |
| 4 | Training/timeout error |

**Validate deployment:**

```bash
./tests/validate-deployment.sh --bucket $S3_BUCKET --verbose
```

## Contributing

See [CONTRIBUTING.md](CONTRIBUTING.md).

## Security Issue Notifications

See [CONTRIBUTING.md](CONTRIBUTING.md#security-issue-notifications).

## License

This project is licensed under the MIT-0 License. See [LICENSE](LICENSE).
