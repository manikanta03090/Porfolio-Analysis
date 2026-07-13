#!/usr/bin/env bash
# ─────────────────────────────────────────────
# test_upload.sh  —  Upload CSV to trigger pipeline
# Run from PROJECT ROOT:  bash scripts/test_upload.sh
# ─────────────────────────────────────────────
set -euo pipefail

STACK="zerodha-portfolio-pipeline"
REGION="ap-south-1"
ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)
BUCKET="${STACK}-trades-${ACCOUNT_ID}"
TIMESTAMP=$(date +%Y%m%d_%H%M%S)
S3_KEY="uploads/trades_${TIMESTAMP}.csv"

echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo " Uploading sample CSV → triggers pipeline"
echo " Bucket : $BUCKET"
echo " S3 Key : $S3_KEY"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

aws s3 cp data/sample_trades.csv "s3://${BUCKET}/${S3_KEY}" --region "$REGION"

echo ""
echo "✅ Uploaded! Pipeline triggered."
echo ""
echo "Monitor Lambda logs:"
echo "  aws logs tail /aws/lambda/${STACK}-trade-processor --follow --region $REGION"
echo ""
echo "Check DLQ for failures:"
DLQ_URL=$(aws sqs get-queue-url --queue-name "${STACK}-trade-dlq" --region "$REGION" --query QueueUrl --output text)
echo "  aws sqs get-queue-attributes --queue-url $DLQ_URL --attribute-names ApproximateNumberOfMessages"
