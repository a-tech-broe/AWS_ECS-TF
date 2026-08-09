#!/usr/bin/env bash
#
# Destroy the cost-incurring infrastructure this platform owns.
#
# Everything is destroyed through `terraform destroy`, so only resources in our
# own state are ever touched. This account also hosts talatwo, banking-platform
# and other stacks whose NAT gateways and load balancers are indistinguishable
# from ours in a CLI query — sweeping by resource type would be catastrophic.
# The AWS CLI is used for exactly three things, each against a resource name
# read from our own Terraform output.
#
# Three settings deliberately block a plain `terraform destroy`, because they
# exist to stop accidents. Teardown has to unblock them on purpose:
#
#   1. ALB deletion protection   (on in staging/prod)
#   2. Non-empty, versioned access-log buckets  (force_destroy is off)
#   3. ECR repositories holding images          (force_delete is off)
#
# Order is prod -> staging -> dev -> shared. The workload roots look up the
# hosted zone that `shared` owns, so destroying shared first would leave the
# others unable to even plan.

set -euo pipefail

readonly REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
readonly DESTROY_ORDER=(prod staging dev shared)

DRY_RUN=0
ASSUME_YES=0
TARGETS=()

log()  { printf '\033[1m==> %s\033[0m\n' "$*"; }
warn() { printf '\033[33m    %s\033[0m\n' "$*"; }
err()  { printf '\033[31mERROR: %s\033[0m\n' "$*" >&2; }

usage() {
  cat <<'EOF'
Usage: scripts/teardown.sh [--all | ENV...] [--dry-run] [--yes]

  --all       Tear down every environment, in dependency order.
  ENV...      One or more of: shared dev staging prod
  --dry-run   Show a destroy plan for each target and change nothing.
  --yes       Skip the interactive confirmation (for automation).

Examples:
  scripts/teardown.sh dev --dry-run     # what would dev's teardown remove?
  scripts/teardown.sh dev               # tear down dev only
  scripts/teardown.sh --all             # tear down everything
EOF
}

parse_args() {
  [[ $# -eq 0 ]] && { usage; exit 1; }
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --all)     TARGETS=("${DESTROY_ORDER[@]}") ;;
      --dry-run) DRY_RUN=1 ;;
      --yes)     ASSUME_YES=1 ;;
      -h|--help) usage; exit 0 ;;
      shared|dev|staging|prod) TARGETS+=("$1") ;;
      *) err "unknown argument: $1"; usage; exit 1 ;;
    esac
    shift
  done
  [[ ${#TARGETS[@]} -eq 0 ]] && { err "no environment selected"; exit 1; }

  # Always honour dependency order regardless of the order given on the CLI.
  local ordered=()
  for env in "${DESTROY_ORDER[@]}"; do
    for t in "${TARGETS[@]}"; do
      [[ "$t" == "$env" ]] && ordered+=("$env") && break
    done
  done
  TARGETS=("${ordered[@]}")
}

has_state() {
  local env="$1"
  [[ -n "$(terraform -chdir="${REPO_ROOT}/envs/${env}" state list 2>/dev/null | head -1)" ]]
}

tf_output() {
  terraform -chdir="${REPO_ROOT}/envs/$1" output -raw "$2" 2>/dev/null || true
}

# --- Unblock steps ------------------------------------------------------------

disable_alb_deletion_protection() {
  local env="$1"
  local arn
  arn=$(terraform -chdir="${REPO_ROOT}/envs/${env}" state show module.alb.aws_lb.this 2>/dev/null \
        | awk -F'"' '/^[[:space:]]+arn[[:space:]]+=/ { print $2; exit }')
  [[ -z "$arn" ]] && return 0

  log "  disabling deletion protection on the load balancer"
  aws elbv2 modify-load-balancer-attributes \
    --load-balancer-arn "$arn" \
    --attributes Key=deletion_protection.enabled,Value=false \
    >/dev/null 2>&1 || warn "could not modify $arn (already gone?)"
}

empty_bucket() {
  local bucket="$1"
  [[ -z "$bucket" ]] && return 0
  aws s3api head-bucket --bucket "$bucket" >/dev/null 2>&1 || return 0

  log "  emptying s3://${bucket} (all versions and delete markers)"
  # A versioned bucket is only empty once every version AND every delete marker
  # is gone; `aws s3 rm --recursive` removes neither.
  local page
  while :; do
    page=$(aws s3api list-object-versions --bucket "$bucket" --max-keys 500 \
             --query '{Objects: (Versions[].{Key:Key,VersionId:VersionId} || `[]`)[], Markers: (DeleteMarkers[].{Key:Key,VersionId:VersionId} || `[]`)[]}' \
             --output json 2>/dev/null || echo '{}')
    local objects
    objects=$(python3 - "$page" <<'PY'
import json, sys
try:
    d = json.loads(sys.argv[1]) or {}
except Exception:
    print("[]"); raise SystemExit
items = (d.get("Objects") or []) + (d.get("Markers") or [])
items = [i for i in items if i and i.get("Key")]
print(json.dumps(items))
PY
)
    [[ "$objects" == "[]" || -z "$objects" ]] && break
    python3 - "$objects" > /tmp/tf-teardown-delete.json <<'PY'
import json, sys
print(json.dumps({"Objects": json.loads(sys.argv[1]), "Quiet": True}))
PY
    aws s3api delete-objects --bucket "$bucket" --delete "file:///tmp/tf-teardown-delete.json" >/dev/null 2>&1 || break
  done
  rm -f /tmp/tf-teardown-delete.json
}

empty_ecr_repositories() {
  log "  deleting images from ECR repositories"
  local repos
  repos=$(terraform -chdir="${REPO_ROOT}/envs/shared" output -json ecr_repository_names 2>/dev/null \
          | python3 -c 'import json,sys; print("\n".join(json.load(sys.stdin).values()))' 2>/dev/null || true)
  [[ -z "$repos" ]] && return 0

  while read -r repo; do
    [[ -z "$repo" ]] && continue
    local ids
    ids=$(aws ecr list-images --repository-name "$repo" --query 'imageIds[]' --output json 2>/dev/null || echo '[]')
    [[ "$ids" == "[]" ]] && continue
    aws ecr batch-delete-image --repository-name "$repo" --image-ids "$ids" >/dev/null 2>&1 \
      || warn "could not clear images from $repo"
  done <<< "$repos"
}

unblock() {
  local env="$1"
  case "$env" in
    dev|staging|prod)
      disable_alb_deletion_protection "$env"
      empty_bucket "$(tf_output "$env" alb_access_logs_bucket)"
      ;;
    shared)
      empty_ecr_repositories
      ;;
  esac
}

# --- Teardown -----------------------------------------------------------------

destroy_env() {
  local env="$1"
  local dir="${REPO_ROOT}/envs/${env}"

  if ! has_state "$env"; then
    log "${env}: no state, nothing to destroy"
    return 0
  fi

  if [[ $DRY_RUN -eq 1 ]]; then
    log "${env}: destroy plan (no changes will be made)"
    terraform -chdir="$dir" plan -destroy -input=false -lock-timeout=5m -no-color \
      | grep -E '^(Plan:|No changes)' || true
    return 0
  fi

  log "${env}: removing the settings that block destroy"
  unblock "$env"

  log "${env}: destroying"
  terraform -chdir="$dir" destroy -auto-approve -input=false -lock-timeout=5m -no-color \
    | tail -5
}

confirm() {
  [[ $ASSUME_YES -eq 1 || $DRY_RUN -eq 1 ]] && return 0

  echo
  warn "This permanently destroys the following environments:"
  printf '      %s\n' "${TARGETS[*]}"
  warn "Terraform state for them will be emptied. This cannot be undone."
  echo
  read -r -p "    Type 'destroy' to proceed: " reply
  [[ "$reply" == "destroy" ]] || { err "aborted"; exit 1; }
}

main() {
  parse_args "$@"

  log "Teardown targets (dependency order): ${TARGETS[*]}"
  "${REPO_ROOT}/scripts/cost-inventory.sh" 2>/dev/null | sed -n '1,20p' || true

  confirm

  for env in "${TARGETS[@]}"; do
    destroy_env "$env"
  done

  if [[ $DRY_RUN -eq 0 ]]; then
    echo
    log "Teardown complete. Remaining cost surface:"
    "${REPO_ROOT}/scripts/cost-inventory.sh" 2>/dev/null | sed -n '1,20p' || true
    cat <<'EOF'

Not removed by this script, by design:
  - KMS keys enter a 30-day pending-deletion window. They stop being billed
    only when deletion completes; cancel it if you want them back.
  - The registered domain skybroe.com is never deleted. Its NS records keep
    pointing at the destroyed hosted zone, so it stops resolving — the same
    state it was in before this platform was first applied.
  - Terraform state objects in s3://bokiti123 under ecs-platform/ are left in
    place; they are a few KB and hold the audit trail of what existed.
EOF
  fi
}

main "$@"
