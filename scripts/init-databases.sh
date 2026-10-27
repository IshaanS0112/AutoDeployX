#!/usr/bin/env bash
# One-time database bootstrap. Run once, after the first `terraform apply`.
set -euo pipefail

cd "$(dirname "$0")/.."
command -v psql >/dev/null || { echo "psql not found. brew install libpq (macOS) or apt install postgresql-client" >&2; exit 1; }

TF_OUT="$(terraform -chdir=terraform output -json)"
RDS_HOST="$(echo "$TF_OUT" | jq -r '.rds_endpoint.value')"
MASTER_SECRET="$(echo "$TF_OUT" | jq -r '.rds_master_secret_arn.value')"

echo "Reading master credentials from Secrets Manager (not from state, not from a file)"
MASTER_JSON="$(aws secretsmanager get-secret-value --secret-id "$MASTER_SECRET" --query SecretString --output text)"
MASTER_USER="$(echo "$MASTER_JSON" | jq -r .username)"
MASTER_PASS="$(echo "$MASTER_JSON" | jq -r .password)"

echo "Target: ${RDS_HOST}"
export PGPASSWORD="$MASTER_PASS"
export PGCONNECT_TIMEOUT=15

if ! psql -h "$RDS_HOST" -U "$MASTER_USER" -d postgres -c 'SELECT 1' >/dev/null 2>&1; then
  cat >&2 <<EOF
Cannot reach ${RDS_HOST}:5432.

Almost always one of:
  1. Your public IP changed. Check:  curl -s ifconfig.me
     Then update operator_cidr in terraform/terraform.tfvars and re-apply.
  2. The instance is still creating (first apply takes ~8 minutes).
  3. You are on a network that blocks outbound 5432.
EOF
  exit 1
fi

jq -c '.services[]' services/services.json | while read -r svc; do
  key=$(echo "$svc" | jq -r .key)
  db=$(echo "$svc" | jq -r .db_name)
  user=$(echo "$svc" | jq -r .db_user)

  pw_arn="$(echo "$TF_OUT" | jq -r --arg k "$key" '.db_password_secret_arns.value[$k]')"
  pw="$(aws secretsmanager get-secret-value --secret-id "$pw_arn" --query SecretString --output text)"

  echo
  echo "--- ${key}: database '${db}', role '${user}' ---"

  # Idempotent: safe to re-run after a teardown/rebuild.
  psql -h "$RDS_HOST" -U "$MASTER_USER" -d postgres -v ON_ERROR_STOP=1 <<SQL
DO \$\$
BEGIN
  IF NOT EXISTS (SELECT FROM pg_roles WHERE rolname = '${user}') THEN
    CREATE ROLE ${user} LOGIN PASSWORD '${pw}';
  ELSE
    ALTER ROLE ${user} WITH PASSWORD '${pw}';
  END IF;
END
\$\$;
SQL

  # CREATE DATABASE cannot run inside a transaction block, so it is issued
  # separately and its "already exists" error is tolerated.
  psql -h "$RDS_HOST" -U "$MASTER_USER" -d postgres -c \
    "CREATE DATABASE ${db} OWNER ${user};" 2>/dev/null \
    || echo "  database ${db} already exists"

  # Least privilege inside the database too. The app role owns the public schema of
  # its OWN database and has no rights in any other — so a SQL injection in FinSight
  # cannot read StrategySphere's.
  psql -h "$RDS_HOST" -U "$MASTER_USER" -d "$db" -v ON_ERROR_STOP=1 <<SQL
REVOKE ALL ON DATABASE ${db} FROM PUBLIC;
GRANT CONNECT ON DATABASE ${db} TO ${user};
GRANT ALL ON SCHEMA public TO ${user};
ALTER SCHEMA public OWNER TO ${user};
SQL

  echo "  ${db} ready"
done

unset PGPASSWORD
echo
echo "Databases initialised. The apps create their own tables on first start"
echo "(SQLAlchemy create_all), so nothing further is needed."
echo
echo "Next: push to main, or run ./scripts/seed-images.sh to bring the services"
echo "up immediately without waiting for a pipeline run."
