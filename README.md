# AWS_ECS-TF

A production-grade ECS on Fargate platform: multi-AZ, private-by-default, WAF at
the edge, encrypted everywhere, and ready to take application deployments.

Applications are declared as data. Adding a service to an environment is an edit
to one `services = { ... }` map in that environment's `terraform.tfvars` — no new
Terraform is written per application.

---

## Architecture

```
                       Internet
                          │
                    ┌─────▼──────┐
                    │  WAFv2     │  managed rules, rate limit, geo/IP lists
                    └─────┬──────┘
                    ┌─────▼──────┐
   public subnets   │    ALB     │  :80 → 301 → :443 (TLS 1.3/1.2, ACM)
                    └─────┬──────┘  default action: 404
                          │          access + connection logs → S3
        ┌─────────────────┼─────────────────┐   listener rules per service
   ┌────▼────┐       ┌────▼────┐       ┌────▼────┐
   │  AZ a   │       │  AZ b   │       │  AZ c   │   private subnets
   │ ┌─────┐ │       │ ┌─────┐ │       │ ┌─────┐ │
   │ │task │ │       │ │task │ │       │ │task │ │   Fargate, awsvpc,
   │ └─────┘ │       │ └─────┘ │       │ └─────┘ │   non-root, read-only rootfs
   │  NAT    │       │  NAT    │       │  NAT    │   per-AZ NAT in prod
   └─────────┘       └─────────┘       └─────────┘
        └───────── VPC endpoints ──────────┘
        ECR · Logs · Secrets Manager · SSM · KMS · STS · S3
```

Nothing that serves traffic runs in a public subnet. The only inbound path to a
task is the ALB's security group, referenced by ID rather than by CIDR so it
stays correct if the network changes.

### Repository layout

| Path | Purpose |
| --- | --- |
| `bootstrap/` | S3 state backend + KMS. Applied once per account with local state. |
| `modules/kms/` | Customer-managed keys with least-privilege policies. |
| `modules/vpc/` | Multi-AZ VPC, NAT, flow logs, interface/gateway endpoints. |
| `modules/ecs-cluster/` | Fargate cluster, capacity providers, audited ECS Exec, Service Connect namespace. |
| `modules/alb/` | ALB, TLS listener, access-log bucket, security group. |
| `modules/waf/` | Regional WAFv2 web ACL, logging, IP/geo controls. |
| `modules/ecr/` | Repositories, scanning, lifecycle, immutable tags. |
| `modules/ecs-service/` | The application unit: task definition, service, target group, autoscaling, IAM, alarms. |
| `modules/observability/` | SNS alerting, platform alarms, CloudWatch dashboard. |
| `modules/github-oidc/` | Keyless CI: separate plan and apply roles. |
| `envs/shared/` | Account-level singletons: ECR and the CI roles. |
| `envs/{dev,staging,prod}/` | One state file each. Identical `.tf`; differences live in `terraform.tfvars`. |

The three workload roots share byte-identical `main.tf`, `variables.tf` and
`outputs.tf`. A change proven in dev exercises the same code path in prod, so
environment drift has to be a deliberate edit to a variable rather than an
accident of copy-paste.

---

## Getting started

### 1. Create the state backend (once per account)

```bash
cd bootstrap
terraform init
terraform apply
terraform output backend_hcl
```

Copy the output into `envs/<env>/backend.hcl` for each environment, adjusting the
`key` line. State uses S3-native locking (`use_lockfile`), so there is no
DynamoDB table to manage.

### 2. Deploy shared resources

```bash
# Set github_subjects and the state ARNs in envs/shared/terraform.tfvars first.
make init ENV=shared
make plan ENV=shared && make apply ENV=shared
```

Record the two role ARNs as repository **variables** (not secrets):
`AWS_PLAN_ROLE_ARN` and `AWS_APPLY_ROLE_ARN`.

### 3. Deploy an environment

Set `domain_name` + `route53_zone_id` (a certificate is issued and DNS-validated
for you) **or** `certificate_arn` for an existing certificate. Then:

```bash
make init ENV=dev
make plan ENV=dev && make apply ENV=dev
```

The platform applies cleanly with `services = {}`. An empty platform is a valid
state — stand up the network and edge first, then add applications.

---

## Deploying an application

Add an entry to `services` in the target environment's `terraform.tfvars`:

```hcl
services = {
  api = {
    image                  = "<account>.dkr.ecr.us-east-1.amazonaws.com/ecs-platform/api:v1.4.2"
    container_port         = 8080
    cpu                    = 512
    memory                 = 1024
    min_capacity           = 3
    max_capacity           = 20
    listener_rule_priority = 100          # unique across the listener
    host_headers           = ["api.example.com"]
    health_check_path      = "/healthz"
    create_dns_record      = true

    request_count_target_value = 1000     # scale on load, not just CPU

    environment = { LOG_LEVEL = "info" }

    secrets = {
      DATABASE_URL = "arn:aws:secretsmanager:us-east-1:<account>:secret:prod/api/db-AbCdEf"
    }
  }
}
```

`terraform apply`. The module creates the task definition, service, target group,
listener rule, security group, log group, both IAM roles, autoscaling policies,
six alarms, and (optionally) the Route 53 record.

Guardrails enforced at plan time, before anything is created:

- `:latest` images are rejected — rollback must be deterministic.
- Duplicate `listener_rule_priority` values are rejected.
- A load-balanced service with no `host_headers` or `path_patterns` is rejected,
  because its listener rule could never match.

### What a service gets by default

| Concern | Default |
| --- | --- |
| User | `1000:1000`, non-root |
| Root filesystem | read-only (mount scratch via `writable_volumes`) |
| Placement | private subnets, `assign_public_ip = false` |
| Inbound | only from the ALB security group |
| Deploys | circuit breaker with automatic rollback; apply blocks until steady state |
| Capacity | min 2 tasks, target-tracking on CPU + memory (+ request count if set) |
| AZ balance | `availability_zone_rebalancing = ENABLED` |
| Secrets | injected by reference at task start, never in the task definition |
| Logs | dedicated KMS-encrypted log group, non-blocking driver |
| Alarms | CPU, memory, running-task count, unhealthy hosts, target 5xx, p95 latency |

Set `enable_load_balancer = false` for queue workers; routing, target group and
ALB alarms are skipped, everything else still applies.

---

## Operations

```bash
make check ENV=dev      # fmt + validate + tflint + checkov, same gate as CI
make plan  ENV=staging
make apply ENV=staging
```

**Shell into a task.** ECS Exec is enabled, KMS-encrypted, and every session is
recorded to `/aws/ecs/<cluster>/exec`:

```bash
aws ecs execute-command --cluster ecs-platform-prod --task <task-id> \
  --container api --interactive --command "/bin/sh"
```

**Roll back.** Images are immutable, so point `image` at the previous tag and
apply. The circuit breaker also rolls back automatically on a failed deploy.

**New WAF rules.** Set `waf_count_mode = true` for the first week in a new
environment. Rules evaluate and emit metrics without blocking, so you tune
against real traffic instead of blocking customers on day one.

---

## Security posture

- **No long-lived AWS keys.** CI authenticates with GitHub OIDC. Pull requests
  assume a read-only plan role; only `main` and protected environments can
  assume the apply role. OIDC subjects must name a specific repository — a bare
  wildcard is rejected by variable validation.
- **Privilege-escalation guard.** The apply role can manage workload IAM roles
  but an explicit `Deny` stops it modifying its own role, and `PassRole` is
  bounded by `iam:PassedToService`.
- **Encryption everywhere.** Customer-managed KMS keys with rotation for state,
  log groups, ECS Exec sessions, ECR images and the alarm topic. TLS 1.3/1.2 at
  the edge; `aws:SecureTransport` denied on every bucket policy.
- **Least-privilege task identity.** Execution role (pull image, read secrets,
  write logs) is separate from the task role (what the application can reach),
  so a compromised application inherits neither registry nor secret access.
  Secrets Manager ARNs are trimmed to the secret itself rather than granted by
  wildcard.
- **Confused-deputy guards.** `aws:SourceAccount` / `aws:SourceArn` conditions on
  service trust policies and KMS grants.
- **Defence in depth at the edge.** WAF managed rule sets, rate limiting,
  optional IP and geo lists, `drop_invalid_header_fields`, and
  `desync_mitigation_mode = strictest`.

Static analysis runs on every pull request (Checkov + Trivy, both failing the
build). Every suppression is an inline `#checkov:skip=<id>:<reason>` or
`#trivy:ignore:<id>` comment next to the resource it applies to, so the
justification is reviewed in the same diff as the code. Nothing is skipped
globally. Current state: **374 passed, 0 failed, 45 documented suppressions.**

### Known limitations

- WAF inspects only the first 8 KB of a request body for ALB-associated web
  ACLs, and AWS does not make that configurable. Enforce your own body-size
  limit in the application.
- ALB access-log delivery supports SSE-S3 only, so that one bucket cannot use a
  CMK. This is an AWS constraint, not a choice.
- The default `apply_policy_arns` is `PowerUserAccess`. Scope it down to the
  resource set you actually use once the platform stabilises.

---

## Environment differences

| | dev | staging | prod |
| --- | --- | --- | --- |
| AZs | 2 | 3 | 3 |
| NAT gateways | 1 (shared) | per-AZ | per-AZ |
| Capacity | 100% Spot | Spot + 1 on-demand | on-demand base 2 + Spot |
| ALB deletion protection | off | on | on |
| Container Insights | standard | standard | enhanced |
| Flow log retention | 14d | 30d | 365d |
| WAF rate limit | 5000 | 3000 | 2000 |

Dev runs entirely on Fargate Spot on purpose: interruptions are a useful forcing
function for making services genuinely restart-tolerant before they reach
production.

### Cost notes

The largest fixed costs are NAT gateways (~$32/month each plus data processing)
and the ALB. Interface VPC endpoints have an hourly charge but usually pay for
themselves by keeping ECR pulls, logs and Secrets Manager traffic off NAT. Dev
deliberately shares a single NAT; production does not, because a shared NAT
turns one AZ's failure into an egress outage for the whole environment.

---

## Verification status

| Gate | Result |
| --- | --- |
| `terraform fmt -recursive -check` | clean |
| `terraform validate` | 14/14 roots and modules valid, 0 warnings |
| `tflint --recursive` (0.64.0, aws ruleset 0.48.0) | 0 issues |
| Checkov | 374 passed, 0 failed, 45 documented suppressions |
| Trivy | 0 misconfigurations |

Two roots were additionally verified with a real `terraform plan` against AWS:

- `envs/dev` carrying two services — a load-balanced API with a sidecar and a
  queue worker — planned **109–112 resources, no errors**.
- `envs/shared` planned **15 resources, no errors**.

No `terraform apply` has been run. This repository has not created any AWS
infrastructure yet.
