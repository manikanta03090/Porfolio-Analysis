# deploy.ps1 - Windows PowerShell Deploy Script
# Run from PROJECT ROOT:  .\scripts\deploy.ps1

$STACK  = "zerodha-portfolio-pipeline"
$REGION = "ap-south-1"

function Cleanup-FailedStack {
    try {
        $status = aws cloudformation describe-stacks `
            --stack-name $STACK `
            --region $REGION `
            --query "Stacks[0].StackStatus" `
            --output text 2>$null
    } catch {
        $status = "NONE"
    }

    switch -Regex ($status) {
        "ROLLBACK_COMPLETE|CREATE_FAILED|ROLLBACK_FAILED|DELETE_FAILED" {
            Write-Host ""
            Write-Host "> Deploy failed - deleting partial stack (status: $status)..." -ForegroundColor Yellow
            aws cloudformation delete-stack --stack-name $STACK --region $REGION
            aws cloudformation wait stack-delete-complete --stack-name $STACK --region $REGION
            Write-Host "   Partial resources removed."
        }
        "DELETE_IN_PROGRESS" {
            Write-Host ""
            Write-Host "> Stack deletion already in progress - waiting..." -ForegroundColor Yellow
            aws cloudformation wait stack-delete-complete --stack-name $STACK --region $REGION
        }
        { $_ -eq "NONE" -or $_ -match "DELETE_COMPLETE" } {
            Write-Host ""
            Write-Host "> Deploy failed - no stack left to clean up." -ForegroundColor Yellow
        }
        default {
            Write-Host ""
            Write-Host "> Deploy failed - stack status: $status" -ForegroundColor Yellow
            Write-Host '   If resources remain, run: .\scripts\cleanup.ps1'
        }
    }
}

Write-Host "======================================" -ForegroundColor Cyan
Write-Host " Zerodha Portfolio Pipeline - Deploy"    -ForegroundColor Cyan
Write-Host "======================================" -ForegroundColor Cyan

if (-not (Get-Command sam -ErrorAction SilentlyContinue)) {
    Write-Host "ERROR: SAM CLI not found." -ForegroundColor Red
    Write-Host "   Download MSI: https://github.com/aws/aws-sam-cli/releases/latest/download/AWS_SAM_CLI_64_PY3.msi"
    exit 1
}
if (-not (Get-Command aws -ErrorAction SilentlyContinue)) {
    Write-Host "ERROR: AWS CLI not found." -ForegroundColor Red
    Write-Host "   Download: https://aws.amazon.com/cli/"
    exit 1
}

Write-Host ""
Write-Host "> Step 1/2 - sam build (installs pymysql into layer)" -ForegroundColor Yellow
sam build
if ($LASTEXITCODE -ne 0) { Write-Host "ERROR: Build failed" -ForegroundColor Red; exit 1 }

Write-Host ""
Write-Host "> Step 2/2 - sam deploy" -ForegroundColor Yellow
sam deploy
if ($LASTEXITCODE -ne 0) {
    Write-Host "ERROR: Deploy failed" -ForegroundColor Red
    Cleanup-FailedStack
    exit 1
}

Write-Host ""
Write-Host "> Stack Outputs:" -ForegroundColor Yellow
aws cloudformation describe-stacks `
    --stack-name $STACK `
    --region $REGION `
    --query "Stacks[0].Outputs[*].[OutputKey,OutputValue]" `
    --output table

Write-Host ""
Write-Host "SUCCESS: Deploy complete!" -ForegroundColor Green
Write-Host ""
Write-Host "Next steps:"
Write-Host '  1. Verify SES emails (check your inbox for AWS verification email)'
Write-Host '  2. Run: .\scripts\test_upload.ps1'
