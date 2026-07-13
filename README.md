# 📊 Zerodha Portfolio Pipeline

> AWS Data Engineering Portfolio Project  
> S3 → SNS → SQS → Lambda → RDS MySQL → SES Email  
> Deployed with AWS SAM

---

## Architecture

```
Upload CSV
    │
    ▼
┌─────────┐   event   ┌─────┐  fan-out  ┌─────┐  trigger  ┌──────────────────┐
│   S3    │──────────▶│ SNS │──────────▶│ SQS │──────────▶│     Lambda       │
│ Bucket  │           │Topic│           │Queue│           │  trade_processor  │
└─────────┘           └─────┘           └──┬──┘           └────────┬─────────┘
                                           │ DLQ                   │
                                           ▼               ┌───────┴────────┐
                                     Failed msgs           │   RDS MySQL    │
                                     (14 days)             │  ┌──────────┐  │
                                                           │  │  trades  │  │
                                                           │  ├──────────┤  │
                                                           │  │positions │  │
                                                           │  ├──────────┤  │
                                                           │  │pnl_summ  │  │
                                                           │  └──────────┘  │
                                                           └───────┬────────┘
                                                                   │
                                                                   ▼
                                                             ┌──────────┐
                                                             │  SES     │
                                                             │  Email   │
                                                             └──────────┘
```

**Dataset:** Zerodha Trade Book Export CSV  
**Schema auto-created:** Tables are created by Lambda on first run — no manual DB init needed.

---

## Project Structure

```
zerodha-portfolio-pipeline/
├── template.yaml                   ← SAM template (all AWS infrastructure)
├── samconfig.toml                  ← SAM deploy config  ⚠️ EDIT THIS FIRST
│
├── functions/
│   └── trade_processor/
│       ├── app.py                  ← Lambda: parse CSV → RDS → email
│       └── requirements.txt
│
├── layers/
│   └── dependencies/
│       └── requirements.txt        ← pymysql (auto-built by SAM)
│
├── data/
│   └── sample_trades.csv           ← Test CSV with 12 trades
│
└── scripts/
    ├── deploy.ps1   / deploy.sh    ← Build + deploy
    ├── test_upload.ps1 / .sh       ← Upload CSV to trigger pipeline
    └── cleanup.ps1  / cleanup.sh   ← Delete all resources after demo
```

---

## Prerequisites

| Tool | Install |
|------|---------|
| AWS CLI | https://aws.amazon.com/cli/ |
| AWS SAM CLI | Windows MSI ↓ or `pip install aws-sam-cli` |
| AWS credentials | `aws configure` |

**SAM CLI for Windows (MSI):**
```
https://github.com/aws/aws-sam-cli/releases/latest/download/AWS_SAM_CLI_64_PY3.msi
```

Verify installs:
```
aws --version
sam --version
aws sts get-caller-identity
```

---

## Step 1 — Edit samconfig.toml

Open `samconfig.toml` and update this line with your real values:

```toml
parameter_overrides = "Environment=dev DBPassword=YourSecurePass123! SenderEmail=you@gmail.com ReceiverEmail=you@gmail.com"
```

| Field | Description |
|-------|-------------|
| `DBPassword` | Any password, min 8 chars, no `@` or `/` |
| `SenderEmail` | Your email — must be verified in SES |
| `ReceiverEmail` | Where to receive notifications (can be same email) |

---

## Step 2 — Verify SES Email

Do this BEFORE deploying so email works on first test.

AWS will send a verification link to your inbox — click it.

**Windows (PowerShell):**
```powershell
aws ses verify-email-identity --email-address you@gmail.com --region ap-south-1
```

**Linux / Mac / Git Bash:**
```bash
aws ses verify-email-identity --email-address you@gmail.com --region ap-south-1
```

> If sender and receiver are the same email, one command is enough.  
> Check your inbox and click the "Amazon SES verification" link.

---

## Step 3 — Deploy

⚠️ **Always run from the PROJECT ROOT folder** (where `template.yaml` is), not from inside `scripts/`.

**Windows (PowerShell):**
```powershell
# From project root
.\scripts\deploy.ps1
```

**Linux / Mac / Git Bash:**
```bash
# From project root
bash scripts/deploy.sh
```

**Manual commands (if scripts don't work):**
```powershell
# Windows PowerShell
sam build
sam deploy
```
```bash
# Linux / Mac / Git Bash
sam build
sam deploy
```

Deploy takes **8–12 minutes** — most of that is RDS creation.

If deploy fails midway, created resources are cleaned up automatically:
- `samconfig.toml` uses `on_failure = "DELETE"` (CloudFormation deletes the partial stack)
- `deploy.ps1` / `deploy.sh` also remove leftover stacks stuck in `ROLLBACK_COMPLETE`

---

## Step 4 — Test the Pipeline

**Windows (PowerShell):**
```powershell
.\scripts\test_upload.ps1
```

**Linux / Mac / Git Bash:**
```bash
bash scripts/test_upload.sh
```

**Manual (any platform):**
```powershell
# Get your account ID
$ACCOUNT_ID = aws sts get-caller-identity --query Account --output text

# Upload CSV
aws s3 cp data/sample_trades.csv `
  s3://zerodha-portfolio-pipeline-trades-$ACCOUNT_ID/uploads/sample_trades.csv `
  --region ap-south-1
```

**What happens next (automatically):**
1. S3 notifies SNS
2. SNS pushes to SQS
3. Lambda triggers, creates DB tables on first run, processes trades
4. Email arrives in ~30 seconds

**Watch Lambda logs:**
```powershell
aws logs tail /aws/lambda/zerodha-portfolio-pipeline-trade-processor --follow --region ap-south-1
```

---

## Step 5 — Cleanup After Demo

⚠️ Run this to avoid ongoing charges. NAT Gateway costs ~$35/month.

**Windows (PowerShell):**
```powershell
.\scripts\cleanup.ps1
```

**Linux / Mac / Git Bash:**
```bash
bash scripts/cleanup.sh
```

**Manual cleanup:**
```powershell
# 1. Empty S3 (required before stack delete)
$ACCOUNT_ID = aws sts get-caller-identity --query Account --output text
aws s3 rm s3://zerodha-portfolio-pipeline-trades-$ACCOUNT_ID --recursive --region ap-south-1

# 2. Delete stack
sam delete --stack-name zerodha-portfolio-pipeline --region ap-south-1

# 3. Delete RDS snapshot (created automatically)
aws rds describe-db-snapshots `
  --query "DBSnapshots[?contains(DBSnapshotIdentifier,'zerodha')].DBSnapshotIdentifier" `
  --output text --region ap-south-1
# Copy the snapshot ID from above, then:
aws rds delete-db-snapshot --db-snapshot-identifier <snapshot-id> --region ap-south-1
```

---

## Fixes Applied in This Version

| Issue | Fix |
|-------|-----|
| `AWS::EarlyValidation::PropertyValidation` error | Fixed S3 `LifecycleConfiguration` — `Prefix` moved inside `Filter` block |
| RDS `AllocatedStorage` type mismatch | Changed from string `'20'` to integer `20` |
| Manual DB init required | Removed — Lambda auto-creates tables on first run |
| S3 suffix filter causing validation issues | Removed suffix filter, kept only `uploads/` prefix |
| `sam deploy` without `sam build` | Scripts now run `sam build` first automatically |
| SNS→SQS subscription race condition | Moved subscription to separate `AWS::SNS::Subscription` with `DependsOn: SQSPolicy` |
| NAT route created before NAT Gateway | Added `DependsOn: NatGateway` on `PrivateRoute` |
| Failed deploy leaving orphaned resources | `on_failure = DELETE` in samconfig + deploy script cleanup trap |
| RDS snapshot left on failed rollback | Changed `DeletionPolicy` to `Delete` (no orphan snapshots) |

---

## RDS Tables (auto-created on first Lambda run)

```
trades               — raw trade records, duplicate-safe (INSERT IGNORE)
portfolio_positions  — net qty + avg price per symbol (upserted each run)
pnl_summary          — one row per processed CSV file
```

---

## Estimated Cost

| Resource | Cost |
|----------|------|
| RDS db.t3.micro | ~$15/month |
| NAT Gateway | ~$35/month |
| Lambda, S3, SNS, SQS | ~$0 (free tier) |
| SES (< 1000 emails) | ~$0 |
| **Total** | **~$50/month** |

> 💡 Delete after demo — `cleanup.ps1` / `cleanup.sh` removes everything.

---

*Built by Mani (Manikanta Gunda) | [cloudwithmani.in](https://cloudwithmani.in)*
