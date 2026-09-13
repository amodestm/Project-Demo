#!/bin/bash
# =============================================
# Binance 对冲交易平台 — 一键启动器 v2
# 自动读取 API Key + 启动后端 + 桌面客户端
# =============================================

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
BACKEND_PORT=${PLATFORM_PORT:-9090}
PYTHON=${PYTHON:-/Users/<YOUR_USER>/miniforge3/bin/python3}
LOG_FILE="${PROJECT_DIR}/trading_platform.log"

cd "$PROJECT_DIR"

echo "=========================================="
echo " Binance 对冲交易平台 v2 — 启动中..."
echo "=========================================="
echo ""

# 从 run.sh 读取 API Key（只取 export 行，跳过 exec）
if [ -f "run.sh" ]; then
    echo "📄 读取 run.sh 配置..."
    eval "$(grep '^export BINANCE_' run.sh 2>/dev/null)" || true
fi

# 检查 API Key
if [ -n "$BINANCE_API_KEY" ] && [ -n "$BINANCE_API_SECRET" ]; then
    echo "✅ API Key 已加载"
else
    echo "⚠️  未设置 BINANCE_API_KEY/BINANCE_API_SECRET"
    echo "   将使用模拟交易模式"
    echo ""
fi

# 启动后端 (后台)
echo "🔧 启动后端服务 → http://127.0.0.1:${BACKEND_PORT}"
PYTHONPATH="$PROJECT_DIR:$PYTHONPATH" \
    nohup "$PYTHON" -u -m trading_platform.app \
    > "$LOG_FILE" 2>&1 &
BACKEND_PID=$!

# 等待就绪
echo "⏳ 等待后端启动..."
for i in $(seq 1 15); do
    if curl -s -o /dev/null "http://127.0.0.1:${BACKEND_PORT}/api/balance" 2>/dev/null; then
        echo "✅ 后端已就绪 (${i}s)"
        break
    fi
    sleep 1
done

# 启动桌面端
echo "🖥️ 启动桌面客户端..."
echo ""
PYTHONPATH="$PROJECT_DIR:$PYTHONPATH" \
    "$PYTHON" -u -m trading_platform.desktop_app

# 清理
echo ""
echo "🛑 关闭后端服务..."
kill "$BACKEND_PID" 2>/dev/null || true
wait "$BACKEND_PID" 2>/dev/null || true
echo "✅ 平台已关闭"
