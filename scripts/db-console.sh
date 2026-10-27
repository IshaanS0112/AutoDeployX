#!/usr/bin/env bash
# A psql session against the deployed database, through ECS Exec.
set -euo pipefail

cd "$(dirname "$0")/.."

SERVICE_KEY="${1:?usage: ./scripts/db-console.sh <service-key> [psql args...]}"
shift || true
CLUSTER="${CLUSTER:-autodeployx-production}"
AWS_REGION="${AWS_REGION:-ap-south-1}"

command -v aws >/dev/null || { echo "aws CLI is required" >&2; exit 1; }
if ! command -v session-manager-plugin >/dev/null 2>&1; then
  cat >&2 <<'EOF'
session-manager-plugin is not installed. ECS Exec needs it.

  macOS: brew install --cask session-manager-plugin
  Other: https://docs.aws.amazon.com/systems-manager/latest/userguide/session-manager-working-with-install-plugin.html
EOF
  exit 1
fi

SERVICE_NAME="${CLUSTER}-${SERVICE_KEY}"

TASK_ARN="$(aws ecs list-tasks --cluster "$CLUSTER" --service-name "$SERVICE_NAME" \
  --desired-status RUNNING --query 'taskArns[0]' --output text 2>/dev/null)"

if [ -z "$TASK_ARN" ] || [ "$TASK_ARN" = "None" ]; then
  echo "ERROR: no RUNNING task for ${SERVICE_NAME}." >&2
  echo "       The stack may be destroyed, or the service may be mid-rollout." >&2
  exit 1
fi

echo "==> ${SERVICE_NAME} task ${TASK_ARN##*/}" >&2
echo "    Session is recorded by SSM against your IAM principal." >&2

# psql is not in the runtime image by design — it would be a package and a CVE
# surface for something used a handful of times a year.
if [ "$#" -gt 0 ]; then
  SQL="$*"
  CMD="python -c \"
import os, psycopg2, sys
url = os.environ['DATABASE_URL'].replace('postgresql+psycopg2://', 'postgresql://')
with psycopg2.connect(url) as c, c.cursor() as cur:
    cur.execute(sys.argv[1])
    if cur.description:
        print(' | '.join(d[0] for d in cur.description))
        for row in cur.fetchall():
            print(' | '.join('' if v is None else str(v) for v in row))
    else:
        print(f'{cur.rowcount} row(s) affected')
\" \"${SQL}\""
else
  echo "    No SQL given — opening a shell in the api container instead." >&2
  echo "    DATABASE_URL is already in the environment." >&2
  CMD="/bin/sh"
fi

exec aws ecs execute-command \
  --cluster "$CLUSTER" \
  --task "$TASK_ARN" \
  --container api \
  --interactive \
  --command "$CMD"
