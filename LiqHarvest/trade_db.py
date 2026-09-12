"""
===========================
trade_db.py — 持久化层
===========================
职责: SQLite 交易数据库 (纯 sqlite3，无 ORM)

表结构:
  trades — 逐笔交易记录
    id / symbol / side / entry_price / exit_price / quantity /
    gross_pnl / fees / net_pnl / entry_time / exit_time / exit_reason
  daily_summary — 日报汇总（自动计算）
    date / total_trades / win_rate / net_pnl / best_trade / worst_trade

函数:
  init_db(path)             — 建表（幂等）
  insert_trade(db, trade)   — 插入一笔交易
  get_daily_summary(db,date) — 某日汇总
  get_all_trades(db, limit)  — 最近 N 笔
  get_equity_curve(db, days) — 权益曲线 (最近 N 天)
"""

import sqlite3
import time
from typing import Any, Dict, List, Optional

SCHEMA_SQL = """
CREATE TABLE IF NOT EXISTS trades (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    symbol TEXT NOT NULL,
    side TEXT NOT NULL CHECK(side IN ('LONG', 'SHORT')),
    entry_price REAL NOT NULL,
    exit_price REAL NOT NULL,
    quantity REAL NOT NULL,
    gross_pnl REAL NOT NULL,
    fees REAL NOT NULL,
    net_pnl REAL NOT NULL,
    entry_time REAL NOT NULL,
    exit_time REAL NOT NULL,
    exit_reason TEXT NOT NULL,
    created_at TEXT DEFAULT (datetime('now'))
);

CREATE TABLE IF NOT EXISTS daily_summary (
    date TEXT PRIMARY KEY,
    total_trades INTEGER NOT NULL DEFAULT 0,
    winning_trades INTEGER NOT NULL DEFAULT 0,
    losing_trades INTEGER NOT NULL DEFAULT 0,
    gross_pnl REAL NOT NULL DEFAULT 0,
    total_fees REAL NOT NULL DEFAULT 0,
    net_pnl REAL NOT NULL DEFAULT 0,
    win_rate REAL NOT NULL DEFAULT 0,
    best_trade REAL,
    worst_trade REAL,
    created_at TEXT DEFAULT (datetime('now'))
);
"""


def init_db(path: str) -> None:
    """Create tables if they do not exist (idempotent)."""
    conn = sqlite3.connect(path)
    conn.executescript(SCHEMA_SQL)
    conn.commit()
    conn.close()


def insert_trade(db_path: str, trade: Dict[str, Any]) -> int:
    """Insert a completed trade row. Returns the new row id."""
    init_db(db_path)
    conn = sqlite3.connect(db_path)
    conn.execute(
        """INSERT INTO trades
           (symbol, side, entry_price, exit_price, quantity,
            gross_pnl, fees, net_pnl, entry_time, exit_time, exit_reason)
           VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)""",
        (
            trade["symbol"],
            trade["side"],
            trade["entry_price"],
            trade["exit_price"],
            trade["quantity"],
            trade["gross_pnl"],
            trade["fees"],
            trade["net_pnl"],
            trade["entry_time"],
            trade["exit_time"],
            trade["exit_reason"],
        ),
    )
    conn.commit()
    row_id = conn.execute("SELECT last_insert_rowid()").fetchone()[0]
    conn.close()
    return row_id


def get_daily_summary(db_path: str, date_str: str) -> Optional[Dict[str, Any]]:
    """Compute and return daily stats for *date_str* (YYYY-MM-DD).

    Returns None when there are no trades on that date.
    """
    conn = sqlite3.connect(db_path)
    conn.row_factory = sqlite3.Row
    row = conn.execute(
        """SELECT
               COUNT(*)                        AS total_trades,
               SUM(CASE WHEN net_pnl > 0 THEN 1 ELSE 0 END) AS winning_trades,
               SUM(CASE WHEN net_pnl <= 0 THEN 1 ELSE 0 END) AS losing_trades,
               COALESCE(SUM(gross_pnl), 0)     AS gross_pnl,
               COALESCE(SUM(fees), 0)          AS total_fees,
               COALESCE(SUM(net_pnl), 0)       AS net_pnl,
               CASE WHEN COUNT(*) > 0
                    THEN 1.0 * SUM(CASE WHEN net_pnl > 0 THEN 1 ELSE 0 END) / COUNT(*)
                    ELSE 0
               END                             AS win_rate,
               MAX(net_pnl)                    AS best_trade,
               MIN(net_pnl)                    AS worst_trade
           FROM trades
           WHERE date(datetime(exit_time, 'unixepoch')) = ?""",
        (date_str,),
    ).fetchone()
    conn.close()

    if row is None or row["total_trades"] == 0:
        return None
    return dict(row)


def get_all_trades(db_path: str, limit: int = 100) -> List[Dict[str, Any]]:
    """Return recent trades, newest first."""
    conn = sqlite3.connect(db_path)
    conn.row_factory = sqlite3.Row
    rows = conn.execute(
        "SELECT * FROM trades ORDER BY id DESC LIMIT ?", (limit,)
    ).fetchall()
    conn.close()
    return [dict(r) for r in rows]


def get_equity_curve(db_path: str, days: int = 30) -> List[Dict[str, Any]]:
    """Return daily P&L for the last *days* days.

    Each entry: ``{date, daily_pnl, cumulative_pnl}``.
    """
    conn = sqlite3.connect(db_path)
    conn.row_factory = sqlite3.Row
    cutoff = time.time() - days * 86400
    rows = conn.execute(
        """SELECT
               date(datetime(exit_time, 'unixepoch')) AS trade_date,
               SUM(net_pnl) AS daily_pnl
           FROM trades
           WHERE exit_time >= ?
           GROUP BY trade_date
           ORDER BY trade_date""",
        (cutoff,),
    ).fetchall()
    conn.close()

    curve = []
    cumulative = 0.0
    for r in rows:
        cumulative += r["daily_pnl"]
        curve.append({
            "date": r["trade_date"],
            "daily_pnl": round(r["daily_pnl"], 4),
            "cumulative_pnl": round(cumulative, 4),
        })
    return curve
