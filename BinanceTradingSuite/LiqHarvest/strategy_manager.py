"""
策略进程管理器 — 供 Dashboard 调用
"""
import json
import os
import signal
import subprocess
import time
from pathlib import Path

BASE_DIR = Path(__file__).parent
CONFIG_FILE = BASE_DIR / "strategy_config.json"


def _status_file(name: str) -> str:
    return f"/tmp/bf_status_{name}.json"


def _pid_file(name: str) -> str:
    return f"/tmp/bf_pid_{name}"


def load_config() -> dict:
    with open(CONFIG_FILE) as f:
        return json.load(f)


def save_config(cfg: dict):
    with open(CONFIG_FILE, "w") as f:
        json.dump(cfg, f, indent=2, ensure_ascii=False)


def is_running(name: str) -> bool:
    pid_file = _pid_file(name)
    if not os.path.exists(pid_file):
        return False
    try:
        with open(pid_file) as f:
            pid = int(f.read().strip())
        os.kill(pid, 0)  # 检查进程是否存在
        return True
    except (ProcessLookupError, OSError, ValueError):
        os.remove(pid_file)
        return False


def start_strategy(name: str):
    """启动策略子进程"""
    if is_running(name):
        return {"ok": False, "msg": f"{name} 已在运行"}

    pid_file = _pid_file(name)
    cmd = [
        "/Users/<YOUR_USER>/miniforge3/bin/python3",
        str(BASE_DIR / "run_strategy.py"),
        "--strategy", name,
        "--config", str(CONFIG_FILE),
    ]
    proc = subprocess.Popen(
        cmd,
        cwd=str(BASE_DIR),
        stdout=subprocess.DEVNULL,
        stderr=subprocess.DEVNULL,
    )
    with open(pid_file, "w") as f:
        f.write(str(proc.pid))
    return {"ok": True, "msg": f"{name} 启动 (PID={proc.pid})"}


def stop_strategy(name: str):
    """停止策略子进程"""
    pid_file = _pid_file(name)
    if not os.path.exists(pid_file):
        return {"ok": False, "msg": f"{name} 未运行"}

    try:
        with open(pid_file) as f:
            pid = int(f.read().strip())
        os.kill(pid, signal.SIGTERM)
        # 等 5s 看是否退出
        for _ in range(25):
            try:
                os.kill(pid, 0)
                time.sleep(0.2)
            except ProcessLookupError:
                break
        else:
            os.kill(pid, signal.SIGKILL)  # 强制杀
    except (ProcessLookupError, OSError, ValueError):
        pass

    if os.path.exists(pid_file):
        os.remove(pid_file)
    return {"ok": True, "msg": f"{name} 已停止"}


def get_status(name: str) -> dict:
    """获取策略运行状态"""
    running = is_running(name)
    status = {
        "running": running,
        "name": name,
        "positions": 0,
        "daily_pnl": 0.0,
        "balance": 0.0,
        "coins": 0,
    }
    if running:
        sf = _status_file(name)
        if os.path.exists(sf):
            try:
                with open(sf) as f:
                    status.update(json.load(f))
            except Exception:
                pass
    return status
