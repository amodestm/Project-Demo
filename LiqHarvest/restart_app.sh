#!/bin/bash
# 杀掉旧 daemon + 打开新版本 LiquidationMonitor.app

set -e
cd "$(dirname "$0")"

echo "→ 杀掉旧 daemon..."
pkill -f liquidation_daemon 2>/dev/null || true
sleep 1

echo "→ 打开新版 LiquidationMonitor.app..."
open ./LiquidationMonitor.app

echo "✅ 完成！新 daemon 已自动启动，涨幅数据已就位。"
