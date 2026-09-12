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
APP_NAME="${AIRUNNER_APP_NAME:-AIRunner}"
BUNDLE_ID="${AIRUNNER_BUNDLE_ID:-com.airunner.app}"
DISPLAY_NAME="${AIRUNNER_DISPLAY_NAME:-${APP_NAME}}"
SHORT_VERSION="${AIRUNNER_SHORT_VERSION:-1.3.2}"
BUILD_VERSION="${AIRUNNER_BUILD_VERSION:-26}"
APP="${ROOT}/dist/${APP_NAME}.app"

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

cat > "${APP}/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleDevelopmentRegion</key>
    <string>zh_CN</string>
    <key>CFBundleExecutable</key>
    <string>AIRunner</string>
    <key>CFBundleIdentifier</key>
    <string>${BUNDLE_ID}</string>
    <key>CFBundleInfoDictionaryVersion</key>
    <string>6.0</string>
    <key>CFBundleName</key>
    <string>AIRunner</string>
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
SIGNING_IDENTITY="${AIRUNNER_CODESIGN_IDENTITY:--}"
if [[ "${SIGNING_IDENTITY}" == "-" ]]; then
    # 普通 ad-hoc 签名的 designated requirement 是每次构建都会变化的 cdhash，
    # 会导致 macOS TCC 把每个新版都当成新的辅助功能客户端。固定本地开发版的
    # designated requirement，让同一 bundle id 的后续构建继承一次性授权。
    LOCAL_REQUIREMENT="=designated => identifier \"${BUNDLE_ID}\""
    codesign --force --sign - --requirements "${LOCAL_REQUIREMENT}" "${APP}"
elif codesign --force --sign "${SIGNING_IDENTITY}" "${APP}" 2>/dev/null; then
    echo "    身份: ${SIGNING_IDENTITY}"
else
    echo "错误: 无法使用 AIRUNNER_CODESIGN_IDENTITY=${SIGNING_IDENTITY} 签名" >&2
    exit 1
fi

if codesign --verify --deep --strict --verbose=1 "${APP}"; then
    codesign -d -r- "${APP}" 2>&1 | tail -n 1
else
    echo "错误: App 签名校验失败" >&2
    exit 1
fi

echo
echo "==> 完成"
echo "    路径: ${APP}"
echo "    运行: open '${APP}'"
echo "    数据: ~/Library/Application Support/AIRunner/airunner.sqlite"
