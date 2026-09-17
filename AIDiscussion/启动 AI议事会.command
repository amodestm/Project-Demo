#!/usr/bin/env bash
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
if [[ -d "/Applications/AIDiscussion.app" ]]; then
    open "/Applications/AIDiscussion.app"
elif [[ -d "${ROOT}/dist/AIDiscussion.app" ]]; then
    open "${ROOT}/dist/AIDiscussion.app"
else
    echo "未找到 AIDiscussion.app，正在自动编译打包..."
    bash "${ROOT}/Scripts/make_discussion_app.sh"
    open "/Applications/AIDiscussion.app"
fi
