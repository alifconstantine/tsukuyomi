#!/usr/bin/env python3
"""Windows PE metadata, icon extraction, and Shell Link (.lnk) parser."""

from __future__ import annotations

import re
import shutil
import struct
import tempfile
from pathlib import Path
from typing import Optional

from compat_common import run_cmd, sanitize_desktop_value


def split_windows_args(command_line: str) -> list[str]:
    """Parse the argument string from a Windows shortcut."""
    tokens = re.findall(r'[ \t]+|\\*"|[^ \t"\\]+|\\+', command_line)
    argv: list[str] = []
    parts: list[str] = []
    quoted = False
    index = 0
    while index < len(tokens):
        token = tokens[index]
        if token.endswith('"'):
            slashes = len(token) - 1
            parts.append("\\" * (slashes // 2))
            if slashes % 2:
                parts.append('"')
            elif quoted and index + 1 < len(tokens) and tokens[index + 1] == '"':
                parts.append('"')
                index += 1
            else:
                quoted = not quoted
        elif not quoted and not token.strip():
            if parts:
                argv.append("".join(parts))
                parts.clear()
        else:
            parts.append(token)
        index += 1
    if parts:
        argv.append("".join(parts))
    return argv


def inspect_pe(exe_path: Path) -> dict[str, object]:
    """Extract PE architecture, version metadata, and installer hint cleanly."""
    suffix = exe_path.suffix.lower()
    info: dict[str, object] = {
        "path": str(exe_path),
        "filename": exe_path.name,
        "kind": "msi" if suffix == ".msi" else ("lnk" if suffix == ".lnk" else "exe"),
        "arch": "unknown",
        "product_name": exe_path.stem,
        "description": "",
        "company": "",
        "version": "",
        "installer_hint": "msi" if suffix == ".msi" else "unknown",
        "nsis_archive": False,
    }

    if suffix == ".lnk":
        parsed = parse_lnk(exe_path)
        if parsed:
            info["target"] = parsed.get("target", "")
            info["arguments"] = parsed.get("arguments", "")
            info["product_name"] = parsed.get("description") or exe_path.stem
        else:
            info["error"] = "This file is not a readable Windows shortcut."
        return info

    try:
        with exe_path.open("rb") as file:
            if suffix == ".msi":
                if file.read(8) != bytes.fromhex("d0cf11e0a1b11ae1"):
                    info["error"] = "This file is not a Windows Installer package. Download the MSI again."
                return info
            header = file.read(64)
            if len(header) != 64 or header[:2] != b"MZ":
                raise ValueError
            file.seek(struct.unpack_from("<I", header, 60)[0])
            pe_header = file.read(6)
            if len(pe_header) != 6 or pe_header[:4] != b"PE\x00\x00":
                raise ValueError
            machine = struct.unpack_from("<H", pe_header, 4)[0]
            # NSIS scans 512-byte boundaries for its firstheader. The installer
            # stub is small even when the compressed application is hundreds of MB.
            file.seek(0)
            stub = file.read(1024 * 1024)
            signature = b"\xef\xbe\xad\xdeNullsoftInst"
            info["nsis_archive"] = any(
                stub.startswith(signature, offset + 4) for offset in range(512, len(stub), 512)
            )
    except (OSError, ValueError):
        info["error"] = "This file is not a readable x86 or x64 Windows executable."
        return info
    info["arch"] = {
        0x014C: "x86", 0x8664: "x86_64", 0xAA64: "arm64", 0xA641: "arm64", 0xA64E: "arm64",
    }.get(machine, "unknown")

    try:
        import pefile  # type: ignore

        pe = pefile.PE(str(exe_path), fast_load=True)
        pe.parse_data_directories(
            directories=[pefile.DIRECTORY_ENTRY["IMAGE_DIRECTORY_ENTRY_RESOURCE"]]
        )
        meta: dict[str, str] = {}
        if hasattr(pe, "FileInfo"):
            for entry in pe.FileInfo:
                for sub in entry:
                    if hasattr(sub, "StringTable"):
                        for st in sub.StringTable:
                            for k, v in st.entries.items():
                                ks = k.decode("utf-8", errors="ignore") if isinstance(k, bytes) else str(k)
                                vs = v.decode("utf-8", errors="ignore") if isinstance(v, bytes) else str(v)
                                meta[ks] = sanitize_desktop_value(vs)

        prod = meta.get("ProductName") or meta.get("FileDescription") or exe_path.stem
        info["product_name"] = prod or exe_path.stem
        info["description"] = meta.get("FileDescription", "")
        info["company"] = meta.get("CompanyName", "")
        info["version"] = meta.get("ProductVersion") or meta.get("FileVersion") or ""

        lower_all = " ".join([exe_path.name, info["description"], info["company"]]).lower()
        if "inno" in lower_all:
            info["installer_hint"] = "inno"
        elif info["nsis_archive"] or "nullsoft" in lower_all or "nsis" in lower_all:
            info["installer_hint"] = "nsis"
        elif any(tok in lower_all for tok in ("setup", "install", "installer")):
            info["installer_hint"] = "setup"
        else:
            info["installer_hint"] = "app"
        pe.close()
    except Exception:
        pass

    return info


def extract_exe_icon_png(exe_path: Path, out_png: Path) -> bool:
    """Extract the highest-resolution icon from a Windows PE binary as PNG."""
    if not exe_path.is_file() or exe_path.suffix.lower() not in (".exe", ".dll"):
        return False
    if not shutil.which("wrestool") or not shutil.which("icotool"):
        return False

    with tempfile.TemporaryDirectory(prefix="tsukuyomi-ico-") as tmp:
        tmp_dir = Path(tmp)
        res = run_cmd(["wrestool", "-x", "-t", "14", f"--output={tmp_dir}", str(exe_path)], timeout=10)
        if res.returncode != 0:
            return False
        icos = sorted(tmp_dir.glob("*.ico"))
        if not icos:
            return False

        # Pick the first/main icon group resource.
        res_ico = run_cmd(["icotool", "-x", "-o", str(tmp_dir), str(icos[0])], timeout=10)
        if res_ico.returncode != 0:
            return False

        pngs = list(tmp_dir.glob("*.png"))
        if not pngs:
            return False

        def png_score(p: Path) -> tuple[int, int]:
            # icotool writes filenames like name_1_256x256x32.png
            parts = p.stem.split("_")
            dim = 0
            bpp = 0
            for part in parts:
                if "x" in part:
                    dims = part.split("x")
                    if dims[0].isdigit():
                        dim = int(dims[0])
                    if len(dims) >= 3 and dims[2].isdigit():
                        bpp = int(dims[2])
            return (dim if dim <= 256 else 256, bpp)

        best = max(pngs, key=png_score)
        out_png.parent.mkdir(parents=True, exist_ok=True)
        shutil.copyfile(best, out_png)
        return out_png.is_file() and out_png.stat().st_size > 0


def _read_u16(data: bytes, offset: int) -> int:
    return struct.unpack_from("<H", data, offset)[0]


def _read_u32(data: bytes, offset: int) -> int:
    return struct.unpack_from("<I", data, offset)[0]


def _read_cstr(data: bytes, offset: int, unicode: bool = False) -> str:
    if offset < 0 or offset >= len(data):
        return ""
    if unicode:
        end = offset
        while end + 1 < len(data) and data[end : end + 2] != b"\x00\x00":
            end += 2
        return data[offset:end].decode("utf-16-le", errors="ignore")
    end = data.find(b"\x00", offset)
    if end == -1:
        end = len(data)
    return data[offset:end].decode("cp1252", errors="ignore")


def parse_lnk(lnk_path: Path) -> Optional[dict[str, str]]:
    """Parse a Microsoft Shell Link (.lnk) binary into target path, args, and icon."""
    try:
        with lnk_path.open("rb") as file:
            data = file.read(1024 * 1024 + 1)
    except OSError:
        return None

    if not 76 <= len(data) <= 1024 * 1024:
        return None
    header_size = _read_u32(data, 0)
    if header_size != 0x4C:
        return None
    clsid = data[4:20]
    if clsid != bytes.fromhex("0114020000000000c000000000000046"):
        return None

    flags = _read_u32(data, 20)
    has_id_list = bool(flags & 0x01)
    has_link_info = bool(flags & 0x02)
    has_name = bool(flags & 0x04)
    has_rel_path = bool(flags & 0x08)
    has_work_dir = bool(flags & 0x10)
    has_args = bool(flags & 0x20)
    has_icon_loc = bool(flags & 0x40)
    is_unicode = bool(flags & 0x80)

    pos = 76
    if has_id_list:
        if pos + 2 > len(data):
            return None
        id_list_size = _read_u16(data, pos)
        pos += 2 + id_list_size

    target = ""
    if has_link_info:
        if pos + 4 > len(data):
            return None
        link_info_size = _read_u32(data, pos)
        if pos + link_info_size > len(data) or link_info_size < 28:
            return None
        link_info_header_size = _read_u32(data, pos + 4)
        link_info_flags = _read_u32(data, pos + 8)
        if link_info_flags & 0x01:
            local_base_off = _read_u32(data, pos + 16)
            common_suffix_off = _read_u32(data, pos + 24)
            if link_info_header_size >= 0x24 and pos + 36 <= len(data):
                uni_base_off = _read_u32(data, pos + 28)
                uni_suffix_off = _read_u32(data, pos + 32)
                base_u = _read_cstr(data, pos + uni_base_off, unicode=True) if uni_base_off else ""
                suf_u = _read_cstr(data, pos + uni_suffix_off, unicode=True) if uni_suffix_off else ""
                target = base_u + suf_u
            if not target and local_base_off:
                base_a = _read_cstr(data, pos + local_base_off, unicode=False)
                suf_a = _read_cstr(data, pos + common_suffix_off, unicode=False) if common_suffix_off else ""
                target = base_a + suf_a
        pos += link_info_size

    def read_string_data() -> str:
        nonlocal pos
        if pos + 2 > len(data):
            return ""
        count = _read_u16(data, pos)
        pos += 2
        byte_len = count * (2 if is_unicode else 1)
        raw = data[pos : pos + byte_len]
        pos += byte_len
        return raw.decode("utf-16-le" if is_unicode else "cp1252", errors="ignore")

    description = read_string_data() if has_name else ""
    rel_path = read_string_data() if has_rel_path else ""
    working_dir = read_string_data() if has_work_dir else ""
    arguments = read_string_data() if has_args else ""
    icon_location = read_string_data() if has_icon_loc else ""

    if not target and rel_path:
        target = rel_path

    return {
        "target": sanitize_desktop_value(target),
        "description": sanitize_desktop_value(description),
        "working_dir": sanitize_desktop_value(working_dir),
        "relative_path": sanitize_desktop_value(rel_path),
        "arguments": sanitize_desktop_value(arguments),
        "icon_location": sanitize_desktop_value(icon_location),
    }
