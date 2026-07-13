# =============================================
# test_upload.ps1 - Upload CSV to trigger pipeline
# Run from PROJECT ROOT:  .\scripts\test_upload.ps1
# =============================================

$STACK      = "zerodha-portfolio-pipeline"
$REGION     = "ap-south-1"
$ACCOUNT_ID = aws sts get-caller-identity --query Account --output text
$BUCKET     = "$STACK-trades-$ACCOUNT_ID"
$TIMESTAMP  = Get-Date -Format "yyyyMMdd_HHmmss"
$S3_KEY     = "uploads/trades_$TIMESTAMP.csv"

Write-Host "======================================" -ForegroundColor Cyan
Write-Host " Uploading sample CSV -> triggers pipeline" -ForegroundColor Cyan
Write-Host " Bucket : $BUCKET"
Write-Host " S3 Key : $S3_KEY"
Write-Host "======================================" -ForegroundColor Cyan

aws s3 cp data/sample_trades.csv "s3://$BUCKET/$S3_KEY" --region $REGION

Write-Host ""
Write-Host "SUCCESS: Uploaded! Pipeline triggered." -ForegroundColor Green
Write-Host ""
Write-Host "Monitor Lambda logs (run in new terminal):"
Write-Host "  aws logs tail /aws/lambda/$STACK-trade-processor --follow --region $REGION"
Write-Host ""
Write-Host "Check for failures in DLQ:"
$DLQ_URL = aws sqs get-queue-url --queue-name "$STACK-trade-dlq" --region $REGION --query QueueUrl --output text
Write-Host "  aws sqs get-queue-attributes --queue-url $DLQ_URL --attribute-names ApproximateNumberOfMessages"
