#!/usr/bin/env bash
#
# 组装一个可双击运行的 AIRunner.app
#
#   bash Scripts/make_app.sh            # release (默认)
#   bash Scripts/make_app.sh debug      # debug
#
# SwiftPM 产出的可执行文件没有 bundle 结构, 而 SwiftUI 的 App 需要 Info.plist
# 才能拿到正确的应用标识与窗口行为, 因此这里手工组装 .app。

set -euo pipefail

CONFIG="${1:-release}"
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

BIN=".build/${CONFIG}/AIRunner"
APP="${ROOT}/dist/AIRunner.app"

echo "==> 构建 (${CONFIG})"
swift build -c "${CONFIG}" --disable-sandbox

if [[ ! -f "${BIN}" ]]; then
    echo "错误: 找不到可执行文件 ${BIN}" >&2
    exit 1
fi

echo "==> 组装 ${APP}"
rm -rf "${APP}"
mkdir -p "${APP}/Contents/MacOS" "${APP}/Contents/Resources"

cp "${BIN}" "${APP}/Contents/MacOS/AIRunner"
chmod +x "${APP}/Contents/MacOS/AIRunner"

cat > "${APP}/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleDevelopmentRegion</key>
    <string>zh_CN</string>
    <key>CFBundleExecutable</key>
    <string>AIRunner</string>
    <key>CFBundleIdentifier</key>
    <string>com.airunner.app</string>
    <key>CFBundleInfoDictionaryVersion</key>
    <string>6.0</string>
    <key>CFBundleName</key>
    <string>AIRunner</string>
    <key>CFBundleDisplayName</key>
    <string>AIRunner</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>CFBundleShortVersionString</key>
    <string>1.2.1</string>
    <key>CFBundleVersion</key>
    <string>5</string>
    <key>LSMinimumSystemVersion</key>
    <string>14.0</string>
    <key>LSApplicationCategoryType</key>
    <string>public.app-category.developer-tools</string>
    <key>NSHighResolutionCapable</key>
    <true/>
    <!-- 长任务不能被系统"自动终止"掉, 否则 Runner 会被中途杀死 -->
    <key>NSSupportsAutomaticTermination</key>
    <false/>
    <key>NSSupportsSuddenTermination</key>
    <false/>
</dict>
</plist>
PLIST

echo "==> 校验 Info.plist"
plutil -lint "${APP}/Contents/Info.plist"

echo "==> 签名 (ad-hoc)"
if codesign --force --sign - "${APP}" 2>/dev/null; then
    codesign --verify --verbose=1 "${APP}"
else
    echo "(ad-hoc 签名不可用, 已跳过 —— 首次打开可能需要右键 → 打开)"
fi

echo
echo "==> 完成"
echo "    路径: ${APP}"
echo "    运行: open '${APP}'"
echo "    数据: ~/Library/Application Support/AIRunner/airunner.sqlite"
