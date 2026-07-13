#!/usr/bin/env bash
# ─────────────────────────────────────────────
# cleanup.sh  —  Delete all AWS resources after demo
# Run from PROJECT ROOT:  bash scripts/cleanup.sh
# ─────────────────────────────────────────────
set -euo pipefail

STACK="zerodha-portfolio-pipeline"
REGION="ap-south-1"
ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)
BUCKET="${STACK}-trades-${ACCOUNT_ID}"

echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo " Cleanup — Deleting all resources"
echo " Stack  : $STACK"
echo " Region : $REGION"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo ""
read -p "Type YES to confirm: " CONFIRM
[[ "$CONFIRM" != "YES" ]] && echo "Cancelled." && exit 0

# Step 1 — Empty S3 (including all versions and delete markers for versioned bucket)
echo ""
echo "▶ Step 1/3 — Emptying S3 bucket (including all versions and delete markers)..."
if aws s3api head-bucket --bucket "${BUCKET}" --region "${REGION}" 2>/dev/null; then
  # Delete all object versions
  aws s3api list-object-versions --bucket "${BUCKET}" --region "${REGION}" --output text --query 'Versions[].[Key,VersionId]' | while read -r key versionId; do
    if [ -n "$key" ] && [ -n "$versionId" ] && [ "$key" != "None" ] && [ "$versionId" != "None" ]; then
      aws s3api delete-object --bucket "${BUCKET}" --key "$key" --version-id "$versionId" --region "${REGION}" >/dev/null
    fi
  done
  # Delete all delete markers
  aws s3api list-object-versions --bucket "${BUCKET}" --region "${REGION}" --output text --query 'DeleteMarkers[].[Key,VersionId]' | while read -r key versionId; do
    if [ -n "$key" ] && [ -n "$versionId" ] && [ "$key" != "None" ] && [ "$versionId" != "None" ]; then
      aws s3api delete-object --bucket "${BUCKET}" --key "$key" --version-id "$versionId" --region "${REGION}" >/dev/null
    fi
  done
  echo "   Bucket emptied."
else
  echo "   Bucket does not exist. Skipping."
fi

# Step 2 — Delete stack
echo ""
echo "▶ Step 2/3 — Deleting CloudFormation stack..."
echo "   (RDS snapshot created automatically — takes ~5 min)"
sam delete --stack-name "$STACK" --region "$REGION" --no-prompts
echo "   Stack deleted."

# Step 3 — Delete RDS snapshot
echo ""
echo "▶ Step 3/3 — Deleting RDS snapshot..."
SNAPSHOT_ID=$(aws rds describe-db-snapshots \
  --region "$REGION" \
  --query "DBSnapshots[?contains(DBSnapshotIdentifier,'${STACK}')].DBSnapshotIdentifier" \
  --output text)

if [[ -n "$SNAPSHOT_ID" ]]; then
  aws rds delete-db-snapshot --db-snapshot-identifier "$SNAPSHOT_ID" --region "$REGION"
  echo "   Snapshot $SNAPSHOT_ID deleted."
else
  echo "   No snapshot found."
fi

echo ""
echo "✅ Cleanup complete — zero ongoing charges."
echo ""
echo "Verify in AWS Console:"
echo "  EC2  → NAT Gateways  (should be empty)"
echo "  RDS  → Snapshots     (should be empty)"
echo "  CloudFormation       (stack should be gone)"
