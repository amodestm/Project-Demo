#!/usr/bin/env python3
"""
<swiftbar.run>short-duration</swiftbar.run>
<swiftbar.hideAbout>true</swiftbar.hideAbout>
<swiftbar.hideRunInTerminal>true</swiftbar.hideRunInTerminal>
<swiftbar.hideLastUpdated>true</swiftbar.hideLastUpdated>
<swiftbar.hideDisablePlugin>true</swiftbar.hideDisablePlugin>
<swiftbar.hideSwiftbar>false</swiftbar.hideSwiftbar>
<swiftbar.env>[]</swiftbar.env>

强平瀑布菜单栏挂件 — SwiftBar 插件
每隔 5 秒读取守护进程的状态文件并显示。

安装:
  1. 先启动守护进程: python3 liquidation_daemon.py
  2. 把本文件复制到 SwiftBar 插件目录:
     cp liquidation_bar.5s.py ~/Library/Application\ Support/SwiftBar/Plugins/
  3. SwiftBar 设置中勾选 "短运行时长"

依赖: 无（仅标准库）
"""

import json
import os
import sys

STATUS_FILE = "/tmp/liquidation_bar.json"


def emoji_side(side: str) -> str:
    return "🔴" if side == "SELL" else "🟢"


def fmt(v: float) -> str:
    if v >= 1_000_000:
        return f"{v/1_000_000:.1f}M"
    if v >= 1_000:
        return f"{v/1_000:.1f}K"
    return f"{v:.0f}"


def render():
    if not os.path.exists(STATUS_FILE):
        print("🔥 ...")
        print("---")
        print("等待守护进程启动...")
        print("运行: python3 liquidation_daemon.py")
        return

    try:
        with open(STATUS_FILE) as f:
            s = json.load(f)
    except (json.JSONDecodeError, OSError):
        print("🔥 err")
        print("---")
        print("读取状态文件失败")
        return

    total = s["total_60s"]
    sell = s["sell_60s"]
    buy = s["buy_60s"]
    count = s["count_60s"]
    waterfall = s["waterfall"]
    alerts = s.get("waterfall_alerts", [])
    top = s.get("top", [])
    latest = s.get("latest", [])
    updated = s.get("updated", "")

    # ── 标题栏 ──
    icon = "🌊" if waterfall else "🔥"
    if total >= 100_000:
        icon = "🌊🌊" if waterfall else "🔥🔥"
    print(f"{icon} {fmt(total)} | size=14")

    # ── 下拉菜单 ──
    print("---")

    # 瀑布报警
    if waterfall:
        print(f"⚠️ 瀑布进行中 | color=red")
        for a in alerts[-3:]:
            print(f"-- {a['time']} 10s={fmt(a['last_10s'])}U ({a['ratio']}x) | color=orange")
        print("---")

    # 概览
    print(f"📊 最近60s")
    print(f"总量: {fmt(total)} USDT")
    print(f"🔴 多单爆仓(SELL): {fmt(sell)} USDT")
    print(f"🟢 空单爆仓(BUY):  {fmt(buy)} USDT")
    print(f"笔数: {count}")
    print("---")

    # TOP 5 火币
    if top:
        print(f"🏆 累计 TOP 5")
        for i, t in enumerate(top[:5], 1):
            total_t = t["sell"] + t["buy"]
            bar = "█" * min(20, max(1, int(total_t / max(t["sell"] + t["buy"] for t in top[:5]) * 20)))
            print(f"{i}. {t['sym']} {fmt(total_t)}U {bar} | color={'red' if t['sell'] > t['buy'] else 'green'}")
        print("---")

    # 最近 5 笔
    if latest:
        print(f"⏱ 最新")
        for e in reversed(latest):
            side_e = emoji_side(e["side"])
            print(f"{side_e} {e['sym']} {fmt(e['usdt'])}U @ {e['price']} | color={'red' if e['side']=='SELL' else 'green'}")
        print("---")

    # 操作
    print(f"🔄 刷新 | refresh=true")
    print(f"⏹ 停止监控 | bash=/usr/bin/pkill param1=-f param2=liquidation_daemon.py terminal=false refresh=true")
    print(f"🕐 {updated} | size=10 color=gray")


if __name__ == "__main__":
    render()
