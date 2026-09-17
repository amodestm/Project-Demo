#!/usr/bin/env bash
#
# 组装独立的 AIDiscussion.app (AI 议事会)
#
#   bash Scripts/make_discussion_app.sh            # release (默认)
#   bash Scripts/make_discussion_app.sh debug      # debug
#

set -euo pipefail

CONFIG="${1:-release}"
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

BIN=".build/${CONFIG}/AIDiscussion"
APP_NAME="AIDiscussion"
BUNDLE_ID="com.aidiscussion.app"
DISPLAY_NAME="AI 议事会"
SHORT_VERSION="1.0.0"
BUILD_VERSION="1"
APP="${ROOT}/dist/${APP_NAME}.app"
TARGET_APP="/Applications/${APP_NAME}.app"

echo "==> 构建 AIDiscussion (${CONFIG})"
swift build -c "${CONFIG}" --disable-sandbox

if [[ ! -f "${BIN}" ]]; then
    echo "错误: 找不到可执行文件 ${BIN}" >&2
    exit 1
fi

echo "==> 组装 ${APP}"
rm -rf "${APP}"
mkdir -p "${APP}/Contents/MacOS" "${APP}/Contents/Resources"

cp "${BIN}" "${APP}/Contents/MacOS/AIDiscussion"
chmod +x "${APP}/Contents/MacOS/AIDiscussion"

cat > "${APP}/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleDevelopmentRegion</key>
    <string>zh_CN</string>
    <key>CFBundleExecutable</key>
    <string>AIDiscussion</string>
    <key>CFBundleIdentifier</key>
    <string>${BUNDLE_ID}</string>
    <key>CFBundleInfoDictionaryVersion</key>
    <string>6.0</string>
    <key>CFBundleName</key>
    <string>${APP_NAME}</string>
    <key>CFBundleDisplayName</key>
    <string>${DISPLAY_NAME}</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>CFBundleShortVersionString</key>
    <string>${SHORT_VERSION}</string>
    <key>CFBundleVersion</key>
    <string>${BUILD_VERSION}</string>
    <key>LSMinimumSystemVersion</key>
    <string>14.0</string>
    <key>LSApplicationCategoryType</key>
    <string>public.app-category.productivity</string>
    <key>NSHighResolutionCapable</key>
    <true/>
    <key>NSSupportsAutomaticTermination</key>
    <false/>
    <key>NSSupportsSuddenTermination</key>
    <false/>
</dict>
</plist>
PLIST

echo "==> 校验 Info.plist"
plutil -lint "${APP}/Contents/Info.plist"

echo "==> 签名 (ad-hoc 指定标识符)"
LOCAL_REQUIREMENT="=designated => identifier \"${BUNDLE_ID}\""
codesign --force --sign - --requirements "${LOCAL_REQUIREMENT}" "${APP}"

if codesign --verify --deep --strict --verbose=1 "${APP}"; then
    echo "==> 签名验证通过:"
    codesign -d -r- "${APP}" 2>&1 | tail -n 1
else
    echo "错误: App 签名校验失败" >&2
    exit 1
fi

echo "==> 安装到 /Applications/${APP_NAME}.app"
rm -rf "${TARGET_APP}"
cp -R "${APP}" "${TARGET_APP}"

echo "================================================="
echo "✅ 构建并安装成功！"
echo "产物路径: ${TARGET_APP}"
echo "启动命令: open \"${TARGET_APP}\""
echo "================================================="
