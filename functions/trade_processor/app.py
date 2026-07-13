"""
Zerodha Portfolio Pipeline — Lambda Trade Processor
────────────────────────────────────────────────────
Flow  : SQS ← SNS ← S3 (CSV upload)
Tables: trades | portfolio_positions | pnl_summary
Note  : Schema is created automatically on first run (ensure_schema)
        No manual DB init step needed.
"""

import boto3
import json
import csv
import io
import os
import logging
from datetime import datetime, timezone
from decimal import Decimal, InvalidOperation

import pymysql
import pymysql.cursors

logger = logging.getLogger()
logger.setLevel(logging.INFO)

# ─────────────────────────────────────────────
# Reuse DB connection across warm Lambda invocations
# ─────────────────────────────────────────────
_db_conn = None

def get_db_connection():
    global _db_conn
    try:
        if _db_conn and _db_conn.open:
            _db_conn.ping(reconnect=True)
            return _db_conn
    except Exception:
        pass

    _db_conn = pymysql.connect(
        host=os.environ["DB_HOST"],
        user=os.environ["DB_USER"],
        password=os.environ["DB_PASSWORD"],
        database=os.environ["DB_NAME"],
        charset="utf8mb4",
        cursorclass=pymysql.cursors.DictCursor,
        connect_timeout=10,
        autocommit=False,
    )
    logger.info("New DB connection established")
    return _db_conn


# ─────────────────────────────────────────────
# Schema Init — runs on cold start, no-op after first time
# ─────────────────────────────────────────────
_schema_initialized = False

def ensure_schema(conn):
    """
    Creates all 3 tables if they don't exist.
    Safe to call every time — IF NOT EXISTS makes it idempotent.
    """
    global _schema_initialized
    if _schema_initialized:
        return

    statements = [
        """
        CREATE TABLE IF NOT EXISTS trades (
            id          INT AUTO_INCREMENT PRIMARY KEY,
            trade_date  DATE               NOT NULL,
            symbol      VARCHAR(50)        NOT NULL,
            trade_type  ENUM('BUY','SELL') NOT NULL,
            quantity    INT                NOT NULL,
            price       DECIMAL(12,4)      NOT NULL,
            amount      DECIMAL(16,4)      NOT NULL,
            exchange    VARCHAR(10)        NOT NULL,
            source_file VARCHAR(512),
            loaded_at   TIMESTAMP          DEFAULT CURRENT_TIMESTAMP,
            UNIQUE KEY uq_trade (trade_date, symbol, trade_type, quantity, price, source_file),
            INDEX idx_symbol     (symbol),
            INDEX idx_trade_date (trade_date)
        ) ENGINE=InnoDB
        """,
        """
        CREATE TABLE IF NOT EXISTS portfolio_positions (
            id             INT AUTO_INCREMENT PRIMARY KEY,
            symbol         VARCHAR(50)   NOT NULL UNIQUE,
            net_qty        INT           DEFAULT 0,
            avg_buy_price  DECIMAL(12,4),
            total_invested DECIMAL(16,4) DEFAULT 0,
            realized_pnl   DECIMAL(16,4) DEFAULT 0,
            last_updated   TIMESTAMP     DEFAULT CURRENT_TIMESTAMP
                                         ON UPDATE CURRENT_TIMESTAMP
        ) ENGINE=InnoDB
        """,
        """
        CREATE TABLE IF NOT EXISTS pnl_summary (
            id                INT AUTO_INCREMENT PRIMARY KEY,
            source_file       VARCHAR(512),
            total_trades      INT          DEFAULT 0,
            inserted_trades   INT          DEFAULT 0,
            total_buy_amount  DECIMAL(16,4) DEFAULT 0,
            total_sell_amount DECIMAL(16,4) DEFAULT 0,
            realized_pnl      DECIMAL(16,4) DEFAULT 0,
            processed_at      TIMESTAMP    DEFAULT CURRENT_TIMESTAMP
        ) ENGINE=InnoDB
        """,
    ]

    with conn.cursor() as cursor:
        for sql in statements:
            cursor.execute(sql)
    conn.commit()
    _schema_initialized = True
    logger.info("Schema verified / initialized")


# ─────────────────────────────────────────────
# Lambda Handler
# ─────────────────────────────────────────────
def lambda_handler(event, context):
    s3_client  = boto3.client("s3")
    ses_client = boto3.client("ses", region_name=os.environ.get("AWS_REGION", "ap-south-1"))
    batch_failures = []

    for record in event.get("Records", []):
        message_id = record["messageId"]
        try:
            bucket, key = _extract_s3_location(record)
            logger.info(f"Processing → s3://{bucket}/{key}")

            csv_content = _download_csv(s3_client, bucket, key)
            trades      = _parse_trades(csv_content)
            logger.info(f"Parsed {len(trades)} trade rows")

            conn = get_db_connection()
            ensure_schema(conn)
            stats = _process_trades(conn, trades, key)
            logger.info(f"Stats: {stats}")

            _send_email(ses_client, stats, key)

        except Exception as exc:
            logger.error(f"Failed on message {message_id}: {exc}", exc_info=True)
            batch_failures.append({"itemIdentifier": message_id})

    return {"batchItemFailures": batch_failures}


# ─────────────────────────────────────────────
# Step 1 — Unwrap SQS → SNS → S3 event chain
# ─────────────────────────────────────────────
def _extract_s3_location(sqs_record: dict) -> tuple:
    body        = json.loads(sqs_record["body"])
    sns_message = json.loads(body["Message"])
    s3_info     = sns_message["Records"][0]["s3"]
    return s3_info["bucket"]["name"], s3_info["object"]["key"]


# ─────────────────────────────────────────────
# Step 2 — Download CSV from S3
# ─────────────────────────────────────────────
def _download_csv(s3_client, bucket: str, key: str) -> str:
    response = s3_client.get_object(Bucket=bucket, Key=key)
    return response["Body"].read().decode("utf-8-sig")  # strips BOM if present


# ─────────────────────────────────────────────
# Step 3 — Parse CSV rows
# ─────────────────────────────────────────────
def _parse_trades(csv_content: str) -> list:
    """
    Expected CSV columns:
        Trade Date | Symbol | Trade Type | Qty | Price | Amount | Exchange

    Dates: YYYY-MM-DD  |  Amounts may have commas
    """
    trades = []
    reader = csv.DictReader(io.StringIO(csv_content))

    for i, row in enumerate(reader, start=2):
        try:
            trade_type = row["Trade Type"].strip().upper()
            if trade_type not in ("BUY", "SELL"):
                raise ValueError(f"Invalid trade_type: {trade_type}")

            trades.append({
                "trade_date": datetime.strptime(row["Trade Date"].strip(), "%Y-%m-%d").date(),
                "symbol":     row["Symbol"].strip().upper(),
                "trade_type": trade_type,
                "quantity":   int(row["Qty"].strip()),
                "price":      _to_decimal(row["Price"]),
                "amount":     _to_decimal(row["Amount"]),
                "exchange":   row["Exchange"].strip().upper(),
            })
        except (KeyError, ValueError, InvalidOperation) as exc:
            logger.warning(f"Row {i} skipped — {exc} | {dict(row)}")

    return trades


def _to_decimal(value: str) -> Decimal:
    return Decimal(str(value).replace(",", "").strip())


# ─────────────────────────────────────────────
# Step 4 — Persist to RDS
# ─────────────────────────────────────────────
def _process_trades(conn, trades: list, file_name: str) -> dict:
    stats = {
        "total_parsed":       len(trades),
        "inserted":           0,
        "duplicates_skipped": 0,
        "buy_count":          0,
        "sell_count":         0,
        "total_buy_amount":   Decimal("0"),
        "total_sell_amount":  Decimal("0"),
        "realized_pnl":       Decimal("0"),
        "symbols":            set(),
    }

    try:
        with conn.cursor() as cursor:
            for trade in trades:
                cursor.execute(
                    """
                    INSERT IGNORE INTO trades
                        (trade_date, symbol, trade_type, quantity, price, amount, exchange, source_file)
                    VALUES (%s, %s, %s, %s, %s, %s, %s, %s)
                    """,
                    (
                        trade["trade_date"], trade["symbol"],
                        trade["trade_type"], trade["quantity"],
                        float(trade["price"]), float(trade["amount"]),
                        trade["exchange"], file_name,
                    ),
                )
                if cursor.rowcount > 0:
                    stats["inserted"] += 1
                    stats["symbols"].add(trade["symbol"])
                    if trade["trade_type"] == "BUY":
                        stats["buy_count"]        += 1
                        stats["total_buy_amount"] += trade["amount"]
                    else:
                        stats["sell_count"]        += 1
                        stats["total_sell_amount"] += trade["amount"]
                else:
                    stats["duplicates_skipped"] += 1

            # Recalculate positions for affected symbols
            for symbol in stats["symbols"]:
                _upsert_position(cursor, symbol)

            stats["realized_pnl"] = stats["total_sell_amount"] - stats["total_buy_amount"]

            cursor.execute(
                """
                INSERT INTO pnl_summary
                    (source_file, total_trades, inserted_trades,
                     total_buy_amount, total_sell_amount, realized_pnl)
                VALUES (%s, %s, %s, %s, %s, %s)
                """,
                (
                    file_name, stats["total_parsed"], stats["inserted"],
                    float(stats["total_buy_amount"]),
                    float(stats["total_sell_amount"]),
                    float(stats["realized_pnl"]),
                ),
            )
            conn.commit()

    except pymysql.Error as err:
        conn.rollback()
        logger.error(f"DB error, rolled back: {err}")
        raise

    stats["symbols"] = sorted(stats["symbols"])
    return stats


def _upsert_position(cursor, symbol: str):
    cursor.execute(
        """
        SELECT
            SUM(CASE WHEN trade_type='BUY'  THEN  quantity ELSE -quantity END) AS net_qty,
            SUM(CASE WHEN trade_type='BUY'  THEN  quantity ELSE 0         END) AS buy_qty,
            SUM(CASE WHEN trade_type='BUY'  THEN  amount   ELSE 0         END) AS buy_amt,
            SUM(CASE WHEN trade_type='SELL' THEN  amount   ELSE 0         END) AS sell_amt
        FROM trades WHERE symbol = %s
        """,
        (symbol,),
    )
    row = cursor.fetchone()
    if not row or row["net_qty"] is None:
        return

    net_qty   = int(row["net_qty"]  or 0)
    buy_qty   = int(row["buy_qty"]  or 0)
    buy_amt   = float(row["buy_amt"]  or 0)
    sell_amt  = float(row["sell_amt"] or 0)

    avg_price       = (buy_amt / buy_qty) if buy_qty > 0 else 0
    realized_pnl    = sell_amt - (avg_price * (buy_qty - net_qty))
    total_invested  = avg_price * net_qty

    cursor.execute(
        """
        INSERT INTO portfolio_positions
            (symbol, net_qty, avg_buy_price, total_invested, realized_pnl)
        VALUES (%s, %s, %s, %s, %s)
        ON DUPLICATE KEY UPDATE
            net_qty        = VALUES(net_qty),
            avg_buy_price  = VALUES(avg_buy_price),
            total_invested = VALUES(total_invested),
            realized_pnl   = VALUES(realized_pnl),
            last_updated   = CURRENT_TIMESTAMP
        """,
        (symbol, net_qty, round(avg_price, 2),
         round(total_invested, 2), round(realized_pnl, 2)),
    )


# ─────────────────────────────────────────────
# Step 5 — Send HTML email via SES
# ─────────────────────────────────────────────
def _send_email(ses_client, stats: dict, file_name: str):
    sender   = os.environ["SENDER_EMAIL"]
    receiver = os.environ["RECEIVER_EMAIL"]

    pnl       = float(stats["realized_pnl"])
    pnl_sign  = "+" if pnl >= 0 else ""
    pnl_color = "#27ae60" if pnl >= 0 else "#e74c3c"
    pnl_emoji = "📈" if pnl >= 0 else "📉"
    now_utc   = datetime.now(timezone.utc).strftime("%d %b %Y, %H:%M UTC")
    symbols   = ", ".join(stats.get("symbols", [])) or "—"
    short_file = file_name.split("/")[-1]

    html = f"""
<!DOCTYPE html>
<html>
<body style="margin:0;padding:0;font-family:Arial,sans-serif;background:#f4f4f4;">
  <table width="100%" cellpadding="0" cellspacing="0">
    <tr><td align="center" style="padding:30px 0;">
      <table width="580" cellpadding="0" cellspacing="0"
             style="background:#fff;border-radius:12px;overflow:hidden;
                    box-shadow:0 2px 10px rgba(0,0,0,.1);">

        <tr>
          <td style="background:linear-gradient(135deg,#1a1a2e,#16213e);
                     padding:26px 30px;color:#fff;">
            <h2 style="margin:0;font-size:20px;">{pnl_emoji} Portfolio Updated</h2>
            <p style="margin:4px 0 0;color:#adb5bd;font-size:12px;">
              File: <strong>{short_file}</strong>
            </p>
          </td>
        </tr>

        <tr>
          <td style="padding:20px 30px 10px;">
            <table width="100%" cellpadding="0" cellspacing="8">
              <tr>
                <td align="center" style="background:#f8f9fa;border-radius:8px;padding:14px;">
                  <div style="font-size:26px;font-weight:700;">{stats['inserted']}</div>
                  <div style="font-size:11px;color:#6c757d;">Trades Loaded</div>
                </td>
                <td width="8"></td>
                <td align="center" style="background:#d4edda;border-radius:8px;padding:14px;">
                  <div style="font-size:26px;font-weight:700;color:#155724;">{stats['buy_count']}</div>
                  <div style="font-size:11px;color:#155724;">BUY</div>
                </td>
                <td width="8"></td>
                <td align="center" style="background:#f8d7da;border-radius:8px;padding:14px;">
                  <div style="font-size:26px;font-weight:700;color:#721c24;">{stats['sell_count']}</div>
                  <div style="font-size:11px;color:#721c24;">SELL</div>
                </td>
              </tr>
            </table>
          </td>
        </tr>

        <tr>
          <td style="padding:10px 30px 20px;">
            <table width="100%" cellpadding="9" cellspacing="0"
                   style="border-collapse:collapse;border:1px solid #dee2e6;border-radius:8px;">
              <tr style="background:#f8f9fa;">
                <th align="left" style="font-size:12px;color:#495057;
                    border-bottom:1px solid #dee2e6;padding:10px;">Metric</th>
                <th align="right" style="font-size:12px;color:#495057;
                    border-bottom:1px solid #dee2e6;padding:10px;">Value</th>
              </tr>
              <tr style="border-bottom:1px solid #dee2e6;">
                <td style="color:#495057;padding:10px;">Total Buy Amount</td>
                <td align="right" style="font-weight:600;padding:10px;">
                  &#8377;{float(stats['total_buy_amount']):,.2f}</td>
              </tr>
              <tr style="border-bottom:1px solid #dee2e6;background:#fafafa;">
                <td style="color:#495057;padding:10px;">Total Sell Amount</td>
                <td align="right" style="font-weight:600;padding:10px;">
                  &#8377;{float(stats['total_sell_amount']):,.2f}</td>
              </tr>
              <tr style="border-bottom:1px solid #dee2e6;">
                <td style="color:#495057;font-weight:700;padding:10px;">Realized P&amp;L</td>
                <td align="right"
                    style="font-weight:700;color:{pnl_color};font-size:16px;padding:10px;">
                  {pnl_sign}&#8377;{pnl:,.2f}</td>
              </tr>
              <tr>
                <td style="color:#495057;padding:10px;">Symbols</td>
                <td align="right" style="color:#6c757d;font-size:12px;padding:10px;">{symbols}</td>
              </tr>
            </table>
          </td>
        </tr>

        <tr>
          <td style="background:#f8f9fa;padding:14px 30px;
                     border-top:1px solid #dee2e6;text-align:center;">
            <p style="margin:0;color:#adb5bd;font-size:11px;">
              Processed: {now_utc} &nbsp;|&nbsp;
              Duplicates skipped: {stats['duplicates_skipped']} &nbsp;|&nbsp;
              <a href="https://cloudwithmani.in" style="color:#6c757d;">cloudwithmani.in</a>
            </p>
          </td>
        </tr>

      </table>
    </td></tr>
  </table>
</body>
</html>
"""

    plain = (
        f"Portfolio Updated — {short_file}\n"
        f"Trades: {stats['inserted']} loaded "
        f"(BUY: {stats['buy_count']}, SELL: {stats['sell_count']})\n"
        f"Buy:  ₹{float(stats['total_buy_amount']):,.2f}\n"
        f"Sell: ₹{float(stats['total_sell_amount']):,.2f}\n"
        f"P&L:  {pnl_sign}₹{pnl:,.2f}\n"
        f"Symbols: {symbols}\n"
        f"Time: {now_utc}"
    )

    ses_client.send_email(
        Source=sender,
        Destination={"ToAddresses": [receiver]},
        Message={
            "Subject": {
                "Data": f"{pnl_emoji} Portfolio Updated: {stats['inserted']} trades | P&L: {pnl_sign}₹{pnl:,.2f}",
                "Charset": "UTF-8",
            },
            "Body": {
                "Html": {"Data": html,  "Charset": "UTF-8"},
                "Text": {"Data": plain, "Charset": "UTF-8"},
            },
        },
    )
    logger.info(f"Email sent to {receiver}")
