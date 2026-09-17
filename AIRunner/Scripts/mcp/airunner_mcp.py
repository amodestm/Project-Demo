#!/usr/bin/env python3
"""AIRunner MCP server.

让 Codex 在长任务执行期间能够：

  * 主动查询当前账号的真实 Codex 额度（5 小时窗口 / 每周窗口 / 恢复时间）；
  * 读取 AIRunner 的账号轮换池与每个账号最近一次采集到的额度快照；
  * 在额度即将或已经耗尽时，请求 AIRunner 保存检查点、切换到额度最先恢复的
    账号，并自动续跑当前线程。

设计约束
--------
* **只用 Python 标准库** —— 不引入任何第三方依赖，便于作为一个常驻子进程被
  Codex 直接拉起。
* **只读取凭据，不外传** —— 额度查询使用本机 Codex 自己的
  `~/.codex/auth.json` 中的 access token；token 不会被写入任何日志或返回值。
* **控制类动作不直接改状态** —— 切号与续跑涉及 GUI 自动化（需要辅助功能
  权限）以及任务检查点，必须由正在运行的 AIRunner 应用执行。本进程只把请求
  写入 `mcp-inbox/` 并等待结果文件，避免两个进程同时操作同一份状态。

协议：MCP over stdio（newline-delimited JSON-RPC 2.0）。
"""

from __future__ import annotations

import json
import os
import plistlib
import sqlite3
import subprocess
import sys
import time
import urllib.error
import urllib.request
import uuid
from datetime import datetime, timedelta, timezone

SERVER_NAME = "airunner"
SERVER_VERSION = "1.0.0"
PROTOCOL_VERSION = "2024-11-05"

CODEX_HOME = os.environ.get("CODEX_HOME") or os.path.expanduser("~/.codex")
SUPPORT_DIR = os.environ.get(
    "AIRUNNER_SUPPORT_DIR",
    os.path.expanduser("~/Library/Application Support/AIRunner"),
)
CHROME_DIR = os.environ.get(
    "AIRUNNER_CHROME_DIR",
    os.path.expanduser("~/Library/Application Support/Google/Chrome"),
)
AIRUNNER_BUNDLE_ID = os.environ.get("AIRUNNER_BUNDLE_ID", "com.airunner.oauth")
HTTP_PROXY = os.environ.get("AIRUNNER_MCP_PROXY") or ""

AUTH_PATH = os.path.join(CODEX_HOME, "auth.json")
DB_PATH = os.path.join(SUPPORT_DIR, "airunner.sqlite")
INBOX_DIR = os.path.join(SUPPORT_DIR, "mcp-inbox")

USAGE_URL = "https://chatgpt.com/backend-api/wham/usage"
HTTP_TIMEOUT = float(os.environ.get("AIRUNNER_MCP_HTTP_TIMEOUT") or 20)
INBOX_TIMEOUT = float(os.environ.get("AIRUNNER_MCP_INBOX_TIMEOUT") or 240)


# --------------------------------------------------------------------------
# 时间工具
# --------------------------------------------------------------------------

def now_utc() -> datetime:
    return datetime.now(timezone.utc)


def iso(dt: datetime) -> str:
    return dt.astimezone(timezone.utc).strftime("%Y-%m-%dT%H:%M:%S.%f")[:-3] + "Z"


def local_text(ts) -> str:
    """把 unix 时间戳渲染成本地可读时间。"""
    if ts in (None, ""):
        return ""
    try:
        value = float(ts)
    except (TypeError, ValueError):
        return str(ts)
    if value <= 0:
        return ""
    return datetime.fromtimestamp(value).strftime("%Y-%m-%d %H:%M:%S")


def human_delta(seconds) -> str:
    try:
        seconds = float(seconds)
    except (TypeError, ValueError):
        return ""
    if seconds <= 0:
        return "已恢复"
    minutes, sec = divmod(int(seconds), 60)
    hours, minutes = divmod(minutes, 60)
    days, hours = divmod(hours, 24)
    if days:
        return "%d天%d小时" % (days, hours)
    if hours:
        return "%d小时%d分" % (hours, minutes)
    if minutes:
        return "%d分%d秒" % (minutes, sec)
    return "%d秒" % sec


# --------------------------------------------------------------------------
# Codex 凭据与额度
# --------------------------------------------------------------------------

class ProbeError(Exception):
    pass


def read_codex_auth():
    """读取本机 Codex 的 OAuth 凭据。

    只返回内存中的 token；调用方不得把它写进日志或工具返回值。
    """
    if not os.path.exists(AUTH_PATH):
        raise ProbeError("找不到 %s：本机 Codex 尚未登录。" % AUTH_PATH)
    try:
        with open(AUTH_PATH, "r", encoding="utf-8") as handle:
            data = json.load(handle)
    except Exception as exc:  # noqa: BLE001
        raise ProbeError("读取 Codex 凭据失败：%s" % exc)
    tokens = data.get("tokens") or {}
    token = tokens.get("access_token")
    account_id = tokens.get("account_id")
    if not token:
        raise ProbeError("Codex 凭据里没有 access_token，请重新登录。")
    return {
        "access_token": token,
        "account_id": account_id,
        "auth_mode": data.get("auth_mode"),
    }


def http_get_json(url, headers):
    request = urllib.request.Request(url, headers=headers, method="GET")
    handlers = []
    if HTTP_PROXY:
        handlers.append(urllib.request.ProxyHandler({"http": HTTP_PROXY, "https": HTTP_PROXY}))
    opener = urllib.request.build_opener(*handlers)
    try:
        with opener.open(request, timeout=HTTP_TIMEOUT) as response:
            body = response.read().decode("utf-8", "replace")
    except urllib.error.HTTPError as exc:
        detail = ""
        try:
            detail = exc.read().decode("utf-8", "replace")[:300]
        except Exception:  # noqa: BLE001
            pass
        raise ProbeError("额度接口返回 HTTP %s：%s" % (exc.code, detail))
    except Exception as exc:  # noqa: BLE001
        raise ProbeError("额度接口不可达：%s" % exc)
    try:
        return json.loads(body)
    except Exception as exc:  # noqa: BLE001
        raise ProbeError("额度接口返回了非 JSON 内容：%s" % exc)


def parse_usage(raw):
    """把 wham/usage 的原始响应整理成稳定结构。"""
    rate = raw.get("rate_limit") or {}
    primary = rate.get("primary_window") or {}
    secondary = rate.get("secondary_window") or {}
    credits = raw.get("credits") or {}
    reset_credits = raw.get("rate_limit_reset_credits") or {}

    models = []
    for name, entry in (raw.get("model_usage") or {}).items():
        entry = entry or {}
        models.append({
            "model": name,
            "available": bool(entry.get("available")),
            "available_at": entry.get("available_at"),
            "available_at_local": local_text(entry.get("available_at")),
            "credits_would_enable": bool(entry.get("credits_would_enable")),
        })

    def window(node):
        if not node:
            return None
        used = node.get("used_percent")
        return {
            "used_percent": used,
            "remaining_percent": (100 - used) if isinstance(used, (int, float)) else None,
            "window_seconds": node.get("limit_window_seconds"),
            "window_text": human_delta(node.get("limit_window_seconds")) if node.get("limit_window_seconds") else "",
            "reset_after_seconds": node.get("reset_after_seconds"),
            "reset_after_text": human_delta(node.get("reset_after_seconds")),
            "reset_at": node.get("reset_at"),
            "reset_at_local": local_text(node.get("reset_at")),
        }

    return {
        "email": raw.get("email"),
        "account_id": raw.get("account_id"),
        "user_id": raw.get("user_id"),
        "plan_type": raw.get("plan_type"),
        "allowed": rate.get("allowed"),
        "limit_reached": rate.get("limit_reached"),
        "rate_limit_reached_type": raw.get("rate_limit_reached_type"),
        "primary": window(primary),
        "secondary": window(secondary),
        "credits_balance": credits.get("balance"),
        "credits_unlimited": credits.get("unlimited"),
        "reset_credits_available": reset_credits.get("available_count"),
        "reset_credits_applicable": reset_credits.get("applicable_available_count"),
        "models": models,
        "captured_at": iso(now_utc()),
    }


def probe_quota():
    auth = read_codex_auth()
    headers = {
        "Authorization": "Bearer %s" % auth["access_token"],
        "Accept": "application/json",
        "User-Agent": "airunner-mcp/%s" % SERVER_VERSION,
    }
    if auth.get("account_id"):
        headers["chatgpt-account-id"] = auth["account_id"]
    raw = http_get_json(USAGE_URL, headers)
    parsed = parse_usage(raw)
    parsed["auth_mode"] = auth.get("auth_mode")
    return parsed


# --------------------------------------------------------------------------
# AIRunner 本地数据
# --------------------------------------------------------------------------

def open_db():
    if not os.path.exists(DB_PATH):
        return None
    try:
        connection = sqlite3.connect(
            "file:%s?mode=ro" % DB_PATH, uri=True, timeout=5
        )
        connection.row_factory = sqlite3.Row
        return connection
    except Exception:  # noqa: BLE001
        return None


def db_rows(sql, params=()):
    connection = open_db()
    if connection is None:
        return []
    try:
        return [dict(row) for row in connection.execute(sql, params).fetchall()]
    except Exception:  # noqa: BLE001
        return []
    finally:
        connection.close()


def table_exists(name):
    return bool(db_rows(
        "SELECT 1 FROM sqlite_master WHERE type='table' AND name=?", (name,)
    ))


def load_settings():
    """读取 AIRunner 的 UserDefaults 设置（只取非敏感字段）。"""
    path = os.path.expanduser("~/Library/Preferences/%s.plist" % AIRUNNER_BUNDLE_ID)
    if not os.path.exists(path):
        return {}
    try:
        with open(path, "rb") as handle:
            plist = plistlib.load(handle)
    except Exception:  # noqa: BLE001
        return {}
    blob = plist.get("com.airunner.settings.v1")
    if isinstance(blob, (bytes, bytearray)):
        try:
            return json.loads(blob.decode("utf-8"))
        except Exception:  # noqa: BLE001
            return {}
    if isinstance(blob, str):
        try:
            return json.loads(blob)
        except Exception:  # noqa: BLE001
            return {}
    return {}


def chrome_profiles():
    """Chrome profile 目录名 -> 显示名（本项目里显示名就是账号邮箱）。"""
    state = os.path.join(CHROME_DIR, "Local State")
    if not os.path.exists(state):
        return {}
    try:
        with open(state, "r", encoding="utf-8") as handle:
            data = json.load(handle)
    except Exception:  # noqa: BLE001
        return {}
    return {
        key: (value or {}).get("name", "")
        for key, value in (data.get("profile", {}).get("info_cache", {}) or {}).items()
    }


def rotation_pool():
    """轮换池：用户配置的有序 profile 列表；未配置时返回全部可用 profile。"""
    settings = load_settings()
    configured = settings.get("accountRotationProfileDirectories") or []
    aliases = settings.get("accountRotationProfileAliases") or {}
    available = chrome_profiles()

    if configured:
        pool = [d for d in configured if d in available]
    else:
        pool = sorted(available.keys())

    oauth_enabled = settings.get("useCodexBrowserOAuthRotation")
    entries = []
    for directory in pool:
        name = aliases.get(directory) or available.get(directory) or ""
        entries.append({
            "profile_directory": directory,
            "display_name": name,
            "label": name or directory,
        })
    return {
        "oauth_rotation_enabled": oauth_enabled,
        "pool": entries,
        "profiles_known_to_chrome": len(available),
    }


def latest_snapshots():
    """每个 profile 最近一次额度快照。"""
    if not table_exists("codex_account_quota_snapshots"):
        return {}
    rows = db_rows(
        """
        SELECT s.* FROM codex_account_quota_snapshots s
        JOIN (
            SELECT profile_directory, MAX(captured_at) AS ts
            FROM codex_account_quota_snapshots
            GROUP BY profile_directory
        ) latest
          ON latest.profile_directory = s.profile_directory
         AND latest.ts = s.captured_at
        """
    )
    return {row["profile_directory"]: row for row in rows}


def active_cooldowns():
    if not table_exists("codex_account_quota_cooldowns"):
        return {}
    stamp = iso(now_utc())
    rows = db_rows(
        "SELECT * FROM codex_account_quota_cooldowns WHERE available_at > ?", (stamp,)
    )
    return {row["account_key"]: row for row in rows}


def active_tasks(limit=10):
    rows = db_rows(
        """
        SELECT id, name, status, updated_at, error_message
        FROM tasks
        WHERE status NOT IN ('completed', 'failed', 'cancelled')
        ORDER BY updated_at DESC LIMIT ?
        """,
        (limit,),
    )
    bindings = {row["task_id"]: row for row in db_rows(
        "SELECT task_id, id, display_title, chrome_profile_directory, resume_message "
        "FROM codex_task_bindings WHERE task_id IS NOT NULL"
    )}
    rotations = {row["task_id"]: row for row in db_rows(
        "SELECT * FROM account_rotation_state"
    )}
    for row in rows:
        row["binding"] = bindings.get(row["id"])
        row["rotation"] = rotations.get(row["id"])
    return rows


# --------------------------------------------------------------------------
# 控制请求（交给运行中的 AIRunner 执行）
# --------------------------------------------------------------------------

def airunner_is_running():
    """AIRunner 应用是否在运行。无法判断时返回 None（不阻断请求）。"""
    try:
        result = subprocess.run(
            ["pgrep", "-f", "AIRunner OAuth.app/Contents/MacOS/AIRunner"],
            capture_output=True, timeout=5,
        )
        return result.returncode == 0
    except Exception:  # noqa: BLE001
        return None


def send_control_request(action, payload, timeout=None):
    # 快速失败：AIRunner 没跑、或版本还没有 MCP 请求通道时，`mcp-inbox` 目录
    # 不存在。这种情况直接给出可行动的错误，比让模型干等四分钟有用得多。
    if not os.path.isdir(INBOX_DIR):
        return {
            "ok": False,
            "error": (
                "AIRunner 的 MCP 请求目录不存在（%s）。请先启动 AIRunner OAuth，"
                "并确认它已升级到带 MCP 请求通道的版本。" % INBOX_DIR
            ),
            "action": action,
        }
    if airunner_is_running() is False:
        return {
            "ok": False,
            "error": (
                "AIRunner OAuth 当前没有运行。控制类请求（切号 / 续跑）必须由正在运行的 "
                "AIRunner 执行；只读的额度查询不受影响。"
            ),
            "action": action,
        }

    request_id = uuid.uuid4().hex
    request = {
        "id": request_id,
        "action": action,
        "source": "codex-mcp",
        "created_at": iso(now_utc()),
    }
    request.update(payload)

    request_path = os.path.join(INBOX_DIR, "%s.json" % request_id)
    result_path = os.path.join(INBOX_DIR, "%s.result.json" % request_id)
    tmp_path = "%s.tmp" % request_path

    with open(tmp_path, "w", encoding="utf-8") as handle:
        json.dump(request, handle, ensure_ascii=False)
    os.replace(tmp_path, request_path)

    deadline = time.time() + (timeout if timeout is not None else INBOX_TIMEOUT)
    while time.time() < deadline:
        if os.path.exists(result_path):
            try:
                with open(result_path, "r", encoding="utf-8") as handle:
                    result = json.load(handle)
            except Exception:  # noqa: BLE001
                time.sleep(0.5)
                continue
            try:
                os.remove(result_path)
            except OSError:
                pass
            return result
        time.sleep(1.0)

    return {
        "ok": False,
        "pending": True,
        "request_id": request_id,
        "error": (
            "AIRunner 在 %.0f 秒内没有处理这条请求。请确认 AIRunner OAuth 正在运行，"
            "并且它已经启用 MCP 请求通道。" % (timeout if timeout is not None else INBOX_TIMEOUT)
        ),
    }


# --------------------------------------------------------------------------
# 工具实现
# --------------------------------------------------------------------------

def tool_quota_status(args):
    profile = (args or {}).get("profile_directory") or ""
    live_error = None

    current_profile = None
    rows = db_rows(
        "SELECT current_profile FROM account_rotation_state "
        "WHERE current_profile IS NOT NULL ORDER BY last_rotated_at DESC LIMIT 1"
    )
    if rows:
        current_profile = rows[0]["current_profile"]

    if profile and profile != current_profile:
        snapshots = latest_snapshots()
        snapshot = snapshots.get(profile)
        pool = {entry["profile_directory"]: entry for entry in rotation_pool()["pool"]}
        if not snapshot:
            return {
                "source": "unavailable",
                "profile_directory": profile,
                "label": (pool.get(profile) or {}).get("label") or profile,
                "message": (
                    "该 Profile 不是当前 Codex 登录账号，且还没有采集到它的额度快照。"
                    "额度接口只能查询当前登录账号；其他账号的数据要等 AIRunner 在下一次"
                    "轮换到它时采集。"
                ),
            }
        return {
            "source": "snapshot",
            "profile_directory": profile,
            "label": (pool.get(profile) or {}).get("label") or profile,
            "captured_at": snapshot.get("captured_at"),
            "captured_at_local": local_text_iso(snapshot.get("captured_at")),
            "email": snapshot.get("email"),
            "plan_type": snapshot.get("plan_type"),
            "allowed": bool(snapshot.get("allowed")),
            "limit_reached": bool(snapshot.get("limit_reached")),
            "primary": {
                "used_percent": snapshot.get("primary_used_percent"),
                "reset_at": snapshot.get("primary_reset_at"),
                "reset_at_local": local_text(snapshot.get("primary_reset_at")),
            },
            "secondary": {
                "used_percent": snapshot.get("secondary_used_percent"),
                "reset_at": snapshot.get("secondary_reset_at"),
                "reset_at_local": local_text(snapshot.get("secondary_reset_at")),
            },
            "model_available_at_local": local_text(snapshot.get("model_available_at")),
            "note": "这是历史快照，不是实时值；使用时请以 captured_at 为准判断新鲜度。",
        }

    try:
        data = probe_quota()
    except ProbeError as exc:
        live_error = str(exc)
        snapshots = latest_snapshots()
        snapshot = snapshots.get(current_profile or "")
        if snapshot:
            return {
                "source": "snapshot",
                "profile_directory": current_profile,
                "captured_at": snapshot.get("captured_at"),
                "email": snapshot.get("email"),
                "primary": {
                    "used_percent": snapshot.get("primary_used_percent"),
                    "reset_at_local": local_text(snapshot.get("primary_reset_at")),
                },
                "warning": live_error,
            }
        return {"source": "error", "error": live_error}

    return {
        "source": "live",
        "profile_directory": current_profile,
        "auth_mode": data.get("auth_mode"),
        "email": data.get("email"),
        "account_id": data.get("account_id"),
        "plan_type": data.get("plan_type"),
        "allowed": data.get("allowed"),
        "limit_reached": data.get("limit_reached"),
        "rate_limit_reached_type": data.get("rate_limit_reached_type"),
        "primary": data.get("primary"),
        "secondary": data.get("secondary"),
        "credits_balance": data.get("credits_balance"),
        "credits_unlimited": data.get("credits_unlimited"),
        "reset_credits_available": data.get("reset_credits_available"),
        "models": data.get("models"),
        "captured_at": data.get("captured_at"),
    }


def local_text_iso(value):
    if not value:
        return ""
    try:
        text = str(value).replace("Z", "+00:00")
        parsed = datetime.fromisoformat(text)
        if parsed.tzinfo is None:
            parsed = parsed.replace(tzinfo=timezone.utc)
        return parsed.astimezone().strftime("%Y-%m-%d %H:%M:%S")
    except Exception:  # noqa: BLE001
        return str(value)


def tool_list_rotation_accounts(_args):
    rot = rotation_pool()
    snapshots = latest_snapshots()
    cooldowns = active_cooldowns()
    now = time.time()

    accounts = []
    for entry in rot["pool"]:
        directory = entry["profile_directory"]
        snapshot = snapshots.get(directory) or {}
        cooldown = cooldowns.get("profile:%s" % directory)
        remaining_seconds = None
        if cooldown:
            remaining_seconds = max(
                0.0, iso_to_epoch(cooldown.get("available_at")) - now
            )

        reset_at = snapshot.get("primary_reset_at")
        seconds_to_reset = None
        if isinstance(reset_at, (int, float)) and reset_at > 0:
            seconds_to_reset = max(0.0, float(reset_at) - now)

        limit_reached = bool(snapshot.get("limit_reached")) if snapshot else None
        used = snapshot.get("primary_used_percent")

        accounts.append({
            "profile_directory": directory,
            "label": entry["label"],
            "has_snapshot": bool(snapshot),
            "snapshot_captured_at_local": local_text_iso(snapshot.get("captured_at")),
            "email": snapshot.get("email"),
            "plan_type": snapshot.get("plan_type"),
            "limit_reached": limit_reached,
            "primary_used_percent": used,
            "primary_remaining_percent": (100 - used) if isinstance(used, (int, float)) else None,
            "primary_reset_at_local": local_text(reset_at),
            "primary_recovers_in": human_delta(seconds_to_reset) if seconds_to_reset is not None else "",
            "secondary_used_percent": snapshot.get("secondary_used_percent"),
            "in_quota_cooldown": bool(cooldown),
            "cooldown_until_local": local_text_iso((cooldown or {}).get("available_at")),
            "cooldown_recovers_in": human_delta(remaining_seconds) if remaining_seconds is not None else "",
            "_reset_at": reset_at or 0,
        })

    accounts.sort(key=rank_key)
    recommended = next((a for a in accounts if not a["in_quota_cooldown"]), None)
    for account in accounts:
        account.pop("_reset_at", None)

    return {
        "oauth_rotation_enabled": rot["oauth_rotation_enabled"],
        "account_count": len(accounts),
        "recommended_next": recommended["label"] if recommended else None,
        "ordering_rule": (
            "排序规则：无冷却且额度未耗尽（按已用额度升序）→ 额度已耗尽但恢复时间最早 → "
            "无快照的账号。实际切换由 AIRunner 按同一规则执行。"
        ),
        "accounts": accounts,
    }


def iso_to_epoch(value):
    if not value:
        return 0.0
    try:
        text = str(value).replace("Z", "+00:00")
        parsed = datetime.fromisoformat(text)
        if parsed.tzinfo is None:
            parsed = parsed.replace(tzinfo=timezone.utc)
        return parsed.timestamp()
    except Exception:  # noqa: BLE001
        return 0.0


def rank_key(account):
    """排序：先排除冷却中的账号，再优先额度未耗尽的（已用越少越靠前），
    其次是额度已耗尽但恢复时间最早的，最后才是没有快照、情况未知的账号。"""
    cooldown = 1 if account["in_quota_cooldown"] else 0
    if not account["has_snapshot"]:
        tier, order = 2, 0.0
    elif account["limit_reached"] is False:
        tier, order = 0, float(account["primary_used_percent"] or 0)
    else:
        tier, order = 1, float(account.get("_reset_at") or 0)
    return (cooldown, tier, order)


def tool_quota_history(args):
    args = args or {}
    profile = args.get("profile_directory") or ""
    limit = int(args.get("limit") or 20)
    if not table_exists("codex_account_quota_snapshots"):
        return {"snapshots": [], "note": "额度快照表尚未创建（AIRunner 还未升级到该版本）。"}
    if profile:
        rows = db_rows(
            "SELECT * FROM codex_account_quota_snapshots WHERE profile_directory = ? "
            "ORDER BY captured_at DESC LIMIT ?",
            (profile, limit),
        )
    else:
        rows = db_rows(
            "SELECT * FROM codex_account_quota_snapshots ORDER BY captured_at DESC LIMIT ?",
            (limit,),
        )
    history = [{
        "profile_directory": row.get("profile_directory"),
        "email": row.get("email"),
        "captured_at_local": local_text_iso(row.get("captured_at")),
        "source": row.get("source"),
        "limit_reached": bool(row.get("limit_reached")),
        "primary_used_percent": row.get("primary_used_percent"),
        "primary_reset_at_local": local_text(row.get("primary_reset_at")),
        "secondary_used_percent": row.get("secondary_used_percent"),
        "model_available_at_local": local_text(row.get("model_available_at")),
    } for row in rows]
    return {"count": len(history), "snapshots": history}


def tool_task_status(args):
    args = args or {}
    task_id = args.get("task_id") or ""
    tasks = active_tasks()
    if task_id:
        tasks = [t for t in tasks if t["id"] == task_id]
        if not tasks:
            rows = db_rows(
                "SELECT id, name, status, updated_at, error_message FROM tasks WHERE id = ?",
                (task_id,),
            )
            tasks = rows
    result = []
    for task in tasks:
        binding = task.get("binding") or {}
        rotation = task.get("rotation") or {}
        result.append({
            "task_id": task["id"],
            "name": task.get("name"),
            "status": task.get("status"),
            "updated_at_local": local_text_iso(task.get("updated_at")),
            "error_message": task.get("error_message"),
            "codex_thread_bound": bool(binding),
            "thread_title": binding.get("display_title"),
            "chrome_profile_directory": binding.get("chrome_profile_directory"),
            "resume_message": binding.get("resume_message"),
            "current_profile": rotation.get("current_profile"),
            "rotation_count": rotation.get("rotation_count"),
        })
    return {"count": len(result), "tasks": result}


def tool_resume_task(args):
    args = args or {}
    payload = {
        "task_id": args.get("task_id") or "",
        "message": args.get("message") or "继续",
        "reason": args.get("reason") or "Codex 通过 MCP 请求续跑",
    }
    if not payload["task_id"]:
        return {"ok": False, "error": "必须提供 task_id。可先用 task_status 查询。"}
    return send_control_request("resumeTask", payload, timeout=args.get("timeout_seconds"))


def tool_request_account_switch(args):
    args = args or {}
    payload = {
        "task_id": args.get("task_id") or "",
        "reason": args.get("reason") or "额度不足",
        "target_profile_directory": args.get("target_profile_directory") or "",
        "resume_message": args.get("resume_message") or "继续",
        "resume_after_switch": bool(args.get("resume_after_switch", True)),
    }
    if not payload["task_id"]:
        return {"ok": False, "error": "必须提供 task_id。可先用 task_status 查询。"}
    return send_control_request(
        "switchAccount", payload, timeout=args.get("timeout_seconds")
    )


def tool_report_quota_exhausted(args):
    args = args or {}
    payload = {
        "task_id": args.get("task_id") or "",
        "reason": args.get("reason") or "Codex 自报额度耗尽",
        "detail": args.get("detail") or "",
    }
    return send_control_request(
        "reportQuotaExhausted", payload, timeout=args.get("timeout_seconds")
    )


def tool_capture_quota_snapshot(args):
    args = args or {}
    payload = {
        "reason": args.get("reason") or "Codex 通过 MCP 主动采集",
        "target_profile_directory": args.get("profile_directory") or "",
    }
    return send_control_request(
        "snapshotQuota", payload, timeout=args.get("timeout_seconds")
    )


# --------------------------------------------------------------------------
# 工具清单
# --------------------------------------------------------------------------

TOOLS = [
    {
        "name": "quota_status",
        "description": (
            "查询当前 Codex 账号的真实额度：5 小时窗口与每周窗口的已用百分比、恢复时间，"
            "以及各模型的可用时间（available_at）和额外余额。数据来自 OpenAI 官方用量接口，"
            "是实时值。\n\n"
            "什么时候调用：开始一个耗时较长或需要大量推理的任务之前；长时间连续生成之后；"
            "遇到「rate limit」「usage limit」「稍后重试」类提示时；提交大批量任务前的容量评估。"
        ),
        "inputSchema": {
            "type": "object",
            "properties": {
                "profile_directory": {
                    "type": "string",
                    "description": (
                        "可选。Chrome Profile 目录名（如 \"Profile 16\"）。省略时查询当前 Codex "
                        "登录账号的实时额度；指定非当前账号时只能返回 AIRunner 采集过的历史快照。"
                    ),
                }
            },
        },
    },
    {
        "name": "list_rotation_accounts",
        "description": (
            "列出 AIRunner 账号轮换池里的全部账号，以及每个账号最近一次采集到的额度快照、"
            "5 小时窗口恢复时间、是否处于额度冷却中，并按「优先可用」排序给出建议的下一个账号。\n\n"
            "什么时候调用：需要了解还有哪些账号可用、哪个账号额度最先恢复时；决定是否值得"
            "让 AIRunner 切换账号之前。"
        ),
        "inputSchema": {"type": "object", "properties": {}},
    },
    {
        "name": "task_status",
        "description": (
            "查询 AIRunner 里的任务状态：任务 ID、当前状态、绑定的 Codex 线程标题、当前使用的 "
            "Chrome Profile 与轮换次数。省略 task_id 时返回所有未结束的任务。\n\n"
            "什么时候调用：需要拿到 task_id 才能请求切号或续跑时；确认 AIRunner 是否正在监控"
            "当前任务时；排查「切换了账号但任务没继续」之前。"
        ),
        "inputSchema": {
            "type": "object",
            "properties": {
                "task_id": {"type": "string", "description": "可选。AIRunner 任务 ID。"}
            },
        },
    },
    {
        "name": "quota_history",
        "description": (
            "查询某账号（或全部账号）的历史额度快照，用于判断额度恢复规律："
            "每次采集时 5 小时/每周窗口的已用比例与恢复时间点。\n\n"
            "什么时候调用：想评估某个账号大概什么时候能恢复、或核对「模型恢复时间」的历史记录时。"
        ),
        "inputSchema": {
            "type": "object",
            "properties": {
                "profile_directory": {"type": "string", "description": "可选。只查该 Profile。"},
                "limit": {"type": "integer", "description": "可选，默认 20。返回条数上限。"},
            },
        },
    },
    {
        "name": "resume_task",
        "description": (
            "请求 AIRunner 向当前绑定的 Codex 线程补发一次「继续」消息，不切换账号。\n\n"
            "什么时候调用：额度仍然充足、但当前这一轮生成已经停止而任务尚未完成时。"
            "如果额度已经耗尽或即将耗尽，请改用 request_account_switch。\n\n"
            "注意：这个动作会真实往 Codex 里发送消息。同一个任务短时间内不要重复调用。"
        ),
        "inputSchema": {
            "type": "object",
            "properties": {
                "task_id": {"type": "string", "description": "AIRunner 任务 ID。"},
                "message": {"type": "string", "description": "可选，默认「继续」。"},
                "reason": {"type": "string", "description": "可选。本次续跑的原因，会记入事件日志。"},
                "timeout_seconds": {"type": "number", "description": "可选，默认 240 秒。"},
            },
            "required": ["task_id"],
        },
    },
    {
        "name": "request_account_switch",
        "description": (
            "请求 AIRunner 完成一次完整的账号交接：保存当前任务检查点 → 用 Codex 原生流程退出"
            "当前账号 → 通过额度最先恢复的 Chrome Profile 重新完成 OAuth 登录 → 必要时自动向"
            "线程补发「继续」续跑。这是一次真实的账号切换，会改变 Codex 当前登录账号。\n\n"
            "什么时候调用（需要同时满足）：额度已经耗尽，或 5 小时窗口剩余比例低到无法完成"
            "当前任务；并且当前线程已经停止生成（没有正在进行的推理）。\n\n"
            "调用前建议先用 quota_status 与 list_rotation_accounts 确认确实有必要切换。"
        ),
        "inputSchema": {
            "type": "object",
            "properties": {
                "task_id": {"type": "string", "description": "AIRunner 任务 ID。"},
                "reason": {"type": "string", "description": "切换原因，例如「5 小时额度已用 97%」。"},
                "target_profile_directory": {
                    "type": "string",
                    "description": "可选。指定目标 Chrome Profile；省略时由 AIRunner 按额度快照自动挑选。",
                },
                "resume_message": {"type": "string", "description": "可选，默认「继续」。"},
                "resume_after_switch": {
                    "type": "boolean",
                    "description": "可选，默认 true。切号成功后是否自动补发「继续」。",
                },
                "timeout_seconds": {"type": "number", "description": "可选，默认 240 秒。"},
            },
            "required": ["task_id"],
        },
    },
    {
        "name": "capture_quota_snapshot",
        "description": (
            "立即采集一次当前 Codex 登录账号的实时额度，并写入 AIRunner 的额度快照表。"
            "AIRunner 之后就能按这份数据判断「哪个账号有余额、哪个账号恢复最早」。\n\n"
            "什么时候调用：开始一个长任务之前想留下当前账号的额度基线；"
            "刚被切换到新账号之后（此时探测到的就是这个新账号的数据）；"
            "或者你刚发现额度明显变化、想让 AIRunner 记住这个时刻。"
        ),
        "inputSchema": {
            "type": "object",
            "properties": {
                "profile_directory": {
                    "type": "string",
                    "description": "可选。把这次快照记到哪个 Chrome Profile 名下；省略时按最近使用的账号推断。",
                },
                "reason": {"type": "string", "description": "可选。采集原因，会记入事件日志。"},
                "timeout_seconds": {"type": "number", "description": "可选，默认 240 秒。"},
            },
        },
    },
    {
        "name": "report_quota_exhausted",
        "description": (
            "把你观察到的额度耗尽信号上报给 AIRunner，让它记录并决定是否切换账号。"
            "与 GUI 屏幕识别相比，这条通道由模型主动上报，更准确。\n\n"
            "什么时候调用：你直接读到了额度耗尽的明确提示，但暂时不希望立即切换账号时。"
            "如果希望立刻恢复执行，请直接调用 request_account_switch。"
        ),
        "inputSchema": {
            "type": "object",
            "properties": {
                "task_id": {"type": "string", "description": "AIRunner 任务 ID。"},
                "reason": {"type": "string", "description": "可选。默认「Codex 自报额度耗尽」。"},
                "detail": {"type": "string", "description": "可选。你看到的原始提示文本。"},
            },
            "required": ["task_id"],
        },
    },
]

TOOL_HANDLERS = {
    "quota_status": tool_quota_status,
    "list_rotation_accounts": tool_list_rotation_accounts,
    "task_status": tool_task_status,
    "quota_history": tool_quota_history,
    "resume_task": tool_resume_task,
    "request_account_switch": tool_request_account_switch,
    "capture_quota_snapshot": tool_capture_quota_snapshot,
    "report_quota_exhausted": tool_report_quota_exhausted,
}


# --------------------------------------------------------------------------
# JSON-RPC / MCP 主循环
# --------------------------------------------------------------------------

def text_result(payload, is_error=False):
    body = json.dumps(payload, ensure_ascii=False, indent=2)
    return {"content": [{"type": "text", "text": body}], "isError": is_error}


def handle_request(message):
    method = message.get("method")
    params = message.get("params") or {}

    if method == "initialize":
        return {
            "protocolVersion": PROTOCOL_VERSION,
            "capabilities": {"tools": {"listChanged": False}},
            "serverInfo": {"name": SERVER_NAME, "version": SERVER_VERSION},
            "instructions": (
                "AIRunner 桥接服务。提供两个能力：一是查询当前 Codex 账号的实时额度与恢复时间，"
                "二是请求 AIRunner 执行账号切换 / 续跑。额度不足时优先使用 request_account_switch，"
                "让 AIRunner 切到额度最先恢复的账号后继续执行。"
            ),
        }

    if method in ("notifications/initialized", "initialized"):
        return None

    if method == "ping":
        return {}

    if method == "tools/list":
        return {"tools": TOOLS}

    if method == "tools/call":
        name = params.get("name")
        arguments = params.get("arguments") or {}
        handler = TOOL_HANDLERS.get(name)
        if handler is None:
            return text_result({"error": "未知工具：%s" % name}, is_error=True)
        try:
            return text_result(handler(arguments))
        except ProbeError as exc:
            return text_result({"error": str(exc)}, is_error=True)
        except Exception as exc:  # noqa: BLE001
            return text_result({"error": "工具执行失败：%s" % exc}, is_error=True)

    raise MethodNotFound(method)


class MethodNotFound(Exception):
    def __init__(self, method):
        super().__init__("未知方法：%s" % method)
        self.method = method


def write_message(payload):
    sys.stdout.write(json.dumps(payload, ensure_ascii=False) + "\n")
    sys.stdout.flush()


def main():
    for line in sys.stdin:
        line = line.strip()
        if not line:
            continue
        try:
            message = json.loads(line)
        except Exception:  # noqa: BLE001
            continue

        message_id = message.get("id")
        if message_id is None:
            try:
                handle_request(message)
            except Exception:  # noqa: BLE001
                pass
            continue

        try:
            result = handle_request(message)
        except MethodNotFound as exc:
            write_message({
                "jsonrpc": "2.0",
                "id": message_id,
                "error": {"code": -32601, "message": str(exc)},
            })
            continue
        except Exception as exc:  # noqa: BLE001
            write_message({
                "jsonrpc": "2.0",
                "id": message_id,
                "error": {"code": -32603, "message": "%s: %s" % (type(exc).__name__, exc)},
            })
            continue

        write_message({"jsonrpc": "2.0", "id": message_id, "result": result})


if __name__ == "__main__":
    try:
        main()
    except (KeyboardInterrupt, BrokenPipeError):
        pass
