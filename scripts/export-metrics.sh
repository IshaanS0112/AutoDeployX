#!/usr/bin/env bash
# Export this stack's CloudWatch metrics as NDJSON — one JSON object per datapoint,
# on stdout.
set -euo pipefail

cd "$(dirname "$0")/.."

CLUSTER="${CLUSTER:-autodeployx-production}"
AWS_REGION="${AWS_REGION:-ap-south-1}"
SINCE="1h"
PERIOD=300
WEBHOOK=""

while [ $# -gt 0 ]; do
  case "$1" in
    --since)   SINCE="$2"; shift 2 ;;
    --period)  PERIOD="$2"; shift 2 ;;
    --webhook) WEBHOOK="$2"; shift 2 ;;
    --cluster) CLUSTER="$2"; shift 2 ;;
    -h|--help) sed -n '2,30p' "$0"; exit 0 ;;
    *) echo "Unknown argument: $1" >&2; exit 1 ;;
  esac
done

command -v aws >/dev/null || { echo "aws CLI is required" >&2; exit 1; }
command -v jq  >/dev/null || { echo "jq is required" >&2; exit 1; }

# --since accepts 30m / 6h / 2d.
seconds_ago() {
  local v="${1%[mhd]}" unit="${1: -1}"
  case "$unit" in
    m) echo $((v * 60)) ;;
    h) echo $((v * 3600)) ;;
    d) echo $((v * 86400)) ;;
    *) echo "Bad --since '${1}'. Use e.g. 30m, 6h, 2d." >&2; exit 1 ;;
  esac
}

WINDOW="$(seconds_ago "$SINCE")"
# BSD date (macOS) and GNU date disagree about relative dates, and this script
# is written on one and runs in CI on the other.
if date -u -v-1H >/dev/null 2>&1; then
  START="$(date -u -v-"${WINDOW}"S +%Y-%m-%dT%H:%M:%SZ)"
else
  START="$(date -u -d "@$(($(date +%s) - WINDOW))" +%Y-%m-%dT%H:%M:%SZ)"
fi
END="$(date -u +%Y-%m-%dT%H:%M:%SZ)"

echo "exporting ${START} -> ${END} at ${PERIOD}s, cluster=${CLUSTER}" >&2

ALB_SUFFIX="$(aws elbv2 describe-load-balancers --region "$AWS_REGION" \
  --names "${CLUSTER}-alb" \
  --query 'LoadBalancers[0].LoadBalancerArn' --output text 2>/dev/null \
  | sed -E 's#.*(app/[^/]+/[^/]+)$#\1#')" || ALB_SUFFIX=""

if [ -z "$ALB_SUFFIX" ] || [ "$ALB_SUFFIX" = "None" ]; then
  echo "ERROR: no load balancer named ${CLUSTER}-alb in ${AWS_REGION}." >&2
  echo "       Is the stack up? Try: make outputs" >&2
  exit 1
fi

# The same free ALB/RDS metrics every alarm in this project uses. Nothing here
# is a custom metric, so exporting costs a GetMetricData call and no ingestion.
QUERIES="$(jq -n --arg alb "$ALB_SUFFIX" --arg cluster "$CLUSTER" --argjson period "$PERIOD" '
  [
    { Id: "requests",     Label: "alb.request_count",
      MetricStat: { Metric: { Namespace: "AWS/ApplicationELB", MetricName: "RequestCount",
                              Dimensions: [{ Name: "LoadBalancer", Value: $alb }] },
                    Period: $period, Stat: "Sum" } },
    { Id: "errors_5xx",   Label: "alb.target_5xx",
      MetricStat: { Metric: { Namespace: "AWS/ApplicationELB", MetricName: "HTTPCode_Target_5XX_Count",
                              Dimensions: [{ Name: "LoadBalancer", Value: $alb }] },
                    Period: $period, Stat: "Sum" } },
    { Id: "elb_5xx",      Label: "alb.elb_5xx",
      MetricStat: { Metric: { Namespace: "AWS/ApplicationELB", MetricName: "HTTPCode_ELB_5XX_Count",
                              Dimensions: [{ Name: "LoadBalancer", Value: $alb }] },
                    Period: $period, Stat: "Sum" } },
    { Id: "latency_p95",  Label: "alb.latency_p95",
      MetricStat: { Metric: { Namespace: "AWS/ApplicationELB", MetricName: "TargetResponseTime",
                              Dimensions: [{ Name: "LoadBalancer", Value: $alb }] },
                    Period: $period, Stat: "p95" } },
    { Id: "latency_p50",  Label: "alb.latency_p50",
      MetricStat: { Metric: { Namespace: "AWS/ApplicationELB", MetricName: "TargetResponseTime",
                              Dimensions: [{ Name: "LoadBalancer", Value: $alb }] },
                    Period: $period, Stat: "p50" } },
    { Id: "unhealthy",    Label: "alb.unhealthy_hosts",
      MetricStat: { Metric: { Namespace: "AWS/ApplicationELB", MetricName: "UnHealthyHostCount",
                              Dimensions: [{ Name: "LoadBalancer", Value: $alb }] },
                    Period: $period, Stat: "Maximum" } },
    { Id: "rds_cpu",      Label: "rds.cpu_percent",
      MetricStat: { Metric: { Namespace: "AWS/RDS", MetricName: "CPUUtilization",
                              Dimensions: [{ Name: "DBInstanceIdentifier", Value: ($cluster + "-db") }] },
                    Period: $period, Stat: "Average" } },
    { Id: "rds_conns",    Label: "rds.connections",
      MetricStat: { Metric: { Namespace: "AWS/RDS", MetricName: "DatabaseConnections",
                              Dimensions: [{ Name: "DBInstanceIdentifier", Value: ($cluster + "-db") }] },
                    Period: $period, Stat: "Average" } }
  ]')"

RAW="$(aws cloudwatch get-metric-data \
  --region "$AWS_REGION" \
  --start-time "$START" --end-time "$END" \
  --scan-by TimestampAscending \
  --metric-data-queries "$QUERIES" \
  --output json)"

# One object per datapoint. Flat on purpose: a consumer should not have to
# understand CloudWatch's result shape to read a number off it.
NDJSON="$(echo "$RAW" | jq -c --arg cluster "$CLUSTER" --arg region "$AWS_REGION" '
  .MetricDataResults[]
  | .Label as $label
  | [.Timestamps, .Values] | transpose[]
  | { cluster: $cluster, region: $region, metric: $label, timestamp: .[0], value: .[1] }
')"

if [ -z "$NDJSON" ]; then
  echo "No datapoints in the window. An idle stack publishes nothing — that is not an error." >&2
  exit 0
fi

COUNT="$(printf '%s\n' "$NDJSON" | wc -l | tr -d ' ')"
echo "${COUNT} datapoints" >&2

if [ -n "$WEBHOOK" ]; then
  # Posted as a JSON array rather than raw NDJSON: most receivers want one
  # request with a body they can parse, not a stream they have to frame.
  printf '%s\n' "$NDJSON" | jq -s '{ source: "autodeployx", datapoints: . }' \
    | curl -fsS -X POST -H 'Content-Type: application/json' --data @- "$WEBHOOK" >/dev/null
  echo "posted ${COUNT} datapoints to ${WEBHOOK%%\?*}" >&2
else
  printf '%s\n' "$NDJSON"
fi
