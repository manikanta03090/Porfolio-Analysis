# =============================================
# cleanup.ps1 - Delete all AWS resources after demo
# Run from PROJECT ROOT:  .\scripts\cleanup.ps1
# =============================================

$STACK      = "zerodha-portfolio-pipeline"
$REGION     = "ap-south-1"
$ACCOUNT_ID = aws sts get-caller-identity --query Account --output text
$BUCKET     = "$STACK-trades-$ACCOUNT_ID"

Write-Host "======================================" -ForegroundColor Red
Write-Host " Cleanup - Deleting all resources"       -ForegroundColor Red
Write-Host " Stack  : $STACK"
Write-Host " Region : $REGION"
Write-Host "======================================" -ForegroundColor Red
Write-Host ""

$confirm = Read-Host "Type YES to confirm deletion"
if ($confirm -ne "YES") {
    Write-Host "Cancelled." -ForegroundColor Yellow
    exit 0
}

# Step 1 - Empty S3 (including all versions and delete markers for versioned bucket)
Write-Host ""
Write-Host "> Step 1/3 - Emptying S3 bucket (including all versions and delete markers)..." -ForegroundColor Yellow

$bucketExists = $true
try {
    aws s3api head-bucket --bucket $BUCKET --region $REGION 2>$null
    if ($LASTEXITCODE -ne 0) { $bucketExists = $false }
} catch {
    $bucketExists = $false
}

if ($bucketExists) {
    # Delete all object versions
    $versionsQuery = 'Versions[].{Key:Key,VersionId:VersionId}'
    $versionsJson = aws s3api list-object-versions --bucket $BUCKET --region $REGION --query $versionsQuery --output json
    if ($versionsJson -and $versionsJson -ne "null") {
        $versions = $versionsJson | ConvertFrom-Json
        foreach ($v in $versions) {
            if ($v.Key -and $v.VersionId) {
                aws s3api delete-object --bucket $BUCKET --key $v.Key --version-id $v.VersionId --region $REGION > $null
            }
        }
    }

    # Delete all delete markers
    $markersQuery = 'DeleteMarkers[].{Key:Key,VersionId:VersionId}'
    $markersJson = aws s3api list-object-versions --bucket $BUCKET --region $REGION --query $markersQuery --output json
    if ($markersJson -and $markersJson -ne "null") {
        $markers = $markersJson | ConvertFrom-Json
        foreach ($m in $markers) {
            if ($m.Key -and $m.VersionId) {
                aws s3api delete-object --bucket $BUCKET --key $m.Key --version-id $m.VersionId --region $REGION > $null
            }
        }
    }
    Write-Host "   Bucket emptied."
} else {
    Write-Host "   Bucket does not exist. Skipping."
}

# Step 2 - Delete stack
Write-Host ""
Write-Host "> Step 2/3 - Deleting CloudFormation stack..." -ForegroundColor Yellow
Write-Host "   (RDS snapshot will be created - takes ~5 min)"
sam delete --stack-name $STACK --region $REGION --no-prompts
Write-Host "   Stack deleted."

# Step 3 - Delete RDS snapshot
Write-Host ""
Write-Host "> Step 3/3 - Deleting RDS snapshot..." -ForegroundColor Yellow
$snapshotQuery = "DBSnapshots[?contains(DBSnapshotIdentifier,'$STACK')].DBSnapshotIdentifier"
$SNAPSHOT_ID = aws rds describe-db-snapshots --region $REGION --query $snapshotQuery --output text

if ($SNAPSHOT_ID) {
    aws rds delete-db-snapshot --db-snapshot-identifier $SNAPSHOT_ID --region $REGION
    Write-Host "   Snapshot $SNAPSHOT_ID deleted."
} else {
    Write-Host "   No snapshot found (already deleted or not created)."
}

Write-Host ""
Write-Host "SUCCESS: Cleanup complete - zero ongoing charges." -ForegroundColor Green
Write-Host ""
Write-Host "Verify in AWS Console:"
Write-Host "  EC2  -> NAT Gateways  (should be empty)"
Write-Host "  RDS  -> Snapshots     (should be empty)"
Write-Host "  CloudFormation       (stack should be gone)"
