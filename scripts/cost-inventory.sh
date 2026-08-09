#!/usr/bin/env bash
#
# Report the billable resources this platform owns, per environment.
#
# Counts come from Terraform state, never from sweeping the account by resource
# type. That distinction matters: this account also hosts talatwo, banking-platform
# and other stacks, and their load balancers and NAT gateways look identical to a
# CLI query. Anything not in our state is not ours to report on or bill for.
#
# Prices are coarse us-east-1 list estimates for the fixed hourly component only.
# They exclude data processing, LCU, request and storage charges, so treat the
# total as a floor, not a forecast.

set -euo pipefail

readonly REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
readonly ENVIRONMENTS=(shared dev staging prod)

# Fixed monthly cost per unit, USD, us-east-1.
readonly PRICE_NAT_GATEWAY=32.85     # $0.045/hr
readonly PRICE_ENDPOINT_ENI=7.30     # $0.01/hr per AZ
readonly PRICE_ALB=16.43             # $0.0225/hr, before LCUs
readonly PRICE_EIP=3.65              # $0.005/hr per public IPv4
readonly PRICE_WAF_ACL=5.00          # per web ACL
readonly PRICE_WAF_RULE=1.00         # per rule / managed rule group
readonly PRICE_KMS_KEY=1.00          # per customer-managed key
readonly PRICE_HOSTED_ZONE=0.50      # per hosted zone

bold() { printf '\033[1m%s\033[0m\n' "$1"; }

state_types() {
  # Resource addresses in state for one environment, or nothing if uninitialised.
  local env="$1"
  terraform -chdir="${REPO_ROOT}/envs/${env}" state list 2>/dev/null || true
}

count_type() {
  local needle="$1"
  shift
  printf '%s\n' "$@" | grep -c "${needle}" || true
}

main() {
  local grand_total=0
  local any_state=0

  bold "Billable resources owned by this platform"
  echo "Source: Terraform state under envs/*. Other stacks in this account are excluded."
  echo

  printf '%-9s %5s %5s %5s %5s %5s %5s %5s  %10s\n' \
    ENV NAT ENDP ALB EIP WAF KMS ZONE "EST \$/MO"
  printf '%s\n' "-------------------------------------------------------------------"

  for env in "${ENVIRONMENTS[@]}"; do
    local addresses
    mapfile -t addresses < <(state_types "$env")

    if [[ ${#addresses[@]} -eq 0 ]]; then
      printf '%-9s %5s %5s %5s %5s %5s %5s %5s  %10s\n' "$env" - - - - - - - "not deployed"
      continue
    fi
    any_state=1

    local nat endpoints alb eip waf kms zones
    nat=$(count_type 'aws_nat_gateway\.' "${addresses[@]}")
    endpoints=$(count_type 'aws_vpc_endpoint\.interface' "${addresses[@]}")
    alb=$(count_type 'aws_lb\.this' "${addresses[@]}")
    eip=$(count_type 'aws_eip\.' "${addresses[@]}")
    waf=$(count_type 'aws_wafv2_web_acl\.' "${addresses[@]}")
    kms=$(count_type 'aws_kms_key\.' "${addresses[@]}")
    zones=$(count_type 'aws_route53_zone\.\|aws_service_discovery_private_dns_namespace\.' "${addresses[@]}")

    # Each interface endpoint bills one ENI per AZ it spans, so multiply by AZs.
    local azs
    azs=$(count_type 'aws_subnet\.private\[' "${addresses[@]}")
    [[ $azs -eq 0 ]] && azs=1

    # Managed rule groups plus the rate-limit rule, all billed per rule.
    local waf_rules=$(( waf * 6 ))

    local subtotal
    subtotal=$(awk -v n="$nat" -v e="$endpoints" -v z="$azs" -v l="$alb" -v i="$eip" \
                   -v w="$waf" -v wr="$waf_rules" -v k="$kms" -v hz="$zones" \
                   -v pn="$PRICE_NAT_GATEWAY" -v pe="$PRICE_ENDPOINT_ENI" -v pl="$PRICE_ALB" \
                   -v pi="$PRICE_EIP" -v pw="$PRICE_WAF_ACL" -v pwr="$PRICE_WAF_RULE" \
                   -v pk="$PRICE_KMS_KEY" -v pz="$PRICE_HOSTED_ZONE" \
                   'BEGIN { printf "%.2f", n*pn + e*z*pe + l*pl + i*pi + w*pw + wr*pwr + k*pk + hz*pz }')

    grand_total=$(awk -v a="$grand_total" -v b="$subtotal" 'BEGIN { printf "%.2f", a+b }')

    printf '%-9s %5s %5s %5s %5s %5s %5s %5s  %10s\n' \
      "$env" "$nat" "$((endpoints * azs))" "$alb" "$eip" "$waf" "$kms" "$zones" "$subtotal"
  done

  printf '%s\n' "-------------------------------------------------------------------"
  printf '%-51s %10s\n' "ESTIMATED FIXED MONTHLY TOTAL" "\$${grand_total}"
  echo

  if [[ $any_state -eq 0 ]]; then
    echo "No environment has state. Nothing is deployed, nothing is billing."
    return 0
  fi

  # Running tasks are the one cost that is not fixed, so report them separately.
  echo "Fargate tasks currently running:"
  local found_tasks=0
  for env in dev staging prod; do
    local cluster
    cluster=$(terraform -chdir="${REPO_ROOT}/envs/${env}" output -raw cluster_name 2>/dev/null || true)
    [[ -z "$cluster" ]] && continue
    local count
    count=$(aws ecs list-tasks --cluster "$cluster" --query 'length(taskArns)' --output text 2>/dev/null || echo 0)
    printf '  %-22s %s\n' "$cluster" "$count"
    [[ "$count" != "0" ]] && found_tasks=1
  done
  [[ $found_tasks -eq 0 ]] && echo "  (none — compute is idle; the total above is standing infrastructure)"

  echo
  echo "Estimates cover fixed hourly charges only. Excluded: NAT and endpoint data"
  echo "processing, ALB LCUs, S3 and ECR storage, CloudWatch ingestion, Fargate."
  echo "Tear down with: make teardown ENV=<env>   (or scripts/teardown.sh --all)"
}

main "$@"
