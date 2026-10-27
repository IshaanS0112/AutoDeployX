#!/usr/bin/env bash
# Price the stack that a tfvars file describes, before applying it.
set -euo pipefail

cd "$(dirname "$0")/.."

ENVIRONMENT="${1:-production}"
case "${2:-}" in
  --hourly) UNIT="hour" ;;
  *)        UNIT="month" ;;
esac

VAR_FILE="terraform/envs/${ENVIRONMENT}.tfvars"
if [ ! -f "$VAR_FILE" ]; then
  VAR_FILE="terraform/envs/${ENVIRONMENT}.tfvars.example"
  echo "note: no ${ENVIRONMENT}.tfvars, pricing the committed example instead" >&2
fi
[ -f "$VAR_FILE" ] || { echo "No tfvars for '${ENVIRONMENT}'." >&2; exit 1; }

# --- Prices, ap-south-1 on-demand list, checked 2026-09-20 -----------------
# Monthly figures assume 730 hours.
PRICE_ALB_HOURS=16.20            # $0.0225/hr
PRICE_FARGATE_SPOT_TASK=7.30     # 0.5 vCPU + 1GB on Spot, ~$0.010/hr
PRICE_FARGATE_ONDEMAND_TASK=24.50
PRICE_RDS_T3_MICRO=13.10         # $0.018/hr, single-AZ
PRICE_RDS_STORAGE_20GB=2.30
PRICE_NAT_GATEWAY=32.85          # $0.045/hr, per gateway, before data
PRICE_NAT_INSTANCE=3.07          # t4g.nano on-demand, ~$0.0042/hr
PRICE_VPC_INTERFACE_ENDPOINT=7.20  # per endpoint per AZ
PRICE_WAF_ACL=5.00
PRICE_WAF_RULE_GROUP=1.00
PRICE_SECRETS_MANAGER=0.40       # per secret
PRICE_ALB_LOGS_S3=0.50
PRICE_FLOW_LOGS=0.50
PRICE_PERF_INSIGHTS=3.00
PRICE_ENHANCED_MONITORING=3.00
PRICE_CONTAINER_INSIGHTS=5.50
PRICE_EKS_CONTROL_PLANE=73.00    # not built; shown for comparison only

# tfvars is HCL, but the subset used here is `key = value` — good enough, and
# it keeps this script dependency-free.
tfvar() {
  local key="$1" default="$2" v
  v="$(grep -E "^[[:space:]]*${key}[[:space:]]*=" "$VAR_FILE" 2>/dev/null \
        | head -1 | sed -E 's/^[^=]*=[[:space:]]*//' | tr -d '"' | awk '{print $1}')"
  [ -n "$v" ] && printf '%s' "$v" || printf '%s' "$default"
}

SERVICES="$(jq -r '.services | length' services/services.json)"
TASKS="$(jq -r '[.services[].desired_count] | add' services/services.json)"
SECRETS=$(( SERVICES * 2 + 1 ))

spot=$(tfvar use_fargate_spot true)
multi_az=$(tfvar rds_multi_az false)
priv=$(tfvar enable_private_subnets false)
nat=$(tfvar enable_nat_gateway false)
nat_mode=$(tfvar nat_mode gateway)
single_nat=$(tfvar single_nat_gateway true)
endpoints=$(tfvar enable_vpc_endpoints false)
flow=$(tfvar enable_flow_logs false)
waf=$(tfvar enable_waf false)
alb_logs=$(tfvar enable_alb_access_logs false)
insights=$(tfvar enable_container_insights false)
perf=$(tfvar rds_performance_insights false)
mon=$(tfvar rds_enhanced_monitoring_interval 0)

total=0
rows=()
add() { # name, amount, note
  rows+=("$(printf '%-34s %10s   %s' "$1" "$(printf '$%.2f' "$2")" "$3")")
  total="$(awk -v t="$total" -v a="$2" 'BEGIN{printf "%.2f", t+a}')"
}

add "Application Load Balancer"  "$PRICE_ALB_HOURS"        "always on; the price of a stable public URL"
if [ "$spot" = "true" ]; then
  add "Fargate Spot × ${TASKS}"  "$(awk -v p="$PRICE_FARGATE_SPOT_TASK" -v n="$TASKS" 'BEGIN{printf "%.2f", p*n}')" "~70% off; reclaimable with 2 minutes' notice"
else
  add "Fargate on-demand × ${TASKS}" "$(awk -v p="$PRICE_FARGATE_ONDEMAND_TASK" -v n="$TASKS" 'BEGIN{printf "%.2f", p*n}')" "no reclaim risk, +\$17/task/month"
fi
if [ "$multi_az" = "true" ]; then
  add "RDS db.t3.micro (Multi-AZ)" "$(awk -v p="$PRICE_RDS_T3_MICRO" 'BEGIN{printf "%.2f", p*2}')" "standby is NOT free-tier eligible"
else
  add "RDS db.t3.micro"            "$PRICE_RDS_T3_MICRO"   "free tier covers 750 hrs for 12 months"
fi
add "RDS storage, 20GB"           "$PRICE_RDS_STORAGE_20GB" "free tier covers 20GB"
add "Secrets Manager × ${SECRETS}" "$(awk -v p="$PRICE_SECRETS_MANAGER" -v n="$SECRETS" 'BEGIN{printf "%.2f", p*n}')" "\$0.40 per secret per month"

optional_total=0
opt() { add "$1" "$2" "$3"; optional_total="$(awk -v t="$optional_total" -v a="$2" 'BEGIN{printf "%.2f", t+a}')"; }

if [ "$nat" = "true" ] && [ "$priv" = "true" ]; then
  if [ "$nat_mode" = "instance" ]; then
    opt "NAT instance (t4g.nano)" "$PRICE_NAT_INSTANCE" "OPT-IN · 10x cheaper, single point of failure"
  else
    n=2; [ "$single_nat" = "true" ] && n=1
    opt "NAT gateway × ${n}" "$(awk -v p="$PRICE_NAT_GATEWAY" -v n="$n" 'BEGIN{printf "%.2f", p*n}')" "OPT-IN · plus \$0.045/GB processed"
  fi
fi
if [ "$endpoints" = "true" ] && [ "$priv" = "true" ]; then
  opt "VPC interface endpoints × 10" "$(awk -v p="$PRICE_VPC_INTERFACE_ENDPOINT" 'BEGIN{printf "%.2f", p*10}')" "OPT-IN · 5 services × 2 AZs"
fi
[ "$waf" = "true" ] && opt "WAFv2 web ACL + 3 rules" "$(awk -v a="$PRICE_WAF_ACL" -v r="$PRICE_WAF_RULE_GROUP" 'BEGIN{printf "%.2f", a + r*3}')" "OPT-IN · plus \$0.60/million requests"
[ "$alb_logs" = "true" ] && opt "ALB access logs to S3" "$PRICE_ALB_LOGS_S3" "OPT-IN · plus PUT requests"
[ "$flow" = "true" ] && opt "VPC flow logs" "$PRICE_FLOW_LOGS" "OPT-IN · scales with traffic, not time"
[ "$insights" = "true" ] && opt "Container Insights" "$PRICE_CONTAINER_INSIGHTS" "OPT-IN · custom metrics, not free-tier"
[ "$perf" = "true" ] && opt "RDS Performance Insights" "$PRICE_PERF_INSIGHTS" "OPT-IN · free at 7-day retention on some classes"
[ "$mon" != "0" ] && opt "RDS enhanced monitoring (${mon}s)" "$PRICE_ENHANCED_MONITORING" "OPT-IN · per instance per minute"

echo
echo "AutoDeployX — estimated cost"
echo "  environment   ${ENVIRONMENT}"
echo "  tfvars        ${VAR_FILE}"
echo "  services      ${SERVICES} (${TASKS} task(s))"
echo
printf '  %-34s %10s   %s\n' "LINE" "PER MONTH" "NOTE"
printf '  %s\n' "$(printf '%.0s-' {1..96})"
for r in "${rows[@]}"; do printf '  %s\n' "$r"; done
printf '  %s\n' "$(printf '%.0s-' {1..96})"

# Free-tier credit, first 12 months from ACCOUNT CREATION (not first use).
# Shown as a separate line rather than folded into the total, because it
# expires and the total does not.
free_credit=0
if [ "$multi_az" = "true" ]; then
  # The free tier covers 750 single-AZ instance-hours. A Multi-AZ pair uses
  # them twice as fast, so it covers one of the two instances.
  free_credit="$(awk -v r="$PRICE_RDS_T3_MICRO" -v s="$PRICE_RDS_STORAGE_20GB" 'BEGIN{printf "%.2f", r+s}')"
else
  free_credit="$(awk -v r="$PRICE_RDS_T3_MICRO" -v s="$PRICE_RDS_STORAGE_20GB" 'BEGIN{printf "%.2f", r+s}')"
fi
after_credit="$(awk -v t="$total" -v c="$free_credit" 'BEGIN{printf "%.2f", t-c}')"

if [ "$UNIT" = "hour" ]; then
  printf '  %-34s %10s\n' "TOTAL" "$(awk -v t="$total" 'BEGIN{printf "$%.4f/hr", t/730}')"
else
  printf '  %-34s %10s\n' "TOTAL" "$(printf '$%.2f/month' "$total")"
fi
printf '  %-34s %10s\n' "of which opt-in" "$(printf '$%.2f' "$optional_total")"
printf '  %-34s %10s   %s\n' "less free-tier credit" "$(printf -- '-$%.2f' "$free_credit")" "RDS instance + storage, first 12 months"
if awk -v o="$optional_total" 'BEGIN{exit !(o == 0)}'; then
  credit_note="this is the figure in docs/cost-breakdown.md"
else
  credit_note="free tier does not discount any opt-in line above"
fi
printf '  %-34s %10s   %s\n' "INSIDE FREE TIER" "$(printf '$%.2f/month' "$after_credit")" "$credit_note"
printf '  %-34s %10s\n' "3-hour demo, then destroyed" "$(awk -v t="$after_credit" 'BEGIN{printf "$%.2f", t/730*3}')"

echo
if awk -v o="$optional_total" 'BEGIN{exit !(o > 0)}'; then
  baseline="$(awk -v t="$total" -v o="$optional_total" 'BEGIN{printf "%.2f", t-o}')"
  mult="$(awk -v t="$total" -v b="$baseline" 'BEGIN{ if (b>0) printf "%.1f", t/b; else print "n/a" }')"
  echo "  This configuration is ${mult}x the default stack (\$${baseline}/month)."
  echo "  Every opt-in line above is one variable in ${VAR_FILE}."
else
  echo "  Default configuration: nothing opt-in is enabled."
fi

if [ "$nat" = "true" ] && [ "$endpoints" = "true" ] && [ "$priv" = "true" ]; then
  echo
  echo "  WARNING: NAT gateway AND VPC endpoints are both on. They solve the same"
  echo "  problem — giving private-subnet tasks a route to AWS services — and you"
  echo "  are paying for both. Pick one: NAT is simpler and cheaper below roughly"
  echo "  600GB/month of egress; endpoints win above that and keep traffic off the"
  echo "  public internet entirely."
fi

echo
echo "  Not built, for comparison:"
printf '    %-32s %s\n' "EKS control plane" "$(printf '$%.2f/month' "$PRICE_EKS_CONTROL_PLANE") — before a single node (ADR 0009)"
echo
echo "  Estimate only. ap-south-1 on-demand list prices as of 2026-09-20. Data"
echo "  transfer and per-request charges are NOT modelled, and both scale with"
echo "  traffic — a busy NAT gateway or WAF costs materially more than its line"
echo "  above. Free-tier credit is shown separately because it expires 12 months"
echo "  after ACCOUNT creation, not after first use."
