#!/bin/bash
# 对冲交易平台 — 一键启动
cd "$(dirname "$0")/.."

export BINANCE_API_KEY="YOUR_BINANCE_API_KEY"
export BINANCE_API_SECRET="YOUR_BINANCE_API_SECRET"

# 清掉代理环境变量 — 防止 urllib 把 localhost 也走 SOCKS5
unset ALL_PROXY http_proxy https_proxy
PYTHON=/Users/<YOUR_USER>/miniforge3/bin/python3

# 杀掉旧进程
kill $(lsof -ti :9090) 2>/dev/null
sleep 1

echo "🚀 启动后端..."
$PYTHON -m trading_platform.app &
BACKEND_PID=$!
sleep 2

echo "🚀 启动桌面端..."
$PYTHON -m trading_platform.desktop_app

kill $BACKEND_PID 2>/dev/null
echo "已关闭"
