# AWS Setup Guide for CloudMan (Real Deployments)

This guide walks you through everything needed to run real AWS deployments with
CloudMan. You need **two AWS accounts** (or the same account used twice):

| Account | Purpose |
|---------|---------|
| **Worker account** | Where the CloudMan worker runs. Its IAM user/role calls `sts:AssumeRole` into the target. |
| **Target account** | Where infrastructure gets deployed. Contains the deploy role CloudMan assumes. |

> If you're just testing locally, you can use a **single account** for both.

---

## Step 1 — Create a deploy role in the target account

1. Open the **IAM console** in the target AWS account.
2. Go to **Roles → Create role**.
3. Select **Custom trust policy** and paste:

```json
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Effect": "Allow",
      "Principal": {
        "AWS": "arn:aws:iam::WORKER_ACCOUNT_ID:root"
      },
      "Action": "sts:AssumeRole",
      "Condition": {
        "StringEquals": {
          "sts:ExternalId": "YOUR_CHOSEN_EXTERNAL_ID"
        }
      }
    }
  ]
}
```

Replace:
- `WORKER_ACCOUNT_ID` — the 12-digit AWS account ID where the worker runs
  (run `aws sts get-caller-identity` in the worker account to find it).
- `YOUR_CHOSEN_EXTERNAL_ID` — any random string ≥ 8 characters you choose
  (e.g. `cloudman-prod-ext-id-2024`). You'll enter this in the CloudMan UI later.

4. Name the role (e.g. `CloudManDeployRole`) and create it.

---

## Step 2 — Attach permissions to the deploy role

Still in the target account, attach a permissions policy to `CloudManDeployRole`.
Start with this broad policy and tighten `Resource` for production:

```json
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Sid": "CloudManDeploy",
      "Effect": "Allow",
      "Action": [
        "ec2:CreateVpc", "ec2:DeleteVpc",
        "ec2:CreateSubnet", "ec2:DeleteSubnet",
        "ec2:CreateSecurityGroup", "ec2:DeleteSecurityGroup",
        "ec2:AuthorizeSecurityGroupIngress", "ec2:RevokeSecurityGroupEgress",
        "ec2:Describe*", "ec2:CreateTags", "ec2:DeleteTags",
        "ec2:RunInstances", "ec2:TerminateInstances", "ec2:ModifyInstanceAttribute",
        "elasticloadbalancing:CreateLoadBalancer", "elasticloadbalancing:DeleteLoadBalancer",
        "elasticloadbalancing:CreateTargetGroup", "elasticloadbalancing:DeleteTargetGroup",
        "elasticloadbalancing:CreateListener", "elasticloadbalancing:DeleteListener",
        "elasticloadbalancing:Describe*",
        "s3:CreateBucket", "s3:DeleteBucket", "s3:ListBucket", "s3:Get*",
        "s3:PutBucketVersioning", "s3:PutEncryptionConfiguration",
        "ecr:CreateRepository", "ecr:DeleteRepository",
        "ecr:GetAuthorizationToken", "ecr:BatchCheckLayerAvailability",
        "ecr:PutImage", "ecr:InitiateLayerUpload", "ecr:UploadLayerPart",
        "ecr:CompleteLayerUpload",
        "lambda:CreateFunction", "lambda:DeleteFunction", "lambda:GetFunction",
        "lambda:InvokeFunction", "lambda:AddPermission", "lambda:RemovePermission",
        "lambda:PublishVersion", "lambda:UpdateFunctionCode", "lambda:UpdateFunctionConfiguration",
        "apigateway:*",
        "logs:CreateLogGroup", "logs:DeleteLogGroup", "logs:PutLogEvents",
        "ecs:CreateCluster", "ecs:DeleteCluster", "ecs:RegisterTaskDefinition",
        "ecs:DeregisterTaskDefinition", "ecs:CreateService", "ecs:DeleteService",
        "ecs:Describe*",
        "iam:CreateRole", "iam:DeleteRole", "iam:AttachRolePolicy",
        "iam:DetachRolePolicy", "iam:PutRolePolicy", "iam:DeleteRolePolicy",
        "iam:GetRole", "iam:CreateInstanceProfile",
        "iam:DeleteInstanceProfile", "iam:AddRoleToInstanceProfile",
        "iam:RemoveRoleFromInstanceProfile",
        "sts:GetCallerIdentity"
      ],
      "Resource": "*"
    },
    {
      "Sid": "CloudManPassRole",
      "Effect": "Allow",
      "Action": "iam:PassRole",
      "Resource": "arn:aws:iam::*:role/*",
      "Condition": {
        "StringLike": {
          "iam:PassedToService": ["ec2.amazonaws.com", "ecs-tasks.amazonaws.com"]
        }
      }
    }
  ]
}
```

> The `iam:PassRole` entry is scoped with a service condition to avoid the
> wildcard-permissiveness warning. If you don't use EC2 or ECS, you can delete
> that `CloudManPassRole` statement entirely.


> The `sts:GetCallerIdentity` permission is needed for CloudMan's **Verify**
> button to confirm the trust chain end-to-end.

---

## Step 3 — Create an IAM user in the worker account

This user's credentials are what the CloudMan worker uses to assume roles.

1. Open the **IAM console** in the worker account.
2. Go to **Users → Create user**.
3. Name it (e.g. `cloudman-worker`).
4. Attach an inline policy with permission to assume any deploy role:

```json
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Effect": "Allow",
      "Action": "sts:AssumeRole",
      "Resource": "arn:aws:iam::TARGET_ACCOUNT_ID:role/CloudManDeployRole"
    }
  ]
}
```

Replace `TARGET_ACCOUNT_ID` and `CloudManDeployRole` with your values.
For multiple target accounts, add multiple `Resource` entries or use a wildcard.

5. After creation, **create an access key** (Actions → Create access key →
   Access key for CLI, SDK, API). Save the **Access Key ID** and
   **Secret Access Key** — you'll need them next.

---

## Step 4 — Set environment variables on the worker

Add these to the worker's `.env` (or deployment environment):

```bash
# ── Required ──────────────────────────────────────────────
DATABASE_URL=mongodb://localhost:27017/cloudman
REDIS_URL=redis://localhost:6379

# ── AWS credentials (the worker account's IAM user) ──────
AWS_ACCESS_KEY_ID=AKIA...          # from Step 3
AWS_SECRET_ACCESS_KEY=wJal...      # from Step 3
AWS_REGION=us-east-1               # default region for STS calls

# ── Encryption key for stored external IDs ───────────────
# Generate once: node -e "console.log(require('crypto').randomBytes(32).toString('hex'))"
CLOUDMAN_SECRET=<64-char-hex>

# ── Worker mode ──────────────────────────────────────────
CLOUDMAN_WORKER_MOCK=0             # 0 = real AWS, 1 = mock
CLOUDMAN_TOFU_AUTOINSTALL=1        # auto-download OpenTofu if not on PATH
CLOUDMAN_REMOTE_STATE=1            # use S3 for Terraform state (recommended)
```

Also set `CLOUDMAN_SECRET` on the **API** process (same value) so it can
encrypt the external ID when you register a connection.

> The worker auto-installs OpenTofu on **Linux, macOS, and Windows** (x64 + arm64).
> Or install it manually and set `TOFU_PATH=/usr/local/bin/tofu`.

---

## Step 5 — Register the connection in CloudMan UI

1. Open CloudMan → **Settings → AWS connections → Add connection**.
2. Enter:
   - **Label** — anything (e.g. "Production account")
   - **Role ARN** — `arn:aws:iam::TARGET_ACCOUNT_ID:role/CloudManDeployRole`
   - **External ID** — the same string you used in the trust policy (Step 1)
   - **Region** — the default deployment region
3. Click **Verify**. CloudMan will:
   - Call `sts:AssumeRole` with your external ID
   - Call `sts:GetCallerIdentity` with the temporary credentials
   - Show the AWS account ID and ARN on success
4. If verify succeeds, the connection is ready to use when deploying.

---

## Step 6 — Deploy

1. Create a project and design a graph on the canvas.
2. Click **Deploy** → select the AWS connection you registered.
3. Pick a region → click **Deploy**.
4. The worker will:
   - Resolve credentials via STS AssumeRole
   - Create an S3 state bucket (`cloudman-tfstate-<projectId>`) in the target account
   - Run `tofu init`, `tofu validate`, `tofu plan`
5. Review the plan summary → click **Approve**.
6. The worker runs `tofu apply` and streams progress to the browser via SSE.

---

## Troubleshooting

| Symptom | Cause | Fix |
|---------|-------|-----|
| `Failed to download OpenTofu (404)` | Platform not in release URL | Set `TOFU_PATH` to a manually-installed binary |
| `External ID decryption failed` | `CLOUDMAN_SECRET` not set or mismatched | Set the same 64-char hex on both API and worker |
| `AccessDenied` on AssumeRole | Trust policy or permissions wrong | Check the role's trust policy principal + external ID |
| `NoSuchBucket` on state init | S3 state bucket not yet created | Normal on first deploy — worker creates it automatically |
| `AccessDenied` on s3:CreateBucket | Deploy role missing S3 permissions | Add the S3 actions from Step 2 to the role's policy |
| Verify returns 502 | Credentials invalid or role can't be assumed | Re-check access keys and trust policy |

---

## Quick reference: what you need from AWS

| What | Where | Why |
|------|-------|-----|
| Worker account ID | `aws sts get-caller-identity` (worker account) | Goes in the target role's trust policy |
| Target account ID | AWS console header (target account) | Goes in the role ARN |
| Role ARN | IAM → Roles → CloudManDeployRole | Entered in CloudMan UI |
| External ID | You choose it | entered in trust policy + CloudMan UI |
| Access Key ID | IAM → Users → cloudman-worker → Security | Worker env var |
| Secret Access Key | Same as above (shown once) | Worker env var |
| 64-char hex secret | `node -e "console.log(require('crypto').randomBytes(32).toString('hex'))"` | `CLOUDMAN_SECRET` on API + worker |
