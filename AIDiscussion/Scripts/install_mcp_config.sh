#!/usr/bin/env bash
#
# 打印（或写入）Codex 的 MCP 配置片段。
#
#   bash Scripts/install_mcp_config.sh          # 只打印，不改任何文件
#   bash Scripts/install_mcp_config.sh --apply  # 追加写入 ~/.codex/config.toml
#
# 刻意默认**只打印**：~/.codex/config.toml 里通常还有 API key 等敏感内容，
# 自动改写别人正在用的配置风险太高，交给用户自己确认后再执行。

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CONFIG="${HOME}/.codex/config.toml"
SERVER_NAME="aidiscussion"

find_binary() {
    for candidate in \
        "${ROOT}/.build/release/AIDiscussionMCP" \
        "${ROOT}/.build/debug/AIDiscussionMCP"
    do
        if [[ -x "${candidate}" ]]; then
            printf '%s' "${candidate}"
            return 0
        fi
    done
    return 1
}

if ! BINARY="$(find_binary)"; then
    cat >&2 <<'EOF'
找不到 AIDiscussionMCP 可执行文件。

先构建：
    swift build -c release --disable-sandbox

然后再运行本脚本。
EOF
    exit 1
fi

BLOCK="$(cat <<EOF

[mcp_servers.${SERVER_NAME}]
command = "${BINARY}"
args = []
startup_timeout_sec = 60
EOF
)"

if [[ "${1:-}" != "--apply" ]]; then
    cat <<EOF
把下面这段加进 ${CONFIG}：

${BLOCK}

或者直接执行（会先做幂等检查，已存在则不动）：

    bash "${ROOT}/Scripts/install_mcp_config.sh" --apply

加完后重启 Codex。可用 ${SERVER_NAME} 的工具应出现在工具列表里。
EOF
    exit 0
fi

if [[ -f "${CONFIG}" ]] && grep -q "^\[mcp_servers\.${SERVER_NAME}\]" "${CONFIG}"; then
    echo "${CONFIG} 里已经有 [mcp_servers.${SERVER_NAME}]，未改动。" >&2
    echo "如需更新路径，请手动编辑该段。" >&2
    exit 0
fi

mkdir -p "$(dirname "${CONFIG}")"
printf '%s\n' "${BLOCK}" >> "${CONFIG}"
echo "已写入 ${CONFIG}"
echo "重启 Codex 后生效。"
