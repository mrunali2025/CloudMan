# CloudMan

> **Working on this repo (human or AI)? Start with [`CONTEXT.md`](./CONTEXT.md) —
> the full briefing: every feature, the architecture, the invariants, and the
> current state.**

> **CloudMan is a visual AWS infrastructure control plane** that lets developers design
> infrastructure on a node-based canvas, review the generated OpenTofu plan, and safely
> deploy it into their own AWS account.

Technically: CloudMan converts a visual infrastructure graph into an intermediate
representation (CloudMan IR), compiles it to OpenTofu, executes deployments through an
isolated worker using AWS STS AssumeRole, and streams deployment state back to the
frontend in real time.

CloudMan also ships a **git-repo deployer**: point it at any GitHub repo, register one of
your servers over SSH, and CloudMan clones the code, auto-detects the stack (Next.js,
Vite/React, Node/Express, Python Flask/Django, Spring Boot), builds/renders the runtime
startup unit, and deploys it to your own IP — no agent to install on the box.

## How it works

```
                USER
                 │
        ┌────────▼────────┐
        │  React Web App  │   drag/drop EC2 · S3, configure resources
        │  Visual Canvas  │
        └────────┬────────┘
           Graph JSON (REST)
        ┌────────▼────────┐
        │    API (Hono)   │   auth · projects · graphs · validation
        │  Graph Engine   │   compile preview · deployment control
        └───┬─────────┬───┘
            │         │  BullMQ (infra-plan / infra-apply)
     MongoDB│      ┌──▼──────┐
            │      │ Worker  │   workspace → STS AssumeRole
            │      │         │   tofu init/validate/plan/apply
            │      └──┬──────┘
            │         │ events (Redis pub/sub)
            │      ┌──▼──────┐
            │      │ API SSE │──► live deployment logs in browser
            ▼      └─────────┘
        Graph versions · Deployments · Plan summaries
```

Every deployment follows a strict lifecycle with **human approval** in the middle:

```
queued → initializing → planning → planned → awaiting_approval
       → [user reviews plan] → apply_queued → applying → completed | failed
```

## Monorepo layout

| Path                  | What it is                                                              |
| --------------------- | ----------------------------------------------------------------------- |
| `apps/web`            | Next.js 16 frontend — canvas editor, config panel, deploy drawer, servers & repo-deploy settings |
| `apps/api`            | Hono control-plane API — REST + Better Auth + SSE + SSH verify           |
| `apps/worker`         | Long-running worker — OpenTofu execution, STS AssumeRole, git-repo SSH deploy |
| `packages/core`       | Domain engine: graph schema, validation, dependency resolution, **CloudMan IR**, IR→OpenTofu compiler, **CloudFormation export** |
| `packages/queue`      | BullMQ queue definitions + Redis pub/sub event bus (infra-plan/apply, repo-deploy) |
| `packages/db`         | Mongoose models (projects, graph versions, deployments, AWS connections, SSH servers) |
| `packages/repo`       | Git-repo deploy domain: stack detection, build recipes, runtime rendering, deploy planning |
| `packages/auth`       | Better Auth (email/password, optional Google OAuth) on the MongoDB adapter |
| `packages/env`        | Type-safe environment schemas per app (`server`, `worker`, `queue`, `db`, `web`) |
| `packages/ui`         | Shared shadcn-style components                                           |

## Prerequisites

- [Bun](https://bun.sh) 1.3+
- Docker (for local MongoDB + Redis)
- OpenTofu binary for real deployments (`winget install OpenTofu.Tofu`, or set
  `CLOUDMAN_TOFU_AUTOINSTALL=1` on the worker to auto-download it)

## Getting started

```bash
bun install

# local infrastructure
docker compose up -d

# development (three shells, or use turbo)
bun run dev          # everything via turborepo
bun run dev:web      # http://localhost:3001
bun run dev:api      # http://localhost:4000
bun run dev:worker   # consumes infra-plan / infra-apply queues
```

Each app reads its own `.env` (see `.env.example`). The worker defaults to
`CLOUDMAN_WORKER_MOCK=0`; set `CLOUDMAN_WORKER_MOCK=1` to simulate tofu execution
without touching AWS.

## Using CloudMan

1. Sign up at `http://localhost:3001/login`
2. Create a project from the dashboard (a stat card row shows aggregate
   projects, deployments, success rate, and resources under management)
3. **Describe a stack in the toolbar** (e.g. "serverless api with lambda") and
   hit **Generate** — a curated blueprint is loaded onto the canvas,
   optionally LLM-backed when `OPENROUTER_API_KEY` + `CLOUDMAN_LLM_GENERATION=1`
   are configured. Or drag **EC2**, **S3**, **VPC**, **Subnet** and **Security
   Group** nodes onto the canvas, connect dependencies (arrow = "depends on"),
   configure each node in the side panel
4. **Validate** compiles the graph to OpenTofu server-side, reports any issues,
   and opens a preview of the generated `.tf` files with an estimated **~$/mo
   cost breakdown** and a **security/ops risk review** (browse per file + copy).
   A **CloudFormation export** (`template.json`) is also generated alongside the
   Terraform files, providing an alternative IaC representation of the same stack
5. **Versions** lists every immutable graph snapshot and lets you load any past
   version back onto the canvas
6. **Save** stores a new immutable graph version
7. **Deploy** opens the live deployment view:
   - pick an AWS connection (or worker default creds, dev only) and a region
   - worker validates, prepares a workspace, runs `tofu init/validate/plan`
   - plan summary (create/update/destroy counts per resource) appears for review
   - you approve → worker runs `tofu apply` streaming progress until completion
8. Project cards show **History**, a browsable deployment history with status
   badges, plan summaries, an **~$/mo cost badge** on provision deployments, and
   a **Retry** button for failed/canceled deployments; projects can be
   renamed/edited in place
9. The dashboard analytics endpoint (`GET /api/analytics`) powers the stat cards,
   including an aggregate **monthly spend estimate** across the user's projects

#### Networking wiring rules

Edges are consumer → dependency. The graph validator enforces:

- a **subnet** must connect to exactly one **VPC**, and its CIDR must fall
  inside the VPC's block (`SUBNET_NO_VPC`, `SUBNET_MULTIPLE_VPCS`,
  `SUBNET_CIDR_OUTSIDE_VPC`)
- an **instance** may live in at most one subnet (`EC2_MULTIPLE_SUBNETS`)
- a **security group** must resolve to a VPC either directly (`sg → vpc`) or by
  inheritance through an attached instance's subnet (`SG_NO_VPC`)

The compiler turns these edges into real references: instances receive
`subnet_id` / `vpc_security_group_ids`, subnets receive `vpc_id`, security
groups get an explicit allow-all egress plus their configured ingress rules.

### Connecting your AWS account

Deployments run against **your** AWS account via cross-account role assumption.
Register an AWS connection in *Settings → AWS connections* (role ARN + external
ID), then use **Verify** to prove the chain end-to-end before deploying:
CloudMan calls `sts:AssumeRole` with your external ID and resolves
`sts:GetCallerIdentity` with the temporary credentials.

<details>
<summary>IAM trust policy runbook</summary>

In the target account, create a role (e.g. `CloudManDeployRole`) with a trust
policy that allows CloudMan's worker principal to assume it, conditioned on the
external ID you chose in the connection form:

```json
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Effect": "Allow",
      "Principal": { "AWS": "arn:aws:iam::<WORKER_ACCOUNT_ID>:root" },
      "Action": "sts:AssumeRole",
      "Condition": {
        "StringEquals": { "sts:ExternalId": "<YOUR_EXTERNAL_ID>" }
      }
    }
  ]
}
```

Attach permissions the deployments need, e.g. for the current resource set:

```json
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Effect": "Allow",
      "Action": [
        "ec2:CreateVpc", "ec2:DeleteVpc",
        "ec2:CreateSubnet", "ec2:DeleteSubnet",
        "ec2:CreateSecurityGroup", "ec2:DeleteSecurityGroup",
        "ec2:AuthorizeSecurityGroupIngress", "ec2:RevokeSecurityGroupEgress",
        "ec2:Describe*", "ec2:CreateTags", "ec2:DeleteTags",
        "ec2:RunInstances", "ec2:TerminateInstances", "ec2:ModifyInstanceAttribute",
        "s3:CreateBucket", "s3:DeleteBucket", "s3:ListBucket", "s3:Get*",
        "s3:PutBucketVersioning", "s3:PutEncryptionConfiguration"
      ],
      "Resource": "*"
    }
  ]
}
```

Notes:

- Choose a random external ID (≥ 8 chars); it prevents the confused-deputy
  attack and is stored encrypted at rest when `CLOUDMAN_SECRET` is set on the API.
- Scope `Resource` tighter in production (specific VPC/bucket ARN patterns).

</details>

For local experiments you can instead set `AWS_ACCESS_KEY_ID` /
`AWS_SECRET_ACCESS_KEY` on the worker env.

### State management

Each project gets a dedicated OpenTofu state backend: by default the worker
creates `s3://cloudman-tfstate-<projectId>` in the deployment region (in the
target account, via the assumed role) and writes a `backend.tf` with native S3
lockfile locking before `tofu init`. Destroy runs read state from the same
bucket, so teardown works even if the local workspace was wiped. State buckets
are retained after destroys for auditability — remove them manually if you
don't want them. Set `CLOUDMAN_REMOTE_STATE=0` on the worker to keep state in
the local workspace instead.

## Verification status

- **197 tests across 4 suites**, all green via `bunx turbo run test`
  (requires local MongoDB + Redis — `docker compose up -d`; CI provides them):
  - `packages/core`: 95 unit tests (validation, cycles, topological order, IR
    defaults, CIDR math, networking wiring rules, compiled HCL assertions,
    cost estimation & risk analysis, blueprint generation, CloudFormation export,
    HCL/CFN conformance, HCL interpolation escaping)
  - `packages/repo`: 37 unit tests (stack detection, build recipes, runtime
    rendering incl. shell-escaping, deploy planning)
  - `apps/api`: 53 e2e tests (auth wall + ownership incl. session-cookie attrs,
    kind guards, CAS approve, event persistence, rate limiting, CSRF, compile
    preview, cost/risk, stack generation,
    projects + updates, graph versions, AWS connections, full deployment
    lifecycle, guarded deletes/cancel, retry, dashboard analytics, CloudFormation export, route53 records)
  - `apps/worker`: 12 mock-job tests (plan/apply provisioning, destroy, skips,
    repo-deploy, backend.tf injection guards)
- `bun run check-types` passes in every workspace that defines it, and
  `bunx biome check .` is clean (errors are blocking in CI; warnings remain as
  advisory diagnostics)
- Compiler output accepted by OpenTofu's own HCL parser (`tofu fmt -check` clean)
- Full lifecycle verified end-to-end (mock mode): canvas graph → queued →
  planning → awaiting_approval → approved → completed, with persisted audit
  trail and live SSE events
- Networking stack verified end-to-end (mock mode): vpc → subnet → security group →
  instance wiring, CIDR containment rejection, guarded deletes, destroy + workspace cleanup
- Ops hardening verified end-to-end (mock mode): guarded deletes, deployment
  cancellation and retry, worker-restart reconciliation, encrypted external IDs
- Cost tracking verified end-to-end (mock mode): estimated monthly cost stored
  per deployment, analytics aggregates spend across projects
- CloudFormation export verified end-to-end (mock mode): all 25 catalog kinds
  map to valid AWS:: resource types with wired DependsOn / Ref / GetAtt
- Repo-deploy verified in mock mode (detect → plan → simulated SSH deploy);
  real SSH deploys need a target host and are exercised manually
- Real mode verified up to the AWS boundary (graceful failure without credentials)
- Networking stack verified end-to-end (mock mode): vpc → subnet → security group →
  instance wiring, CIDR containment rejection, guarded deletes, destroy + workspace cleanup
- Ops hardening verified end-to-end (mock mode): guarded deletes, deployment
  cancellation and retry, worker-restart reconciliation, encrypted external IDs
- Cost tracking verified end-to-end (mock mode): estimated monthly cost stored
  per deployment, analytics aggregates spend across projects
- CloudFormation export verified end-to-end (mock mode): all 25 catalog kinds
  map to valid AWS:: resource types with wired DependsOn / Ref / GetAtt
- Real mode verified up to the AWS boundary (graceful failure without credentials)

> The api and worker e2e suites use **separate** test databases and Redis DBs
> (`cloudman_test` / `cloudman_test_worker`) so `turbo run test` can run them in
> parallel safely.

## Roadmap

- Real AWS/prod operations (deploys currently run against a mock boundary;
  real-mode connection verification is validated up to the AWS API call)
- Real SSH repo-deploys against a staging host (mock-covered; needs a
  documented manual runbook)
- Clear the 56 advisory Biome warnings (`noNonNullAssertion`, `useTemplate`,
  `noExplicitAny` are the bulk) now that errors gate CI

## Deploying

- **Web → Vercel** (`vercel.json`; linked project `cloudman-web`). Sync env with
  `bun run env:production` (reads `apps/web/.env`, skips local-only keys).
- **API + worker → Railway** (`apps/api/railway.json`, `apps/worker/railway.json`;
  see `apps/railway-README.md` for the required dashboard settings). Railway has
  no persistent volumes — keep `CLOUDMAN_REMOTE_STATE=1` (default) and set
  `CLOUDMAN_TOFU_AUTOINSTALL=1` on the worker for real runs.
- **Single host → Docker** (`docker-compose.prod.yml`). Copy
  `.env.production.example` to `.env.production`, fill it in, and
  `export CLOUDMAN_SECRET=…` (compose interpolation reads the shell/root
  `.env`, not `.env.production`) — verify with `docker compose config` first.

## Scripts

| Command             | Purpose                          |
| ------------------- | -------------------------------- |
| `bun run check`     | Biome lint/format (write mode)   |
| `bun run check-types` | TypeScript across all packages |
| `bunx turbo run test` | All test suites (core, repo, api, worker; needs Mongo+Redis) |
| `bun run dev`       | Everything via turborepo         |
| `docker compose up -d` | Start MongoDB + Redis         |

> API requests require a session (sign in at `/login`). For frictionless local
> demos only, set `ALLOW_ANON=1` on the API to serve unauthenticated requests
> as a shared workspace user — never enable it in production.
