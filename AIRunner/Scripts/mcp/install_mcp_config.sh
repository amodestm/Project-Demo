#!/usr/bin/env bash
#
# 打印（或写入）Codex 的 AIRunner MCP 配置片段。
#
#   bash Scripts/mcp/install_mcp_config.sh          # 只打印，不改任何文件
#   bash Scripts/mcp/install_mcp_config.sh --apply  # 幂等写入 ~/.codex/config.toml
#   bash Scripts/mcp/install_mcp_config.sh --remove # 从配置里移除这一段
#
# 刻意默认**只打印**：~/.codex/config.toml 里通常还有 API key 等敏感内容，
# 自动改写别人正在用的配置风险太高，交给用户自己确认后再执行。

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
CONFIG="${HOME}/.codex/config.toml"
SERVER_NAME="airunner"
SCRIPT="${ROOT}/Scripts/mcp/airunner_mcp.py"
PYTHON="/usr/bin/python3"

if [[ ! -f "${SCRIPT}" ]]; then
    cat >&2 <<EOF
找不到 MCP server 脚本：${SCRIPT}

请确认 AIRunner 仓库路径正确。
EOF
    exit 1
fi

if [[ ! -x "${PYTHON}" ]]; then
    cat >&2 <<EOF
找不到 ${PYTHON}。AIRunner MCP 只用 Python 标准库，也可以用其他 Python 3.9+ 解释器，
改一下本脚本里的 PYTHON 即可。
EOF
    exit 1
fi

BLOCK="$(cat <<EOF

# AIRunner 桥接：查询当前账号实时额度、上报额度耗尽、请求切号与续跑。
# 需要 AIRunner OAuth 正在运行；控制类请求由它在本地 inbox 中处理。
[mcp_servers.${SERVER_NAME}]
command = "${PYTHON}"
args = ["${SCRIPT}"]
startup_timeout_sec = 20
enabled = true
EOF
)"

case "${1:-}" in
    --remove)
        if [[ ! -f "${CONFIG}" ]]; then
            echo "没有 ${CONFIG}，无需移除。" >&2
            exit 0
        fi
        if ! grep -qE "^\[mcp_servers\.${SERVER_NAME}\]" "${CONFIG}"; then
            echo "${CONFIG} 里没有 [mcp_servers.${SERVER_NAME}]，无需移除。"
            exit 0
        fi
        cp "${CONFIG}" "${CONFIG}.bak-${SERVER_NAME}-mcp"
        awk -v target="[mcp_servers.${SERVER_NAME}]" '
            $0 == target { skip = 1; next }
            skip && /^\[/ { skip = 0 }
            skip { next }
            { print }
        ' "${CONFIG}" > "${CONFIG}.tmp"
        mv "${CONFIG}.tmp" "${CONFIG}"
        echo "已移除 [mcp_servers.${SERVER_NAME}]；原配置备份在 ${CONFIG}.bak-${SERVER_NAME}-mcp"
        ;;

    --apply)
        if [[ ! -f "${CONFIG}" ]]; then
            mkdir -p "$(dirname "${CONFIG}")"
            : > "${CONFIG}"
        fi
        if grep -qE "^\[mcp_servers\.${SERVER_NAME}\]" "${CONFIG}"; then
            echo "${CONFIG} 里已经有 [mcp_servers.${SERVER_NAME}]，未做修改。"
            echo "要更新路径，先 --remove 再 --apply。"
            exit 0
        fi
        cp "${CONFIG}" "${CONFIG}.bak-${SERVER_NAME}-mcp"
        printf '%s\n' "${BLOCK}" >> "${CONFIG}"
        echo "已写入 [mcp_servers.${SERVER_NAME}]；原配置备份在 ${CONFIG}.bak-${SERVER_NAME}-mcp"
        echo
        echo "重启 Codex 后生效。验证：在会话里问「你现在还剩多少额度？」"
        ;;

    *)
        cat <<EOF
把下面这段加进 ${CONFIG}：

${BLOCK}

或者直接执行（会先做幂等检查，已存在则不动）：

    bash "${ROOT}/Scripts/mcp/install_mcp_config.sh" --apply

移除：

    bash "${ROOT}/Scripts/mcp/install_mcp_config.sh" --remove
EOF
        ;;
esac
