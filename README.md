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
| `bootstrap/` | S3 state bucket, KMS key and DynamoDB lock table. Greenfield only — this account already has both. |
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

### 1. State backend

State lives in **`s3://bokiti123`**, locked by the **`family_dyning`** DynamoDB
table. Both already exist in this account, so **`bootstrap/` is not needed here** —
skip straight to step 2. The `envs/*/backend.hcl` files are already filled in.

```hcl
bucket         = "bokiti123"
key            = "ecs-platform/<env>/terraform.tfstate"
region         = "us-east-1"
encrypt        = true
dynamodb_table = "family_dyning"
```

> **Why keys are namespaced.** `bokiti123` is shared with other projects, and it
> already contains `dev/terraform.tfstate` and `prod/terraform.tfstate` belonging
> to them. Pointing this platform at those bare keys would make Terraform adopt
> another project's state and plan to destroy it. Every key here sits under
> `ecs-platform/`, matching the convention already used in that bucket
> (`ai-log-investigator/`, `aws-infrastructure/`). **Never use a bare `<env>/`
> key in this bucket.**
>
> Note also that `bokiti123` uses SSE-S3 (AES256), not SSE-KMS, so `backend.hcl`
> deliberately sets no `kms_key_id`.

For a **greenfield account** that has neither resource, `bootstrap/` creates both
(bucket, KMS key, and lock table — 10 resources):

```bash
cd bootstrap && terraform init && terraform apply
terraform output backend_hcl     # paste into each envs/*/backend.hcl
```

It also runs safely against an account that already has them:

```bash
terraform apply -var create_state_bucket=false -var create_lock_table=false
```

### 2. Deploy shared resources

```bash
# Set github_subjects and the state ARNs in envs/shared/terraform.tfvars first.
make init ENV=shared
make plan ENV=shared && make apply ENV=shared
```

Record the two role ARNs as repository **variables** (not secrets):
`AWS_PLAN_ROLE_ARN` and `AWS_APPLY_ROLE_ARN`.

> **CI before this point.** The pipeline's `plan` and `apply` jobs need those
> roles, which only exist once `envs/shared` is applied. Until both variables
> are set, a `preflight` job detects it and skips them, printing this checklist
> in the run summary instead of failing inside the credentials action.
> `fmt`, `validate`, `tflint`, Checkov and Trivy still run on every pull
> request, so nothing goes unchecked while you bootstrap.

This ordering is inherent, not incidental: the pipeline's own identity is one of
the things the pipeline manages, so the first apply of `envs/shared` has to
happen from a workstation.

### 3. Delegate the domain

The platform serves **`skybroe.com`**. `envs/shared` creates one public hosted
zone for it; each environment issues its own certificate for its own name inside
that zone:

| Environment | Certificate names |
| --- | --- |
| dev | `dev.skybroe.com`, `*.dev.skybroe.com` |
| staging | `staging.skybroe.com`, `*.staging.skybroe.com` |
| prod | `skybroe.com`, `*.skybroe.com` |

**Delegation is automated.** `skybroe.com` is registered in this account through
Route 53 Domains (auto-renew on, expires 2027-05-29), so `envs/shared` points the
registered domain's name servers straight at the zone it creates — via
`aws_route53domains_registered_domain`, controlled by `manage_domain_delegation`.
There is no manual registrar step.

> **This rewrites live delegation.** The domain's NS records currently point at
> Route 53 nameservers for a hosted zone that no longer exists in this account,
> so `skybroe.com` does not resolve today and nothing is being served from it.
> Repointing it is therefore safe here. If anything *else* ever becomes
> authoritative for this domain — including a zone in another AWS account — set
> `manage_domain_delegation = false` before applying, or this will take it over.

```bash
make apply ENV=shared
dig NS skybroe.com    # should return the four ns-*.awsdns-* servers of the new zone
```

Propagation takes a few minutes. ACM cannot validate until it completes, so
confirm the NS records resolve before applying an environment — otherwise the
apply waits out `certificate_validation_timeout` (default 15m) and fails. That
is the most likely reason a first apply hangs.

For a domain registered **outside** this account, leave
`manage_domain_delegation = false`, apply `envs/shared`, then copy its
`route53_name_servers` output to the registrar by hand.

Environments find the zone by name, so no zone ID is copied between them. This
does mean **`envs/shared` must be applied before dev/staging/prod can even
plan** — without the zone, the lookup fails with `no matching Route 53 Hosted
Zone found`. To decouple an environment from that ordering, set its
`route53_zone_id` explicitly; it takes precedence and skips the lookup.

To use a certificate you already hold instead, set `certificate_arn` and leave
the domain variables unset.

### 4. Deploy an environment

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
    host_headers           = ["api.skybroe.com"]
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
- DNSSEC is not enabled on the hosted zone. It only takes effect once DS records
  are published at the registrar, and a half-configured chain of trust makes a
  domain unresolvable rather than merely unsigned — so it is a deliberate step
  to take after delegation is stable, not part of first stand-up.
- Certificates carry a wildcard SAN so services can add hostnames without a
  reissue. One private key therefore covers the whole subdomain space; list
  explicit SANs instead if that trade-off is unacceptable.

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

## Cleaning up

Everything this platform runs costs money whether or not a container is serving
traffic. `make cost` reports what is billable, read from Terraform state:

```
ENV         NAT  ENDP   ALB   EIP   WAF   KMS  ZONE    EST $/MO
shared        0     0     0     0     0     1     1        1.50
dev           1    16     1     1     1     1     2      182.73
staging       3    24     1     3     1     1     2      314.13
prod          0     0     0     0     1     1     1       12.50
ESTIMATED FIXED MONTHLY TOTAL                          $510.86
```

Counts come from state, never from sweeping the account by resource type. That
distinction is load-bearing: this account also hosts `talatwo` and
`banking-platform`, whose NAT gateways and load balancers are indistinguishable
from ours in a CLI query. Of the 3 ALBs and 11 Elastic IPs currently in the
region, only 2 and 4 belong to this platform.

### Tearing down

```bash
make teardown-plan ENV=dev     # what would go, changes nothing
make teardown      ENV=dev     # tear down one environment
make teardown-all              # everything, in dependency order
```

Teardown destroys exclusively through `terraform destroy`, so it can only ever
touch resources in our own state. Before destroying it clears the three things
that deliberately block one — each aimed at a specific resource read from our
own outputs, never a wildcard:

| Blocker | Why it exists | How teardown clears it |
| --- | --- | --- |
| ALB deletion protection | Stops an accidental `destroy` deleting the front door | Disabled on that one load balancer ARN |
| Non-empty access-log bucket | `force_destroy` is off so logs are not silently lost | Every object **version and delete marker** removed; a versioned bucket is not empty until both are gone, and `aws s3 rm --recursive` clears neither |
| Images in ECR | `force_delete` is off so a repo cannot be dropped with images in it | Images deleted from the repositories named in `shared`'s output |

Order is **prod → staging → dev → shared**, and the script re-sorts whatever you
pass into that order. `shared` must go last: the workload roots look up the
hosted zone it owns, so destroying it first leaves the others unable to plan.

Confirmation requires typing `destroy`; `--yes` skips it for automation.

### What teardown deliberately leaves behind

- **KMS keys** enter a 30-day pending-deletion window rather than vanishing.
  They keep billing (~$1/month each) until deletion completes.
- **The registered domain** `skybroe.com` is never deleted — only its hosted
  zone. Its NS records then point at a zone that no longer exists, so it stops
  resolving, which is exactly the state it was in before this platform was
  first applied.
- **Terraform state objects** under `ecs-platform/` in `s3://bokiti123` stay put.
  They are a few KB and record what existed.
- **Nothing belonging to another stack**, ever. That is the whole reason
  teardown is state-driven rather than a CLI sweep.

---

## Deployment status

Deployed to account `694992586025` / `us-east-1` on 2026-08-09.

| Root | State | Detail |
| --- | --- | --- |
| `shared` | **deployed** | 19 resources. Zone `Z00990161YDCIUY3TO24J`, NS delegation, DNS query logging, ECR (`api`, `web`), both CI roles. |
| `dev` | **deployed** | 69 resources. 2 AZ, shared NAT, ALB, WAF, ECS cluster. |
| `staging` | **deployed** | 79 resources. 3 AZ, per-AZ NAT, ALB, WAF, ECS cluster. |
| `prod` | **partial** | Blocked by a regional VPC quota, see below. Certificate, log bucket and WAF exist; VPC and everything downstream do not. |

`terraform plan -detailed-exitcode` returns 0 for shared, dev and staging — all
three are converged with no drift. All four state files live under the
`ecs-platform/` prefix in `s3://bokiti123`.

Live: ECS clusters `ecs-platform-dev` and `ecs-platform-staging`; ALBs for both;
WAF web ACLs for all three environments; ACM certificates `dev.skybroe.com`,
`staging.skybroe.com` and `skybroe.com` all `ISSUED`.

No ECS services are running — every environment has `services = {}`, so the
platform is standing but idle. That is the intended starting state.

### prod is blocked on a VPC quota

`us-east-1` allows 5 VPCs per region and is at 5: the AWS default VPC,
`talatwo-vpc` and `banking-platform-prod` (both belonging to other projects), plus
`ecs-platform-dev` and `ecs-platform-staging`. prod's apply failed with
`VpcLimitExceeded`.

A Service Quotas increase to 10 was requested on 2026-08-09 (request
`d2d36a79cb2246f7a6874f7802e23659CzioQRyc`). Once approved:

```bash
make plan ENV=prod && make apply ENV=prod
```

prod's partial state needs no cleanup — the certificate for `skybroe.com` is
already issued and will be reused.

### A CIDR collision to be aware of

`talatwo-vpc` uses `10.20.0.0/16`, the same range as `ecs-platform-staging`. They
do not conflict today because nothing connects them, but staging can never be
peered with that VPC. Change `vpc_cidr` in `envs/staging/terraform.tfvars` before
any peering or Transit Gateway work.

### Static analysis

| Gate | Result |
| --- | --- |
| `terraform fmt -recursive -check` | clean |
| `terraform validate` | 14/14 roots and modules valid |
| `tflint --recursive` (0.64.0, aws ruleset 0.48.0) | 0 issues |
| Checkov | 380 passed, 0 failed, 57 documented suppressions |
| Trivy | 0 misconfigurations |
