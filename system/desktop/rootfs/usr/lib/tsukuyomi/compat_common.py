#!/usr/bin/env python3
"""Shared security, validation, atomic I/O, and desktop integration helpers."""

from __future__ import annotations

import json
import os
import re
import shutil
import stat
import subprocess
import tempfile
import zipfile
from pathlib import Path
from typing import Iterable, Optional

SLUG_RE = re.compile(r"^[a-z0-9][a-z0-9-]{0,63}$")
ANDROID_PKG_RE = re.compile(r"^[A-Za-z][A-Za-z0-9_]*(\.[A-Za-z0-9_]+)+$")
CONTROL_CHARS_RE = re.compile(r"[\x00-\x1f\x7f]")


def xdg_data_home() -> Path:
    return Path(os.environ.get("XDG_DATA_HOME") or (Path.home() / ".local" / "share"))


def xdg_config_home() -> Path:
    return Path(os.environ.get("XDG_CONFIG_HOME") or (Path.home() / ".config"))


def xdg_runtime_dir() -> Path:
    return Path(os.environ.get("XDG_RUNTIME_DIR") or f"/run/user/{os.getuid()}")


def slugify(raw: str, fallback: str = "app") -> str:
    cleaned = re.sub(r"[^a-z0-9]+", "-", (raw or "").lower()).strip("-")
    cleaned = cleaned[:64].strip("-")
    if not cleaned or not SLUG_RE.match(cleaned):
        return fallback
    return cleaned


def validate_slug(slug: str) -> str:
    if not SLUG_RE.match(slug or ""):
        raise ValueError(f"Invalid app slug: {slug!r}")
    return slug


def validate_android_pkg(pkg: str) -> str:
    if not ANDROID_PKG_RE.match(pkg or "") or len(pkg) > 192:
        raise ValueError(f"Invalid Android package ID: {pkg!r}")
    return pkg


def sanitize_desktop_value(value: str, fallback: str = "") -> str:
    cleaned = CONTROL_CHARS_RE.sub(" ", value or "")
    cleaned = re.sub(r"\s+", " ", cleaned).strip()
    return cleaned if cleaned else fallback


def format_desktop_exec(argv: Iterable[str]) -> str:
    """Quote argv cleanly for XDG Desktop Entry Exec= without shell expansion."""
    parts = []
    for arg in argv:
        s = sanitize_desktop_value(str(arg))
        if not s:
            continue
        # Escape desktop field codes and special quoting characters per XDG spec.
        needs_quote = any(c in s for c in (' ', '\t', '\n', '"', "'", '\\', '>', '<', '~', '|', '&', ';', '$', '*', '?', '#', '(', ')', '`'))
        s = s.replace("\\", "\\\\").replace('"', '\\"').replace("$", "\\$").replace("`", "\\`").replace("%", "%%")
        if needs_quote:
            parts.append(f'"{s}"')
        else:
            parts.append(s)
    return " ".join(parts)


def atomic_write_bytes(path: Path, data: bytes, mode: int = 0o644) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    fd, tmp_name = tempfile.mkstemp(dir=str(path.parent), prefix=f".{path.name}.")
    tmp_path = Path(tmp_name)
    try:
        with os.fdopen(fd, "wb") as handle:
            handle.write(data)
            handle.flush()
            os.fsync(handle.fileno())
        os.chmod(tmp_path, mode)
        os.replace(tmp_path, path)
    finally:
        if tmp_path.exists():
            tmp_path.unlink(missing_ok=True)


def atomic_write_text(path: Path, text: str, mode: int = 0o644) -> None:
    atomic_write_bytes(path, text.encode("utf-8"), mode=mode)


def atomic_write_json(path: Path, payload: object, mode: int = 0o644) -> None:
    atomic_write_text(path, json.dumps(payload, indent=2, sort_keys=False) + "\n", mode=mode)


def read_json(path: Path, default: object = None) -> object:
    try:
        return json.loads(path.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError):
        return default


def safe_extract_zip(
    zip_path: Path,
    dest_dir: Path,
    allowed_exts: Optional[set[str]] = None,
    max_total_bytes: int = 4 * 1024 * 1024 * 1024,
) -> list[Path]:
    """Extract ZIP members safely, guarding against Zip Slip, symlinks, and zip bombs."""
    dest_root = os.path.realpath(dest_dir)
    dest_dir.mkdir(parents=True, exist_ok=True)
    extracted: list[Path] = []
    total_written = 0

    with zipfile.ZipFile(zip_path, "r") as zf:
        for info in zf.infolist():
            if info.is_dir():
                continue
            mode = (info.external_attr >> 16) & 0o170000
            if mode == stat.S_IFLNK:
                raise ValueError(f"Refusing symlink inside archive: {info.filename}")

            rel = Path(info.filename)
            if rel.is_absolute() or ".." in rel.parts:
                raise ValueError(f"Refusing unsafe archive path: {info.filename}")

            if allowed_exts is not None and rel.suffix.lower() not in allowed_exts:
                continue

            target = Path(os.path.realpath(os.path.join(dest_root, *rel.parts)))
            if os.path.commonpath([dest_root, str(target)]) != dest_root:
                raise ValueError(f"Archive path escapes destination: {info.filename}")

            if total_written + info.file_size > max_total_bytes:
                raise ValueError("Archive exceeds maximum safe extracted size")

            target.parent.mkdir(parents=True, exist_ok=True)
            with zf.open(info, "r") as src, open(target, "wb") as dst:
                while True:
                    chunk = src.read(1024 * 1024)
                    if not chunk:
                        break
                    total_written += len(chunk)
                    if total_written > max_total_bytes:
                        dst.close()
                        target.unlink(missing_ok=True)
                        raise ValueError("Archive exceeds maximum safe extracted size")
                    dst.write(chunk)
            extracted.append(target)

    return extracted


def run_cmd(
    argv: list[str],
    *,
    env: Optional[dict[str, str]] = None,
    cwd: Optional[Path] = None,
    check: bool = False,
    timeout: Optional[int] = None,
) -> subprocess.CompletedProcess[str]:
    merged_env = os.environ.copy()
    if env:
        merged_env.update(env)
    try:
        return subprocess.run(
            argv,
            env=merged_env,
            cwd=str(cwd) if cwd else None,
            shell=False,
            text=True,
            capture_output=True,
            check=check,
            timeout=timeout,
        )
    except FileNotFoundError:
        return subprocess.CompletedProcess(argv, 127, "", f"Command not found: {argv[0]}")


def detect_hypr_monitor() -> dict[str, object]:
    """Return active/focused monitor geometry and scale from Hyprland if available."""
    fallback = {"width": 1920, "height": 1080, "scale": 1.0}
    if not shutil.which("hyprctl"):
        return fallback
    res = run_cmd(["hyprctl", "monitors", "-j"], timeout=3)
    if res.returncode != 0 or not res.stdout.strip():
        return fallback
    try:
        monitors = json.loads(res.stdout)
        if not isinstance(monitors, list) or not monitors:
            return fallback
        focused = next((m for m in monitors if m.get("focused")), monitors[0])
        return {
            "width": int(focused.get("width") or 1920),
            "height": int(focused.get("height") or 1080),
            "scale": float(focused.get("scale") or 1.0),
        }
    except (ValueError, TypeError, json.JSONDecodeError):
        return fallback


def detect_theme_dark() -> bool:
    shell_cfg = xdg_config_home() / "ryoku" / "shell.json"
    data = read_json(shell_cfg, {})
    if isinstance(data, dict):
        theme = data.get("theme", {})
        if isinstance(theme, dict):
            app = theme.get("appearance", {})
            if isinstance(app, dict) and app.get("mode") in ("dark", "light"):
                return app["mode"] == "dark"
    return True


def refresh_desktop_caches() -> None:
    apps_dir = xdg_data_home() / "applications"
    icons_dir = xdg_data_home() / "icons" / "hicolor"
    if apps_dir.exists() and shutil.which("update-desktop-database"):
        run_cmd(["update-desktop-database", str(apps_dir)], timeout=10)
    if icons_dir.exists() and shutil.which("gtk-update-icon-cache"):
        run_cmd(["gtk-update-icon-cache", "-q", "-t", "-f", str(icons_dir)], timeout=10)
