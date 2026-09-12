#!/bin/bash
#
# 双击这个文件即可启动 AIRunner（图形界面）。
#
# 优先使用 /Applications 里已安装的正式版本；
# 若不存在则回退到项目内 dist/ 构建（首次会自动构建）。
#
set -e
cd "$(dirname "$0")"

INSTALLED="/Applications/AIRunner.app"
DIST="dist/AIRunner.app"

if [ -d "$INSTALLED" ]; then
    APP="$INSTALLED"
else
    if [ ! -d "$DIST" ]; then
        echo "未找到已安装版本，首次运行：正在构建 AIRunner，大约需要 15 秒…"
        echo
        swift build -c release --disable-sandbox
        bash Scripts/make_app.sh release
        echo
        echo "构建完成。"
        echo
    fi
    APP="$DIST"
fi

echo "正在启动 AIRunner ($(defaults read "$APP/Contents/Info.plist" CFBundleShortVersionString))…"
open "$APP"

echo
echo "已启动。这个终端窗口可以直接关掉。"
echo
echo "数据位置：~/Library/Application Support/AIRunner/airunner.sqlite"
echo "API Key 位置：macOS 钥匙串 (service = com.airunner.apikeys)"
