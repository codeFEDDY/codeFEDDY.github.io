#!/usr/bin/env python3
"""
Quillgeist Lite emergency recovery v2026.09.24.6.

Python owns recovery orchestration. PowerShell is used only as a narrow bridge to
Windows ScheduledTasks/CIM where Windows exposes no stable stdlib Python API.

Design invariant:
  automatic qq lifecycle NEVER depends on a Windows Terminal profile.

This script self-elevates, stops the restart loop, disables stale Terminal launch
sources, refreshes canonical files atomically, rewrites the managed task to an
absolute PowerShell launcher, restarts the watchdog, and verifies a real runner PID.
"""

from __future__ import annotations

import ctypes
import os
import pathlib
import subprocess
import sys
import tempfile
import time
import urllib.request

VERSION = "2026.09.24.6.1"
RAW = "https://raw.githubusercontent.com/codeFEDDY/codeFEDDY.github.io/fdcce8eca26534c4088dacb53536d8de4c7660d9/quillgeist-lite"
SERVICE = "CodeFEDDYQQHealth"
TASK = "CodeFEDDY qq Runner"

def log(msg: str) -> None:
    print(msg, flush=True)

def run(args, timeout=30):
    try:
        return subprocess.run(args, capture_output=True, text=True, timeout=timeout)
    except Exception as exc:
        return subprocess.CompletedProcess(args, 1, "", str(exc))

def is_admin() -> bool:
    try:
        return bool(ctypes.windll.shell32.IsUserAnAdmin())
    except Exception:
        return False

def elevate_self() -> bool:
    if is_admin():
        return False
    params = subprocess.list2cmdline([str(pathlib.Path(__file__).resolve()), *sys.argv[1:]])
    rc = ctypes.windll.shell32.ShellExecuteW(
        None, "runas", sys.executable, params, str(pathlib.Path.cwd()), 1
    )
    if int(rc) <= 32:
        raise RuntimeError("UAC elevation was not granted.")
    log("RECOVERY // elevated repair launched; this unelevated copy is exiting")
    return True

def download(url: str) -> bytes:
    req = urllib.request.Request(
        url + ("&" if "?" in url else "?") + "v=" + VERSION,
        headers={"Cache-Control":"no-cache","Pragma":"no-cache","User-Agent":"Clintware-QQ-Recovery/" + VERSION},
    )
    with urllib.request.urlopen(req, timeout=30) as response:
        return response.read()

def atomic_write(path: pathlib.Path, data: bytes) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    fd, tmp = tempfile.mkstemp(prefix=path.name + ".", suffix=".new", dir=str(path.parent))
    try:
        with os.fdopen(fd, "wb") as handle:
            handle.write(data)
            handle.flush()
            os.fsync(handle.fileno())
        os.replace(tmp, path)
    finally:
        try:
            os.unlink(tmp)
        except FileNotFoundError:
            pass

def ps_exe() -> pathlib.Path:
    windir = pathlib.Path(os.environ.get("SystemRoot", r"C:\Windows"))
    path = windir / "System32" / "WindowsPowerShell" / "v1.0" / "powershell.exe"
    if not path.is_file():
        raise RuntimeError("Absolute Windows PowerShell executable was not found: " + str(path))
    return path

def powershell(script: str, timeout=45):
    return run([
        str(ps_exe()),
        "-NoProfile",
        "-NonInteractive",
        "-ExecutionPolicy", "Bypass",
        "-Command", script,
    ], timeout=timeout)

def stop_loop(home: pathlib.Path) -> None:
    log("RECOVERY // HARD STOP: disabling watchdog + managed task before repair")
    run(["sc.exe","stop",SERVICE], timeout=20)
    run(["sc.exe","config",SERVICE,"start=","disabled"], timeout=20)
    run(["schtasks.exe","/Change","/TN",TASK,"/DISABLE"], timeout=20)
    run(["schtasks.exe","/End","/TN",TASK], timeout=20)

    # Kill only qq-owned Windows Terminal / PowerShell processes. Do not kill the
    # user's unrelated shells.
    h = str(home).replace("'", "''")
    script = (
        "$me=$PID;"
        "Get-CimInstance Win32_Process | Where-Object {"
        "$_.ProcessId -ne $me -and ("
        "([string]$_.CommandLine -match '(?i)Quillgeist|Clintware\\\\QuillgeistLite|launcher\\.ps1|runner\\.ps1')"
        ") -and ($_.Name -match '(?i)WindowsTerminal|powershell|pwsh|wt')"
        "} | ForEach-Object {"
        "try { Stop-Process -Id $_.ProcessId -Force -ErrorAction Stop } catch {}"
        "};"
        # Disable stale scheduled tasks that launch a Quillgeist Terminal profile.
        "Get-ScheduledTask -ErrorAction SilentlyContinue | Where-Object {"
        "$_.TaskName -ne '" + TASK.replace("'", "''") + "' -and "
        "(($_.Actions | ForEach-Object {[string]$_.Execute+' '+[string]$_.Arguments}) -join ' ') -match '(?i)Quillgeist.*(wt|WindowsTerminal)|(wt|WindowsTerminal).*Quillgeist'"
        "} | ForEach-Object { try { Disable-ScheduledTask -TaskName $_.TaskName -TaskPath $_.TaskPath -ErrorAction Stop | Out-Null } catch {} }"
    )
    powershell(script, timeout=45)

def remove_terminal_sources(home: pathlib.Path) -> None:
    local = pathlib.Path(os.environ["LOCALAPPDATA"])
    fragment_dir = local / "Microsoft" / "Windows Terminal" / "Fragments" / "Clintware"
    fragment_dir.mkdir(parents=True, exist_ok=True)

    for name in ("quillgeist-lite.json","quillgeist-lite-v2.json"):
        p = fragment_dir / name
        if p.exists():
            backup = fragment_dir / (name + ".disabled")
            try:
                if backup.exists():
                    backup.unlink()
                p.replace(backup)
                log("RECOVERY // disabled Windows Terminal fragment " + name)
            except Exception:
                try:
                    p.unlink()
                except Exception:
                    pass

    for marker in ("terminal-repair.ok",):
        try:
            (home / marker).unlink()
        except FileNotFoundError:
            pass

    # Remove startup shortcuts created by old styling code.
    script = (
        "$paths=@("
        "[Environment]::GetFolderPath('Startup'),"
        "[Environment]::GetFolderPath('CommonStartup')"
        ");"
        "foreach($d in $paths){"
        "$p=Join-Path $d 'CodeFEDDY qq.lnk';"
        "Remove-Item $p -Force -ErrorAction SilentlyContinue"
        "}"
    )
    powershell(script)

def refresh_files(home: pathlib.Path) -> None:
    specs = [
        ("launcher.ps1", "/launcher.ps1", b"Reliability-first boot path"),
        ("runner.ps1", "/runner.ps1", b"Show-QuillgeistSplash"),
        ("boot_splash.py", "/tools/boot_splash.py", b"retro DOS boot splash"),
        ("terminal_repair.py", "/tools/terminal_repair.py", b"generate_boot_image"),
    ]

    for local_name, remote, required in specs:
        data = download(RAW + remote)
        if len(data) < 800 or required not in data:
            raise RuntimeError(f"{local_name} download failed structural validation")
        atomic_write(home / local_name, data)
        log("RECOVERY // refreshed " + local_name)

def rewrite_task(home: pathlib.Path) -> None:
    psex = ps_exe()
    launcher = home / "launcher.ps1"
    user = os.environ.get("USERDOMAIN","") + "\\" + os.environ.get("USERNAME","")
    user = user.strip("\\")
    if not user:
        raise RuntimeError("Could not resolve the interactive Windows user.")

    # Typed ScheduledTasks APIs avoid schtasks.exe command-line quoting bugs.
    def q(s: str) -> str:
        return s.replace("'", "''")

    task_script = (
        "$ErrorActionPreference='Stop';"
        "$taskName='" + q(TASK) + "';"
        "$home='" + q(str(home)) + "';"
        "$exe='" + q(str(psex)) + "';"
        "$launcher='" + q(str(launcher)) + "';"
        "$user='" + q(user) + "';"
        "$args='-NoProfile -ExecutionPolicy Bypass -NoExit -File \"' + $launcher + '\"';"
        "$action=New-ScheduledTaskAction -Execute $exe -Argument $args -WorkingDirectory $home;"
        "$task=Get-ScheduledTask -TaskName $taskName -ErrorAction SilentlyContinue;"
        "if($task){"
        "Set-ScheduledTask -TaskName $taskName -Action $action | Out-Null;"
        "}else{"
        "$trigger=New-ScheduledTaskTrigger -AtLogOn -User $user;"
        "$principal=New-ScheduledTaskPrincipal -UserId $user -LogonType Interactive -RunLevel Highest;"
        "$settings=New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -StartWhenAvailable -ExecutionTimeLimit ([TimeSpan]::Zero);"
        "Register-ScheduledTask -TaskName $taskName -Action $action -Trigger $trigger -Principal $principal -Settings $settings "
        "-Description 'CodeFEDDY qq reliable fallback console. Windows Terminal is not in the automatic lifecycle path.' | Out-Null;"
        "};"
        "Enable-ScheduledTask -TaskName $taskName | Out-Null;"
        "$t=Get-ScheduledTask -TaskName $taskName;"
        "$a=$t.Actions | Select-Object -First 1;"
        "if([string]$a.Execute -ne $exe){throw 'task executable verification failed'};"
        "if(([string]$a.Arguments) -notmatch 'launcher\\.ps1'){throw 'task launcher verification failed'};"
        "Write-Output ('TASK_OK '+[string]$a.Execute+' '+[string]$a.Arguments)"
    )
    result = powershell(task_script, timeout=45)
    if result.returncode != 0 or "TASK_OK" not in result.stdout:
        raise RuntimeError("managed task rewrite failed: " + (result.stdout + result.stderr).strip())
    log("VERIFY // task action rewritten to absolute PowerShell launcher")

def pid_alive(pid: int) -> bool:
    if pid <= 0:
        return False
    r = run(["tasklist.exe","/FI",f"PID eq {pid}","/FO","CSV","/NH"], timeout=10)
    return r.returncode == 0 and f'"{pid}"' in r.stdout

def restart_and_verify(home: pathlib.Path) -> None:
    pidfile = home / "runner.pid"
    try:
        pidfile.unlink()
    except FileNotFoundError:
        pass

    run(["sc.exe","config",SERVICE,"start=","auto"], timeout=20)
    start = run(["sc.exe","start",SERVICE], timeout=20)
    if start.returncode != 0:
        combined = (start.stdout + start.stderr).lower()
        if "already been started" not in combined and "already running" not in combined:
            log("WARN // watchdog service start returned: " + (start.stdout + start.stderr).strip())

    task_start = run(["schtasks.exe","/Run","/TN",TASK], timeout=20)
    if task_start.returncode != 0:
        raise RuntimeError("managed qq task failed to start: " + (task_start.stdout + task_start.stderr).strip())

    deadline = time.time() + 20
    live_pid = 0
    while time.time() < deadline:
        try:
            candidate = int(pidfile.read_text(encoding="ascii").strip())
            if pid_alive(candidate):
                live_pid = candidate
                break
        except Exception:
            pass
        time.sleep(0.5)

    if not live_pid:
        crash = home / "runner-crash.log"
        tail = ""
        try:
            lines = crash.read_text(encoding="utf-8", errors="replace").splitlines()
            tail = "\n".join(lines[-20:])
        except Exception:
            pass
        raise RuntimeError("runner did not become live within 20 seconds" + (("\n" + tail) if tail else ""))

    log("VERIFY // live runner PID " + str(live_pid))

def main() -> int:
    if os.name != "nt":
        raise RuntimeError("Quillgeist Lite emergency recovery is Windows-only.")

    if elevate_self():
        return 0

    local = pathlib.Path(os.environ["LOCALAPPDATA"])
    home = local / "Clintware" / "QuillgeistLite"
    home.mkdir(parents=True, exist_ok=True)

    log("RECOVERY // Quillgeist Lite " + VERSION)
    stop_loop(home)
    remove_terminal_sources(home)
    refresh_files(home)
    rewrite_task(home)
    restart_and_verify(home)

    log("VERIFY // Windows Terminal removed from automatic qq lifecycle")
    log("VERIFY // old Terminal fragments/startup launchers disabled")
    log("VERIFY // managed task uses absolute PowerShell path")
    log("VERIFY // Python retro DOS splash installed")
    log("READY // restart loop eliminated; qq is running in safe host mode")
    return 0

if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except Exception as exc:
        print("ERROR // " + str(exc), file=sys.stderr, flush=True)
        raise SystemExit(1)

