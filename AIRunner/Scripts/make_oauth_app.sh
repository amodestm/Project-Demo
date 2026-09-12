#!/usr/bin/env bash

# 生成独立的 OAuth/Profile 技术路线版本。它使用独立应用名和 bundle id，
# 不覆盖旧的 AIRunner.app（1.3.2 / build 26）。

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

AIRUNNER_APP_NAME="AIRunner OAuth" \
AIRUNNER_DISPLAY_NAME="AIRunner OAuth" \
AIRUNNER_BUNDLE_ID="com.airunner.oauth" \
AIRUNNER_SHORT_VERSION="1.5.5" \
AIRUNNER_BUILD_VERSION="41" \
    bash "${ROOT}/Scripts/make_app.sh" "${1:-release}"
