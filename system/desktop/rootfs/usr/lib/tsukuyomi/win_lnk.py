#!/usr/bin/env python3
"""Windows PE metadata, icon extraction, and Shell Link (.lnk) parser."""

from __future__ import annotations

import shutil
import struct
import tempfile
from pathlib import Path
from typing import Optional

from compat_common import run_cmd, sanitize_desktop_value


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
    }

    if suffix == ".lnk":
        parsed = parse_lnk(exe_path)
        if parsed:
            info["target"] = parsed.get("target", "")
            info["arguments"] = parsed.get("arguments", "")
            info["product_name"] = parsed.get("description") or exe_path.stem
        return info

    if suffix == ".msi":
        info["product_name"] = exe_path.stem
        return info

    try:
        import pefile  # type: ignore

        pe = pefile.PE(str(exe_path), fast_load=True)
        pe.parse_data_directories(
            directories=[pefile.DIRECTORY_ENTRY["IMAGE_DIRECTORY_ENTRY_RESOURCE"]]
        )
        magic = pe.OPTIONAL_HEADER.Magic
        info["arch"] = "x86_64" if magic == 0x20B else ("x86" if magic == 0x10B else "unknown")

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
        elif "nullsoft" in lower_all or "nsis" in lower_all:
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
        data = lnk_path.read_bytes()
    except OSError:
        return None

    if len(data) < 76:
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
        "arguments": sanitize_desktop_value(arguments),
        "icon_location": sanitize_desktop_value(icon_location),
    }
