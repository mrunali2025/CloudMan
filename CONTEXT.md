# CloudMan — Full Project Context

> This file is the single entry point for AI assistants (and humans) working on
> this repo. Read it first. It covers what the product is, every feature, the
> architecture, the invariants that must not be broken, and the current state.

## 1. What CloudMan is

**CloudMan is a visual AWS infrastructure control plane.** A developer designs
infrastructure on a node-based canvas, reviews the generated plan, and deploys
it into **their own AWS account** — CloudMan never hosts your infrastructure.

It has two product surfaces:

1. **Infra designer** — drag AWS resources (EC2, S3, VPC, Subnet, Security
   Group, Lambda, RDS, ECS, ALB, …) onto a canvas, wire dependencies, configure
   each node, then Validate → Save → Deploy with a human approval gate between
   plan and apply.
2. **Repo deployer** — point at any GitHub repo, register one of your servers
   over SSH, and CloudMan clones the code, auto-detects the stack (Next.js,
   Vite/React, Node/Express, Python Flask/Django, Spring Boot), builds it on
   your box, renders the runtime unit (systemd / pm2 / nginx), and deploys it
   to your own IP. No agent to install on the target.

## 2. Feature inventory (user-visible)

- **Dashboard** (`/dashboard`) — project cards + aggregate stat cards
  (projects, deployments, success rate, resources under management, monthly
  spend estimate). Project rename/edit inline, per-project deployment history.
- **Canvas editor** (`/projects/[id]`) — drag/drop 25 resource kinds, connect
  consumer→dependency edges, side config panel per node, natural-language
  prompt box ("serverless api with lambda") that loads a curated blueprint
  (optionally LLM-generated via OpenRouter), Validate (compiles server-side,
  shows generated `.tf` files + cost breakdown + risk review + CloudFormation
  export), Versions (immutable snapshots, load any back), Save, Deploy/Destroy.
- **Deploy flow** — pick AWS connection + region → worker plans → plan summary
  (create/update/destroy counts) appears → **you approve** → worker applies
  with live-streamed logs → completion with cost badge. Failed/canceled
  deployments can be retried.
- **Templates** (`/templates`) — browse the 4 blueprints
  (`web-app`, `serverless-api`, `data-pipeline`, `react-app`), one-click
  project creation from any of them.
- **Variables** (`/variables`) — per-browser localStorage key/value store
  (no backend; reserved for future substitution).
- **Settings → AWS** (`/settings/aws`) — register role ARN + external ID
  connections, Verify (STS AssumeRole + GetCallerIdentity) before deploying.
- **Settings → Servers** (`/settings/servers`) — register SSH targets
  (host/port/user/key-or-password), Verify with host-key TOFU pinning,
  credential rotation without delete/recreate.
- **Repo projects** — create `kind:"repo"` projects (repo URL, branch, stack,
  server), trigger deploys, watch progress, see stack/commit/URL/plan summary.
- **Help** (`/help`) — static product docs and links.
- **Auth** (`/login`) — email/password + optional Google OAuth. API returns
  401 without a session; `ALLOW_ANON=1` is a dev-only escape hatch (never in
  production).

## 3. Architecture

```
Browser (Next.js 16 canvas, :3001)
  │  fetch + credentials:include → API (:4000), SameSite=None session cookie
  ▼
Hono API — auth, projects, graph versions, compile preview, deployments, SSE
  │  BullMQ (infra-plan / infra-apply / repo-deploy / infra-maintenance)
  ▼
Worker (no HTTP) — workspace → STS AssumeRole → tofu init/validate/plan/apply
  │  Redis pub/sub  deployment:<id>:events   (+ S3 remote state per project)
  ▼
API SSE endpoint → live logs in the deploy drawer
```

MongoDB stores: projects, immutable graph versions, deployments (with a
500-event ring), AWS connections (external IDs encrypted), SSH servers
(credentials encrypted, host keys pinned). Redis backs BullMQ and the event bus.

## 4. Monorepo layout

```
apps/web        Next.js 16 frontend — canvas, panels, settings, history (:3001)
apps/api        Hono control plane — REST + SSE + Better Auth (:4000)
apps/worker     BullMQ consumers — OpenTofu execution, SSH repo deploys
packages/core   graph schema, validation, IR, HCL + CFN compiler, cost, risk, blueprints
packages/db     Mongoose models + AES-256-GCM secret helpers
packages/queue  queue definitions + Redis pub/sub event bus
packages/auth   Better Auth factory (Mongo adapter)
packages/repo   stack detection, build recipes, runtime-unit rendering
packages/env    t3-env schemas: server | web | worker | queue | db
packages/ui     shadcn-style shared components
```

Plus: `turbo.json`, `vercel.json` (web → Vercel), `apps/*/railway.json` +
`apps/railway-README.md` (api + worker → Railway), `Dockerfile*` +
`docker-compose(.prod).yml`, `.github/workflows/ci.yml`, `.env.example`,
`.env.production.example`.

## 5. The pipeline contract (read before touching core)

`validateGraph()` → `buildIR()` → `compileIR()` / `exportCloudFormation()` /
`estimateCost()` / `analyzeRisks()`. **IR is the single fan-out point.**

- Edges are **consumer → dependency**: `{source, target}` means "source depends
  on target"; the target is emitted first.
- Validation is rule-based with error codes (`SUBNET_CIDR_OUTSIDE_VPC`,
  `SG_NO_VPC`, `LAMBDA_NO_REPOSITORY`, …). New wiring rule = new code + test.
- **Adding a resource kind = 6 places, no exceptions** (every site has a silent
  `default`): `registry/resources/<kind>.ts` (strict zod schema +
  `defineResource`), `registry/index.ts` (register + re-export), `ir/transform.ts`
  `mapAttributes` (camelCase → snake_case; refs as `*_ref`/`*_refs` holding
  **graph node ids**, never addresses), `compiler/index.ts` `writeX` (use
  `refAddress`/`refAttr`; `hclString` for user data, `hclInterpString` only for
  strings you construct), `export/cloudformation.ts` (`KIND_PREFIX` + branch;
  keep parity — `conformance.test.ts` compares backends),
  `apps/web/.../resource-catalog.ts` (icon/accent/fields).
- After any zod schema change, run `bun run generate-catalog` in `apps/web`
  and keep the hand-written catalog in sync. **The catalog must be a subset of
  the schema** — wider options 422 on save.
- `hclString` escapes `${`; `hclEscapeFragment` splices a user fragment into a
  string that keeps an intentional reference live. Never concatenate user input
  into HCL/shell/backend files unescaped (`backendTfContents` throws on unsafe
  values — it runs beside live AWS credentials).

## 6. Deployment lifecycle (do not redesign casually)

```
queued → initializing → planning → awaiting_approval → apply_queued → applying → completed | failed
                                                                                ↘ canceled (pre-apply only)
```

- `awaiting_approval` is the human gate. There is **no mid-apply cancel** and
  no `planned` state (it was removed; don't reintroduce it).
- Transitions are CAS: `updateOne({_id, status: expected})` + `modifiedCount`
  check → 409. Never read-then-write.
- Queues run `attempts: 1`; recovery is manual `POST /:id/retry`, which removes
  the retained BullMQ job (same `jobId` = deployment id) before re-adding.
- Every worker job: guard on expected status, try/catch, set `error` + failure
  event, rethrow. Cancel is re-checked before apply and before completion.
- Each project gets an S3 state bucket (`cloudman-tfstate-<projectId>`);
  destroy reads it back, so teardown survives workspace wipes.

## 7. Auth, secrets, and network rules

- `requireAuth` → 401 without a session. Scope **every** query by owner
  (`loadOwnedProject` / `loadOwnedDeployment`, or `{_id, userId}` filters).
  "Not found" and "not yours" are both 404.
- Session cookie is `SameSite=None + Secure` under `options.advanced`
  (top-level cookie options are silently ignored by better-auth — do not move
  them). Required for the Vercel→Railway split; every mutating route is
  additionally guarded by the Origin-check middleware (`lib/csrf.ts`). Never
  weaken one without the other. `/api/auth/*` relies on better-auth's own
  origin checks and is exempt.
- `CLOUDMAN_SECRET` (64 hex, shared api+worker) encrypts external IDs and SSH
  credentials (AES-256-GCM, `enc:v1:`). Missing key = 503 refusal on credential
  writes, never plaintext. Never log secret values; tofu/SSH output streams
  verbatim into events, so keep secrets out of command lines.
- SSH host keys are trust-on-first-use: verify pins the fingerprint, later
  mismatches refuse. Rate limits key on authenticated `userId` (never trust
  `x-forwarded-for`); bodies capped at 512KB globally; SSE streams capped (one
  Redis connection each); raw SDK/ssh2 errors are logged server-side, clients
  get stable messages.
- Running a repo's build scripts executes untrusted code **by design** — that is
  the feature, not a bug to "fix" by sandboxing unilaterally.

## 8. Commands

```bash
bun install
docker compose up -d                       # mongo :27017 + redis :6379
bun run dev                                # web + api + worker via turbo
bun run dev:web | dev:api | dev:worker     # individually (:3001 / :4000 / -)
bun run check-types                        # tsc across workspaces
bunx turbo run test                        # all suites (needs mongo + redis)
bun run check                              # biome --write (MUTATES)
bunx biome check .                         # read-only lint (0 errors; blocking in CI)
cd apps/web && bun run generate-catalog    # after any zod schema change
```

Tests: `packages/core` + `packages/repo` need no infra; `apps/api` +
`apps/worker` need live Mongo/Redis (separate DBs/Redis DBs so they parallelize).
Mock mode (`CLOUDMAN_WORKER_MOCK=1`) still writes workspaces and events, so
assert on files/events there. e2e files shim `process.getBuiltinModule` for
`"v8"` (bson 7 vs Bun) — keep it.

## 9. Configuration rules

- Web → **Vercel** (`vercel.json`); api + worker → **Railway** (Root Directory =
  repo root, Config File Path = `apps/<svc>/railway.json`); everything →
  Docker (`docker-compose.prod.yml` + `.env.production.example`).
- Railway has no volumes: keep `CLOUDMAN_REMOTE_STATE=1`; set
  `CLOUDMAN_TOFU_AUTOINSTALL=1` on the worker for real runs (Nixpacks ships no
  tofu; the Dockerfile path bakes it in).
- Adding an env var = update **all four**: schema in `packages/env/src/*`,
  `turbo.json` `globalEnv`, `.env.example`, `.env.production.example`.
- Auth-adjacent env: `BETTER_AUTH_SECRET` (32+), `BETTER_AUTH_URL`,
  `CORS_ORIGIN` (single trusted origin — CORS + CSRF both key off it),
  `NEXT_PUBLIC_API_URL`, `ALLOW_ANON` (dev only, never production).
- Internal packages are `@my-better-t-app/*` (root rename never done — don't
  start one mid-change). Code style: tabs, double quotes.
  `apps/web/tsconfig.json` is standalone and weaker than the shared strict base.
- No `TODO`/`FIXME` markers in this repo; unfinished work lives in doc comments
  and the README roadmap.

## 10. Agent skills available in this repo

Project-scope skills live in `.agents/skills/` (+ `.claude/skills/`), locked in
`skills-lock.json` (must resolve to on-disk content):

| Skill | When to load it |
|---|---|
| `cloudman-conventions` | **Load for any change listed in its description** — repo invariants, checklists, gotchas (superset of §5–§9, kept current) |
| `owasp-security` | Anything touching auth, secrets, SSH, HCL emission, the LLM prompt path, or reviewing a diff for vulnerabilities |
| `web-design-guidelines` | UI/accessibility review of `apps/web` + `packages/ui` |
| `vercel-react-best-practices` | React/Next performance work (canvas, waterfalls, bundles) |
| `vercel-composition-patterns` | Component API design |
| `turborepo` | Task graph, caching, CI |
| `code-review` | Diff/PR review workflow |

Manage with `npx skills {list,add,update,remove}`; refresh via `npx skills update -y`.

## 11. Current state and known gaps (as of `41aca28`)

- **197 tests green** (95 core / 37 repo / 53 api / 12 worker — static count;
  `test.each` expansions report higher at runtime), all typechecks pass, Biome
  0 errors, CI green.
- **Never executed live**: real `tofu apply` against AWS and real SSH deploys
  are mock-tested only. First live run may surface IAM/SSH gaps.
- **Accepted risks**: tofu autoinstall has no checksum; repo builds run
  untrusted scripts by design; build output is retained verbatim in events.
- **Minor leftovers**: LLM failure falls back to templates silently; no hard
  block on `ALLOW_ANON=1` in production; 56 Biome warnings (advisory).
- **Needs a human**: Railway/Vercel/AWS access + production secrets
  (`CLOUDMAN_SECRET`, `BETTER_AUTH_SECRET`); staging deploy walkthrough.
