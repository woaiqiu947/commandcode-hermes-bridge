"""Watchdog: commandcode-bridge (127.0.0.1:9992)。

由 Windows 计划任务 CommandCodeBridgeWatchdog 每分钟调度(pythonw 无窗口)。
健康时 stdout 为空;探测到宕机则自动拉起(node 直启,日志落盘)。
"""
import os
import subprocess
import sys
import time
import urllib.request

NODE = r"C:\Users\your-user\AppData\Local\hermes\node\node.exe"
BRIDGE_DIR = r"C:\Users\your-user\commandcode-bridge"
LOG = os.path.join(BRIDGE_DIR, "bridge.log")
ERR = os.path.join(BRIDGE_DIR, "bridge.err.log")


def health_ok() -> bool:
    try:
        with urllib.request.urlopen("http://127.0.0.1:9992/health", timeout=3) as resp:
            return resp.status == 200
    except Exception:
        return False


def bridge_node_running() -> bool:
    """精确检测:存在 node 进程且命令行含 dist/index.js(排除其他 node 残留)。"""
    try:
        ps = subprocess.run(
            ["powershell", "-NoProfile", "-Command",
             "Get-CimInstance Win32_Process -Filter \"Name='node.exe'\" "
             "| Where-Object { $_.CommandLine -match 'run-with-guard|dist/index\\.js' } "
             "| Measure-Object | Select-Object -ExpandProperty Count"],
            capture_output=True, text=True, timeout=15,
        )
        return ps.stdout.strip().isdigit() and int(ps.stdout.strip()) > 0
    except Exception:
        return False


def main() -> None:
    if health_ok():
        return
    if bridge_node_running():
        # 端口未就绪但有 bridge 进程:可能正在启动,等下一轮
        return
    with open(LOG, "a", encoding="utf-8", errors="replace") as logf, \
         open(ERR, "a", encoding="utf-8", errors="replace") as errf:
        logf.write(f"[watchdog] {time.strftime('%Y-%m-%d %H:%M:%S')} auto-restart\n")
        logf.flush()
        subprocess.Popen(
            [NODE, "run-with-guard.mjs"],  # guard:吞连接中断类 AbortError,防进程崩溃
            cwd=BRIDGE_DIR,
            stdout=logf,
            stderr=errf,
            creationflags=getattr(subprocess, "CREATE_NO_WINDOW", 0),
        )
    time.sleep(6)
    if health_ok():
        print("commandcode-bridge 宕机,已自动拉起并恢复")
    else:
        print("commandcode-bridge 宕机,已尝试拉起但 6 秒后仍未就绪(看 bridge.err.log)")


if __name__ == "__main__":
    main()
    sys.exit(0)
