#!/usr/bin/env python3
"""
==========================
monitor.py — 运行监控器
==========================
职责: 终端实时监控策略运行状态
  - 每 10 秒自动刷新
  - 显示: 进程状态 / 运行时间 / CPU / 内存
  - 显示: 今日交易笔数 / 净盈亏 / 手续费
  - 追踪新交易，增量显示

用法:
  python3 monitor.py                    # 监控已有进程
  或修改 PID 变量后运行（默认 PID=8266）

注意:
  另开终端运行，不影响主策略进程。
  Ctrl+C 退出。
"""
import sqlite3
import time
import os
import subprocess
import sys

DB_PATH = os.path.expanduser("~/WorkBuddy/binance_liq_harvest/trades.sqlite3")
PID = 8266
CHECK_INTERVAL = 10
LAST_CHECK_ID = 19  # 从第 19 笔之后开始监控


def get_proc():
    try:
        r = subprocess.run(["ps", "-p", str(PID), "-o", "etime,%cpu,%mem"],
                           capture_output=True, text=True, timeout=3)
        lines = r.stdout.strip().split("\n")
        return lines[1].split() if len(lines) >= 2 else None
    except Exception:
        return None


def get_trades(since_id):
    if not os.path.exists(DB_PATH):
        return [], 0, {}
    conn = sqlite3.connect(DB_PATH)
    conn.row_factory = sqlite3.Row
    new = [dict(r) for r in conn.execute(
        "SELECT * FROM trades WHERE id > ? ORDER BY id ASC", (since_id,)).fetchall()]
    total = conn.execute("SELECT COUNT(*) FROM trades").fetchone()[0]
    today = conn.execute("""SELECT COUNT(*),SUM(net_pnl),SUM(fees) FROM trades
        WHERE date(datetime(exit_time,'unixepoch'))=date('now')""").fetchone()
    conn.close()
    return new, total, dict(today) if today else {}


os.system("clear" if os.name == "posix" else "cls")
print("=" * 66)
print("  清算瀑布收割 · 实时监控器")
print("  另开终端运行，每 10 秒自动刷新")
print("  Ctrl+C 退出")
print("=" * 66)

while True:
    os.system("clear" if os.name == "posix" else "cls")
    print("=" * 66)
    print(f"  [{time.strftime('%H:%M:%S')}] 清算瀑布收割 · 实时监控")
    print("=" * 66)

    p = get_proc()
    if p:
        print(f"  PID {PID} | 运行 {p[0]} | CPU {p[1]}% | MEM {p[2]}%")
    else:
        print(f"  PID {PID} 已停止")
        print("=" * 66)
        time.sleep(CHECK_INTERVAL)
        continue

    new_trades, total, today = get_trades(LAST_CHECK_ID)
    if today:
        t, pnl, fees = today["COUNT(*)"], today["SUM(net_pnl)"], today["SUM(fees)"]
        print(f"  今日: {t}笔 | 盈亏 {pnl:+.4f}U | 手续费 {fees:.4f}U")

    if new_trades:
        print(f"  新交易 +{len(new_trades)} 笔 (总{total})")
        print(f"  {'时间':<8} {'品种':<10} {'方向':<5} {'净利':<12} {'原因'}")
        print(f"  {'-'*8} {'-'*10} {'-'*5} {'-'*12} {'-'*16}")
        for nt in new_trades:
            et = time.strftime("%H:%M:%S", time.localtime(nt["exit_time"]))
            pnl = nt["net_pnl"]
            ds = '+' if pnl >= 0 else ''
            print(f"  {et} {nt['symbol']:<8} {nt['side']:<5} {ds}{pnl:.4f}U     {nt['exit_reason']}")
        LAST_CHECK_ID = new_trades[-1]["id"]
    else:
        print(f"  无新交易 (总{total})")

    print("=" * 66)
    print(f"  每 {CHECK_INTERVAL}s 自动刷新 | Ctrl+C 退出")
    time.sleep(CHECK_INTERVAL)
