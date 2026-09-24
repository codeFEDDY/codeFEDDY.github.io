#!/usr/bin/env python3
"""
Quillgeist Lite terminal self-repair.

Pure Python / standard library only. It owns the error-prone Windows Terminal JSON,
creates the deterministic retro DOS boot image, refreshes the managed launcher, and
verifies the resulting profile before returning success.
"""

from __future__ import annotations

import argparse
import binascii
import json
import math
import os
import pathlib
import shutil
import struct
import subprocess
import sys
import tempfile
import urllib.request
import uuid
import zlib

VERSION = "2026.09.24.5"
PROFILE_GUID = "{4a4b4fda-d945-42f1-a682-46c7534c2c5a}"
PROFILE_NAME = "Quillgeist Lite"
LEGACY_PROFILE_GUID = "{5c7d2c59-4989-4f24-9f07-cbd0a38acb6d}"
RAW_BASE = "https://raw.githubusercontent.com/codeFEDDY/codeFEDDY.github.io/main/quillgeist-lite"
LAUNCHER_URL = RAW_BASE + "/launcher.ps1?v=" + VERSION

FONT = {
    "A": ["01110","10001","10001","11111","10001","10001","10001"],
    "B": ["11110","10001","10001","11110","10001","10001","11110"],
    "C": ["01111","10000","10000","10000","10000","10000","01111"],
    "D": ["11110","10001","10001","10001","10001","10001","11110"],
    "E": ["11111","10000","10000","11110","10000","10000","11111"],
    "F": ["11111","10000","10000","11110","10000","10000","10000"],
    "G": ["01111","10000","10000","10111","10001","10001","01111"],
    "H": ["10001","10001","10001","11111","10001","10001","10001"],
    "I": ["11111","00100","00100","00100","00100","00100","11111"],
    "J": ["00111","00010","00010","00010","10010","10010","01100"],
    "K": ["10001","10010","10100","11000","10100","10010","10001"],
    "L": ["10000","10000","10000","10000","10000","10000","11111"],
    "M": ["10001","11011","10101","10101","10001","10001","10001"],
    "N": ["10001","11001","10101","10011","10001","10001","10001"],
    "O": ["01110","10001","10001","10001","10001","10001","01110"],
    "P": ["11110","10001","10001","11110","10000","10000","10000"],
    "Q": ["01110","10001","10001","10001","10101","10010","01101"],
    "R": ["11110","10001","10001","11110","10100","10010","10001"],
    "S": ["01111","10000","10000","01110","00001","00001","11110"],
    "T": ["11111","00100","00100","00100","00100","00100","00100"],
    "U": ["10001","10001","10001","10001","10001","10001","01110"],
    "V": ["10001","10001","10001","10001","10001","01010","00100"],
    "W": ["10001","10001","10001","10101","10101","10101","01010"],
    "X": ["10001","10001","01010","00100","01010","10001","10001"],
    "Y": ["10001","10001","01010","00100","00100","00100","00100"],
    "Z": ["11111","00001","00010","00100","01000","10000","11111"],
    "0": ["01110","10001","10011","10101","11001","10001","01110"],
    "1": ["00100","01100","00100","00100","00100","00100","01110"],
    "2": ["01110","10001","00001","00010","00100","01000","11111"],
    "3": ["11110","00001","00001","01110","00001","00001","11110"],
    "4": ["00010","00110","01010","10010","11111","00010","00010"],
    "5": ["11111","10000","10000","11110","00001","00001","11110"],
    "6": ["01110","10000","10000","11110","10001","10001","01110"],
    "7": ["11111","00001","00010","00100","01000","01000","01000"],
    "8": ["01110","10001","10001","01110","10001","10001","01110"],
    "9": ["01110","10001","10001","01111","00001","00001","01110"],
    ".": ["00000","00000","00000","00000","00000","00110","00110"],
    "-": ["00000","00000","00000","11111","00000","00000","00000"],
    " ": ["00000","00000","00000","00000","00000","00000","00000"],
}

def log(message: str) -> None:
    print(message, flush=True)

def env_path(name: str) -> pathlib.Path:
    value = os.environ.get(name)
    if not value:
        raise RuntimeError(f"Required environment variable {name} is missing.")
    return pathlib.Path(value)

def atomic_write_bytes(path: pathlib.Path, data: bytes) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    fd, tmp_name = tempfile.mkstemp(prefix=path.name + ".", suffix=".new", dir=str(path.parent))
    try:
        with os.fdopen(fd, "wb") as handle:
            handle.write(data)
            handle.flush()
            os.fsync(handle.fileno())
        os.replace(tmp_name, path)
    finally:
        try:
            os.unlink(tmp_name)
        except FileNotFoundError:
            pass

def atomic_write_text(path: pathlib.Path, text: str) -> None:
    atomic_write_bytes(path, text.encode("utf-8"))

def download_text(url: str) -> str:
    request = urllib.request.Request(
        url,
        headers={"Cache-Control": "no-cache", "User-Agent": "Clintware-Quillgeist-Lite/" + VERSION},
    )
    with urllib.request.urlopen(request, timeout=25) as response:
        data = response.read()
    return data.decode("utf-8-sig")

def refresh_launcher(launcher_path: pathlib.Path) -> None:
    try:
        text = download_text(LAUNCHER_URL)
        if len(text) < 800 or "QuillgeistLite" not in text or "$ErrorActionPreference" not in text:
            raise RuntimeError("downloaded launcher failed structural validation")
        atomic_write_text(launcher_path, text)
        log("PYTHON // launcher refreshed atomically")
    except Exception as exc:
        if launcher_path.exists() and launcher_path.stat().st_size > 800:
            log(f"WARN // launcher refresh unavailable; keeping validated local copy: {exc}")
            return
        raise

def set_pixel(buf: bytearray, width: int, height: int, x: int, y: int, color: tuple[int,int,int]) -> None:
    if x < 0 or y < 0 or x >= width or y >= height:
        return
    idx = (y * width + x) * 3
    buf[idx:idx+3] = bytes(color)

def rect(buf: bytearray, width: int, height: int, x: int, y: int, w: int, h: int, color: tuple[int,int,int]) -> None:
    x0 = max(0, x)
    y0 = max(0, y)
    x1 = min(width, x + w)
    y1 = min(height, y + h)
    if x0 >= x1 or y0 >= y1:
        return
    row = bytes(color) * (x1 - x0)
    for yy in range(y0, y1):
        idx = (yy * width + x0) * 3
        buf[idx:idx + len(row)] = row

def draw_text(buf: bytearray, width: int, height: int, text: str, x: int, y: int, scale: int, color: tuple[int,int,int], glow: bool = False) -> None:
    cursor = x
    spacing = scale
    if glow:
        glow_color = (18, 91, 148)
        for char in text.upper():
            glyph = FONT.get(char, FONT[" "])
            for gy, row in enumerate(glyph):
                for gx, bit in enumerate(row):
                    if bit == "1":
                        rect(buf, width, height, cursor + gx*scale - max(1,scale//5), y + gy*scale - max(1,scale//5), scale + max(2,scale//3), scale + max(2,scale//3), glow_color)
            cursor += 5*scale + spacing
        cursor = x

    for char in text.upper():
        glyph = FONT.get(char, FONT[" "])
        for gy, row in enumerate(glyph):
            for gx, bit in enumerate(row):
                if bit == "1":
                    rect(buf, width, height, cursor + gx*scale, y + gy*scale, max(1,scale-1), max(1,scale-1), color)
        cursor += 5*scale + spacing

def text_width(text: str, scale: int) -> int:
    if not text:
        return 0
    return len(text) * 5 * scale + (len(text)-1) * scale

def png_chunk(kind: bytes, payload: bytes) -> bytes:
    return struct.pack(">I", len(payload)) + kind + payload + struct.pack(">I", binascii.crc32(kind + payload) & 0xFFFFFFFF)

def encode_png_rgb(width: int, height: int, rgb: bytes) -> bytes:
    stride = width * 3
    raw = bytearray()
    for y in range(height):
        raw.append(0)
        raw.extend(rgb[y*stride:(y+1)*stride])
    return (
        b"\x89PNG\r\n\x1a\n"
        + png_chunk(b"IHDR", struct.pack(">IIBBBBB", width, height, 8, 2, 0, 0, 0))
        + png_chunk(b"IDAT", zlib.compress(bytes(raw), 9))
        + png_chunk(b"IEND", b"")
    )

def generate_boot_image(path: pathlib.Path) -> None:
    width, height = 1280, 900
    buf = bytearray(width * height * 3)
    cx, cy = width // 2, 410
    radius = 310

    # Faint CRT scan lines.
    for y in range(0, height, 4):
        rect(buf, width, height, 0, y, width, 1, (0, 5, 9))

    # Deterministic pixel/ASCII-style eclipse halo inspired by the supplied
    # blue/white Clintware DOS artwork.
    for ring in range(-34, 35, 7):
        r = radius + ring
        for step in range(720):
            angle = (step / 720.0) * math.tau
            # Regularly omit cells to keep the 1970s/80s digital halftone feel.
            gate = (step * 37 + ring * 13) % 17
            if gate in (0, 1, 2):
                continue
            x = int(cx + math.cos(angle) * r)
            y = int(cy + math.sin(angle) * r * 0.92)
            intensity = max(80, 245 - abs(ring) * 4)
            blue = min(255, intensity + 10)
            color = (0, min(190, intensity // 2 + 45), blue)
            size = 2 if abs(ring) > 20 else 3
            rect(buf, width, height, x, y, size, size, color)

    # Bright inner and outer rim.
    for ring, color in ((-4, (50, 205, 255)), (5, (0, 126, 255))):
        r = radius + ring
        for step in range(900):
            angle = (step / 900.0) * math.tau
            x = int(cx + math.cos(angle) * r)
            y = int(cy + math.sin(angle) * r * 0.92)
            rect(buf, width, height, x, y, 3, 3, color)

    logo = "CLINTWARE"
    scale = 18
    lx = (width - text_width(logo, scale)) // 2
    ly = 345
    draw_text(buf, width, height, logo, lx, ly, scale, (245, 248, 250), glow=True)

    tm_scale = 5
    draw_text(buf, width, height, "TM", min(width-95, lx + text_width(logo, scale) + 8), ly + 3, tm_scale, (245, 248, 250))

    est = "EST. 2026"
    est_scale = 8
    ex = (width - text_width(est, est_scale)) // 2
    draw_text(buf, width, height, est, ex, 565, est_scale, (230, 242, 255), glow=True)

    q = "QUILLGEIST LITE"
    q_scale = 5
    qx = (width - text_width(q, q_scale)) // 2
    draw_text(buf, width, height, q, qx, 665, q_scale, (61, 191, 255))

    atomic_write_bytes(path, encode_png_rgb(width, height, bytes(buf)))

def resolve_powershell() -> pathlib.Path:
    windir = pathlib.Path(os.environ.get("SystemRoot", r"C:\Windows"))
    candidates = [
        windir / "System32" / "WindowsPowerShell" / "v1.0" / "powershell.exe",
        pathlib.Path(shutil.which("powershell.exe") or ""),
        pathlib.Path(shutil.which("powershell") or ""),
    ]
    for candidate in candidates:
        if str(candidate) and candidate.is_file():
            return candidate
    raise RuntimeError("Windows PowerShell executable could not be resolved.")

def build_boot_command(ps_exe: pathlib.Path, launcher_path: pathlib.Path) -> str:
    # Keep the Windows Terminal command line intentionally boring. The scheduled
    # task is the recovery layer; the profile only launches an absolute, verified
    # executable and absolute launcher path. This avoids nested -Command quoting
    # and PATH/AppExecutionAlias failures that surface as 0x80070002.
    return subprocess.list2cmdline([
        str(ps_exe),
        "-NoProfile",
        "-ExecutionPolicy", "Bypass",
        "-NoExit",
        "-File", str(launcher_path),
        "-TerminalHost",
    ])

def write_fragment(fragment_path: pathlib.Path, home: pathlib.Path, image_path: pathlib.Path, commandline: str) -> None:
    fragment = {
        "profiles": [{
            "guid": PROFILE_GUID,
            "name": PROFILE_NAME,
            "commandline": commandline,
            "startingDirectory": str(home),
            "tabTitle": "Quillgeist Lite",
            "suppressApplicationTitle": True,
            "colorScheme": "Clintware Glass",
            "opacity": 92,
            "useAcrylic": True,
            "background": "#000000",
            "foreground": "#EAF7FF",
            "selectionBackground": "#244A66",
            "cursorColor": "#57C7FF",
            "cursorShape": "vintage",
            "cursorHeight": 22,
            "padding": "16, 12, 16, 12",
            "scrollbarState": "hidden",
            "intenseTextStyle": "bright",
            "adjustIndistinguishableColors": "never",
            "backgroundImage": str(image_path),
            "backgroundImageAlignment": "center",
            "backgroundImageOpacity": 0.22,
            "backgroundImageStretchMode": "uniform",
            "experimental.retroTerminalEffect": False,
            "font": {"face": "Cascadia Mono", "size": 11, "weight": "normal"},
            "unfocusedAppearance": {
                "opacity": 92,
                "useAcrylic": True,
                "backgroundImageOpacity": 0.14,
            },
        }],
        "schemes": [{
            "name": "Clintware Glass",
            "background": "#000000",
            "foreground": "#EAF7FF",
            "cursorColor": "#57C7FF",
            "selectionBackground": "#244A66",
            "black": "#05080D",
            "red": "#FF4B4B",
            "green": "#8FE388",
            "yellow": "#FF9F1C",
            "blue": "#168BFF",
            "purple": "#A880FF",
            "cyan": "#35BFFF",
            "white": "#EAF7FF",
            "brightBlack": "#617382",
            "brightRed": "#FF6B6B",
            "brightGreen": "#B5F5AE",
            "brightYellow": "#FFB84D",
            "brightBlue": "#53B7FF",
            "brightPurple": "#C0A7FF",
            "brightCyan": "#78D9FF",
            "brightWhite": "#FFFFFF",
        }],
    }
    payload = json.dumps(fragment, indent=2, ensure_ascii=False) + "\n"
    atomic_write_text(fragment_path, payload)

def verify(fragment_path: pathlib.Path, image_path: pathlib.Path, launcher_path: pathlib.Path, ps_exe: pathlib.Path) -> None:
    if not ps_exe.is_file():
        raise RuntimeError("PowerShell executable verification failed.")
    if not launcher_path.is_file() or launcher_path.stat().st_size < 800:
        raise RuntimeError("Managed launcher verification failed.")
    if not image_path.is_file() or image_path.stat().st_size < 20000:
        raise RuntimeError("Retro boot image verification failed.")
    with image_path.open("rb") as handle:
        if handle.read(8) != b"\x89PNG\r\n\x1a\n":
            raise RuntimeError("Retro boot image is not a valid PNG.")
    with fragment_path.open("r", encoding="utf-8-sig") as handle:
        fragment = json.load(handle)
    profile = fragment["profiles"][0]
    if profile.get("guid") != PROFILE_GUID:
        raise RuntimeError("Terminal profile GUID verification failed.")
    if str(ps_exe).lower() not in profile.get("commandline", "").lower():
        raise RuntimeError("Terminal commandline does not use the absolute PowerShell path.")
    if "launcher.ps1" not in profile.get("commandline", ""):
        raise RuntimeError("Terminal commandline does not contain launcher self-recovery.")
    if pathlib.Path(profile.get("backgroundImage", "")) != image_path:
        raise RuntimeError("Terminal boot image binding verification failed.")

def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--verify-only", action="store_true")
    args = parser.parse_args()

    if os.name != "nt":
        raise RuntimeError("Quillgeist Lite terminal repair is Windows-only.")

    local = env_path("LOCALAPPDATA")
    home = local / "Clintware" / "QuillgeistLite"
    fragment_dir = local / "Microsoft" / "Windows Terminal" / "Fragments" / "Clintware"
    fragment_path = fragment_dir / "quillgeist-lite-v2.json"
    legacy_fragment = fragment_dir / "quillgeist-lite.json"
    image_path = fragment_dir / "clintware-boot-70s-dos.png"
    launcher_path = home / "launcher.ps1"
    marker = home / "terminal-repair.ok"

    ps_exe = resolve_powershell()

    if not args.verify_only:
        home.mkdir(parents=True, exist_ok=True)
        fragment_dir.mkdir(parents=True, exist_ok=True)

        log(f"PYTHON // terminal self-repair {VERSION}")
        refresh_launcher(launcher_path)
        generate_boot_image(image_path)
        log("PYTHON // deterministic 70s/DOS boot image generated")
        commandline = build_boot_command(ps_exe, launcher_path)
        write_fragment(fragment_path, home, image_path, commandline)
        log("PYTHON // Windows Terminal profile written atomically")

        # Remove the previous fragment so a stale broken command line cannot win
        # profile resolution. The v2 profile also uses a new GUID to avoid any
        # old per-profile overrides cached against the legacy GUID.
        try:
            legacy_fragment.unlink()
            log("PYTHON // legacy terminal fragment removed")
        except FileNotFoundError:
            pass

    verify(fragment_path, image_path, launcher_path, ps_exe)
    atomic_write_text(marker, VERSION + "\n")

    log("VERIFY // PowerShell absolute path: " + str(ps_exe))
    log("VERIFY // profile GUID: " + PROFILE_GUID)
    log("VERIFY // fragment: " + str(fragment_path))
    log("VERIFY // boot image: " + str(image_path))
    log("READY // Quillgeist Lite terminal profile self-test passed")
    return 0

if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except Exception as exc:
        print("ERROR // terminal self-repair failed: " + str(exc), file=sys.stderr, flush=True)
        raise SystemExit(1)

