#!/bin/bash
# 彻底停掉所有相关进程 + 清残留文件

for NAME in liquidation_daemon price_drop_monitor; do
    echo "=== 查找 $NAME ==="
    ps aux | grep "$NAME" | grep -v grep

    PIDS=$(pgrep -f "$NAME" 2>/dev/null)
    if [ -n "$PIDS" ]; then
        echo "→ 杀进程: $PIDS"
        kill -9 $PIDS 2>/dev/null
        sleep 1
        pgrep -f "$NAME" && echo "⚠️ $NAME 还有残留" || echo "✅ $NAME 已清"
    else
        echo "✅ 没有运行中的 $NAME"
    fi
    echo ""
done

echo "=== 清理残留文件 ==="
rm -f ~/.liq_harvest/liquidation_daemon.pid
rm -f ~/.liq_harvest/liquidation_bar.json
echo "✅ 残留文件已清"
