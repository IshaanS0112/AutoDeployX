#!/usr/bin/env bash
# Take a manual RDS snapshot, list them, or rehearse a restore.
set -euo pipefail

cd "$(dirname "$0")/.."

ACTION="${1:-list}"
CLUSTER="${CLUSTER:-autodeployx-production}"
AWS_REGION="${AWS_REGION:-ap-south-1}"
DB_ID="${DB_ID:-${CLUSTER}-db}"

command -v aws >/dev/null || { echo "aws CLI is required" >&2; exit 1; }

case "$ACTION" in
  create)
    SNAP="${DB_ID}-manual-$(date -u +%Y%m%d-%H%M%S)"
    echo "==> Creating ${SNAP} from ${DB_ID}"
    aws rds create-db-snapshot \
      --db-instance-identifier "$DB_ID" \
      --db-snapshot-identifier "$SNAP" \
      --tags Key=Project,Value=autodeployx Key=Kind,Value=manual \
      --query 'DBSnapshot.[DBSnapshotIdentifier,Status]' --output text
    echo
    echo "Snapshots are billed for storage beyond the free allowance (which is"
    echo "the size of the instance). Delete it when the migration is proven:"
    echo "    aws rds delete-db-snapshot --db-snapshot-identifier ${SNAP}"
    echo
    echo "Waiting for it to complete (a few minutes)..."
    aws rds wait db-snapshot-available --db-snapshot-identifier "$SNAP"
    echo "Done. ${SNAP} is available."
    ;;

  list)
    echo "Manual snapshots:"
    aws rds describe-db-snapshots --db-instance-identifier "$DB_ID" \
      --snapshot-type manual \
      --query 'DBSnapshots[].[DBSnapshotIdentifier,SnapshotCreateTime,Status,AllocatedStorage]' \
      --output table 2>/dev/null || echo "  (none)"
    echo
    echo "Point-in-time recovery window (automated backups):"
    aws rds describe-db-instances --db-instance-identifier "$DB_ID" \
      --query 'DBInstances[0].[LatestRestorableTime,BackupRetentionPeriod]' \
      --output table 2>/dev/null || echo "  (instance not found)"
    echo
    echo "PITR restores to any second in that window. It is the right tool for"
    echo "'undo the last twenty minutes'; a manual snapshot is the right tool"
    echo "for 'keep this exact state past the retention period'."
    ;;

  restore-drill)
    SNAP="${2:-$(aws rds describe-db-snapshots --db-instance-identifier "$DB_ID" \
      --snapshot-type manual --query 'sort_by(DBSnapshots,&SnapshotCreateTime)[-1].DBSnapshotIdentifier' \
      --output text 2>/dev/null)}"
    [ -n "$SNAP" ] && [ "$SNAP" != "None" ] || { echo "No manual snapshot found. Run 'create' first." >&2; exit 1; }

    TARGET="${DB_ID}-drill-$(date -u +%H%M%S)"
    cat <<EOF

  RESTORE DRILL
  =============
  snapshot : ${SNAP}
  restoring to a NEW instance: ${TARGET}

  Production ${DB_ID} is NOT touched. This costs roughly \$0.018/hour while the
  drill instance exists, and the script prints the command to delete it.

  This takes 5-10 minutes.

EOF
    read -rp "Type 'drill' to proceed: " answer
    [ "$answer" = "drill" ] || { echo "Aborted."; exit 1; }

    aws rds restore-db-instance-from-db-snapshot \
      --db-instance-identifier "$TARGET" \
      --db-snapshot-identifier "$SNAP" \
      --db-instance-class db.t3.micro \
      --no-publicly-accessible \
      --tags Key=Project,Value=autodeployx Key=Kind,Value=restore-drill \
      --query 'DBInstance.[DBInstanceIdentifier,DBInstanceStatus]' --output text

    echo "Waiting for ${TARGET}..."
    aws rds wait db-instance-available --db-instance-identifier "$TARGET"

    ENDPOINT="$(aws rds describe-db-instances --db-instance-identifier "$TARGET" \
      --query 'DBInstances[0].Endpoint.Address' --output text)"
    cat <<EOF

  RESTORED. The snapshot is real and restorable.

  endpoint: ${ENDPOINT}

  Verify the data is what you expect before trusting the drill — a restore that
  completes and contains an empty schema has told you nothing:

      CLUSTER=${CLUSTER} ./scripts/db-console.sh <service> \\
        "select table_name from information_schema.tables where table_schema='public'"

  Then DELETE IT. It bills by the hour:

      ./scripts/db-snapshot.sh cleanup

EOF
    ;;

  cleanup)
    echo "Restore-drill instances:"
    DRILLS="$(aws rds describe-db-instances \
      --query "DBInstances[?starts_with(DBInstanceIdentifier, '${DB_ID}-drill')].DBInstanceIdentifier" \
      --output text 2>/dev/null || true)"
    if [ -z "$DRILLS" ]; then
      echo "  (none — nothing is billing)"
      exit 0
    fi
    for d in $DRILLS; do echo "  $d"; done
    echo
    read -rp "Delete all of these? Type 'delete': " answer
    [ "$answer" = "delete" ] || { echo "Aborted."; exit 1; }
    for d in $DRILLS; do
      echo "deleting $d"
      aws rds delete-db-instance --db-instance-identifier "$d" \
        --skip-final-snapshot --delete-automated-backups >/dev/null
    done
    echo "Deletion started. Confirm with: aws rds describe-db-instances --query 'DBInstances[].DBInstanceIdentifier'"
    ;;

  *)
    sed -n '2,22p' "$0"
    exit 1
    ;;
esac
