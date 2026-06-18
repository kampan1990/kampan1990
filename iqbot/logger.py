"""
CSV trade logger.

Columns: timestamp, asset, trade_type, direction, amount, duration,
         result, pnl, balance_after, strategy_signal
"""

import csv
import logging
import os
from datetime import datetime, timezone

logger = logging.getLogger(__name__)

CSV_PATH = os.path.join(os.path.dirname(__file__), "trades.csv")

_FIELDS = [
    "timestamp",
    "asset",
    "trade_type",
    "direction",
    "amount",
    "duration_min",
    "result",       # win / loss / pending
    "pnl",
    "balance_after",
    "trade_id",
]


def _ensure_header() -> None:
    if not os.path.exists(CSV_PATH) or os.path.getsize(CSV_PATH) == 0:
        with open(CSV_PATH, "w", newline="") as f:
            csv.DictWriter(f, fieldnames=_FIELDS).writeheader()


def log_trade(
    asset: str,
    trade_type: str,
    direction: str,
    amount: float,
    duration_min: int,
    result: str = "pending",
    pnl: float = 0.0,
    balance_after: float = 0.0,
    trade_id: str = "",
) -> None:
    _ensure_header()

    row = {
        "timestamp": datetime.now(timezone.utc).isoformat(timespec="seconds"),
        "asset": asset,
        "trade_type": trade_type,
        "direction": direction,
        "amount": amount,
        "duration_min": duration_min,
        "result": result,
        "pnl": round(pnl, 2),
        "balance_after": round(balance_after, 2),
        "trade_id": trade_id,
    }

    with open(CSV_PATH, "a", newline="") as f:
        csv.DictWriter(f, fieldnames=_FIELDS).writerow(row)

    logger.debug("Logged trade: %s", row)


def update_trade_result(trade_id: str, result: str, pnl: float, balance_after: float) -> None:
    """
    Rewrite the CSV row for a specific trade_id once the result is known.
    IQ Option binary trades settle after the expiry; this lets us patch the row.
    """
    if not os.path.exists(CSV_PATH):
        return

    rows = []
    updated = False
    with open(CSV_PATH, newline="") as f:
        reader = csv.DictReader(f)
        for row in reader:
            if row.get("trade_id") == trade_id and row.get("result") == "pending":
                row["result"] = result
                row["pnl"] = round(pnl, 2)
                row["balance_after"] = round(balance_after, 2)
                updated = True
            rows.append(row)

    if updated:
        with open(CSV_PATH, "w", newline="") as f:
            writer = csv.DictWriter(f, fieldnames=_FIELDS)
            writer.writeheader()
            writer.writerows(rows)
        logger.debug("Updated result for trade_id=%s: %s pnl=%.2f", trade_id, result, pnl)
