#!/usr/bin/env bash
# ─────────────────────────────────────────────
# deploy.sh  —  Linux / Mac / Git Bash Deploy
# Run from PROJECT ROOT:  bash scripts/deploy.sh
# ─────────────────────────────────────────────
set -euo pipefail

STACK="zerodha-portfolio-pipeline"
REGION="ap-south-1"

cleanup_failed_stack() {
  local status
  status=$(aws cloudformation describe-stacks \
    --stack-name "$STACK" \
    --region "$REGION" \
    --query "Stacks[0].StackStatus" \
    --output text 2>/dev/null || echo "NONE")

  case "$status" in
    ROLLBACK_COMPLETE|CREATE_FAILED|ROLLBACK_FAILED|DELETE_FAILED)
      echo ""
      echo "▶ Deploy failed — deleting partial stack (status: $status)..."
      aws cloudformation delete-stack --stack-name "$STACK" --region "$REGION"
      aws cloudformation wait stack-delete-complete --stack-name "$STACK" --region "$REGION" || true
      echo "   Partial resources removed."
      ;;
    DELETE_IN_PROGRESS)
      echo ""
      echo "▶ Stack deletion already in progress — waiting..."
      aws cloudformation wait stack-delete-complete --stack-name "$STACK" --region "$REGION" || true
      ;;
    NONE|*DELETE_COMPLETE*)
      echo ""
      echo "▶ Deploy failed — no stack left to clean up."
      ;;
    *)
      echo ""
      echo "▶ Deploy failed — stack status: $status"
      echo "   If resources remain, run: bash scripts/cleanup.sh"
      ;;
  esac
}

echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo " Zerodha Portfolio Pipeline — Deploy"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

# Pre-flight checks
command -v sam >/dev/null 2>&1 || {
  echo "❌ SAM CLI not found."
  echo "   Linux/Mac: pip install aws-sam-cli"
  echo "   Windows  : download AWS_SAM_CLI_64_PY3.msi from GitHub releases"
  exit 1
}
command -v aws >/dev/null 2>&1 || {
  echo "❌ AWS CLI not found. https://aws.amazon.com/cli/"
  exit 1
}

echo ""
echo "▶ Step 1/2 — sam build (installs pymysql into layer)"
sam build

echo ""
echo "▶ Step 2/2 — sam deploy"
if ! sam deploy; then
  echo "❌ Deploy failed"
  cleanup_failed_stack
  exit 1
fi

echo ""
echo "▶ Stack Outputs:"
aws cloudformation describe-stacks \
  --stack-name "$STACK" \
  --region "$REGION" \
  --query "Stacks[0].Outputs[*].[OutputKey,OutputValue]" \
  --output table

echo ""
echo "✅ Deploy complete!"
echo ""
echo "Next steps:"
echo "  1. Verify SES emails (check inbox for AWS verification email)"
echo "  2. Run: bash scripts/test_upload.sh"
