#!/usr/bin/env python3
"""Pure-Python Android APK / XAPK / APKM manifest, ABI, and icon inspector."""

from __future__ import annotations

import json
import struct
import tempfile
import zipfile
from pathlib import Path
from typing import Optional

from compat_common import safe_extract_zip, sanitize_desktop_value, validate_android_pkg

RES_STRING_POOL_TYPE = 0x0001
RES_XML_TYPE = 0x0003
RES_XML_RESOURCE_MAP_TYPE = 0x0180
RES_XML_START_ELEMENT_TYPE = 0x0102


def _parse_axml_manifest(raw: bytes) -> dict[str, object]:
    """Parse key attributes from binary AndroidManifest.xml without external tools."""
    out: dict[str, object] = {
        "package": "",
        "version_name": "",
        "version_code": "",
        "label": "",
        "icon": "",
    }
    if len(raw) < 8:
        return out
    chunk_type, hdr_size, total_size = struct.unpack_from("<HHI", raw, 0)
    if chunk_type != RES_XML_TYPE:
        return out

    pos = hdr_size
    strings: list[str] = []

    while pos + 8 <= len(raw) and pos < total_size:
        ctype, chdr_size, csize = struct.unpack_from("<HHI", raw, pos)
        if csize < 8 or pos + csize > len(raw):
            break

        if ctype == RES_STRING_POOL_TYPE and pos + 28 <= len(raw):
            string_count, _style_count, flags, strings_start, _styles_start = struct.unpack_from("<IIIII", raw, pos + 8)
            is_utf8 = bool(flags & (1 << 8))
            offsets = struct.unpack_from(f"<{string_count}I", raw, pos + chdr_size)
            pool_base = pos + strings_start
            for off in offsets:
                spos = pool_base + off
                if spos >= len(raw):
                    strings.append("")
                    continue
                if is_utf8:
                    # UTF-8 string pool prefixes two length varints (utf16len, utf8len)
                    def read_varint(p: int) -> tuple[int, int]:
                        if p >= len(raw):
                            return 0, p
                        b = raw[p]
                        if b & 0x80 and p + 1 < len(raw):
                            return ((b & 0x7F) << 8) | raw[p + 1], p + 2
                        return b, p + 1

                    _, spos = read_varint(spos)
                    blen, spos = read_varint(spos)
                    strings.append(raw[spos : spos + blen].decode("utf-8", errors="ignore"))
                else:
                    if spos + 2 > len(raw):
                        strings.append("")
                        continue
                    clen = struct.unpack_from("<H", raw, spos)[0]
                    spos += 2
                    if clen & 0x8000 and spos + 2 <= len(raw):
                        clen = ((clen & 0x7FFF) << 16) | struct.unpack_from("<H", raw, spos)[0]
                        spos += 2
                    strings.append(raw[spos : spos + clen * 2].decode("utf-16-le", errors="ignore"))

        elif ctype == RES_XML_START_ELEMENT_TYPE and pos + 36 <= len(raw):
            _ns_idx, name_idx, attr_start, attr_size, attr_count = struct.unpack_from("<IIHHH", raw, pos + 16)
            tag = strings[name_idx] if 0 <= name_idx < len(strings) else ""
            attr_pos = pos + 16 + attr_start
            for i in range(attr_count):
                cur = attr_pos + i * attr_size
                if cur + 20 > pos + csize:
                    break
                _ans, aname_idx, araw_idx, _tsize, _res0, data_type, data_val = struct.unpack_from("<IIIHBBI", raw, cur)
                aname = strings[aname_idx] if 0 <= aname_idx < len(strings) else ""
                sval = strings[araw_idx] if 0 <= araw_idx < len(strings) else ""
                if not sval and data_type == 0x03 and 0 <= data_val < len(strings):
                    sval = strings[data_val]

                if tag == "manifest":
                    if aname == "package" and sval:
                        out["package"] = sanitize_desktop_value(sval)
                    elif aname == "versionName" and sval:
                        out["version_name"] = sanitize_desktop_value(sval)
                    elif aname == "versionCode" and not out["version_code"]:
                        out["version_code"] = sval or str(data_val)
                elif tag == "application":
                    if aname == "label" and sval and not sval.startswith("@"):
                        out["label"] = sanitize_desktop_value(sval)
                    elif aname == "icon" and sval and sval.lower().endswith(".png"):
                        out["icon"] = sval

        pos += csize

    return out


def _pick_best_apk_icon(zf: zipfile.ZipFile, preferred: str = "") -> Optional[bytes]:
    names = zf.namelist()
    if preferred and preferred in names:
        return zf.read(preferred)
    candidates = [
        n
        for n in names
        if n.lower().endswith(".png")
        and ("ic_launcher" in n.lower() or "app_icon" in n.lower() or "mipmap-" in n.lower())
        and "foreground" not in n.lower()
        and "background" not in n.lower()
        and "round" not in n.lower()
    ]
    if not candidates:
        candidates = [n for n in names if n.lower().endswith(".png") and "ic_launcher" in n.lower()]
    if not candidates:
        return None

    density_rank = {
        "xxxhdpi": 6,
        "xxhdpi": 5,
        "xhdpi": 4,
        "hdpi": 3,
        "mdpi": 2,
        "ldpi": 1,
    }

    def score(name: str) -> tuple[int, int]:
        low = name.lower()
        rank = 0
        for key, val in density_rank.items():
            if key in low:
                rank = val
                break
        return (rank, zf.getinfo(name).file_size)

    best = max(candidates, key=score)
    return zf.read(best)


def inspect_android_package(pkg_path: Path, icon_out: Optional[Path] = None) -> dict[str, object]:
    """Inspect .apk, .xapk, or .apkm package safely and extract metadata + icon."""
    suffix = pkg_path.suffix.lower()
    info: dict[str, object] = {
        "path": str(pkg_path),
        "filename": pkg_path.name,
        "format": suffix.lstrip("."),
        "package": "",
        "name": pkg_path.stem,
        "version_name": "",
        "version_code": "",
        "abis": [],
        "split": suffix in (".xapk", ".apkm"),
        "icon_extracted": False,
        "needs_arm_translation": False,
        "likely_landscape": False,
    }

    if not pkg_path.is_file():
        info["error"] = f"File not found: {pkg_path}"
        return info
    if suffix not in (".apk", ".xapk", ".apkm"):
        info["error"] = "Choose an .apk, .xapk or .apkm file."
        return info

    try:
        if suffix == ".apk":
            with zipfile.ZipFile(pkg_path, "r") as zf:
                parsed: dict[str, object] = {}
                if "AndroidManifest.xml" in zf.namelist():
                    parsed = _parse_axml_manifest(zf.read("AndroidManifest.xml"))
                    info["package"] = parsed.get("package", "")
                    info["version_name"] = parsed.get("version_name", "")
                    info["version_code"] = parsed.get("version_code", "")
                    if parsed.get("label"):
                        info["name"] = parsed["label"]
                abis = sorted(
                    {
                        parts[1]
                        for n in zf.namelist()
                        for parts in [Path(n).parts]
                        if len(parts) >= 3 and parts[0] == "lib"
                    }
                )
                info["abis"] = abis
                if icon_out:
                    icon_bytes = _pick_best_apk_icon(zf, str(parsed.get("icon", "")))
                    if icon_bytes:
                        icon_out.parent.mkdir(parents=True, exist_ok=True)
                        icon_out.write_bytes(icon_bytes)
                        info["icon_extracted"] = True
        else:
            with tempfile.TemporaryDirectory(prefix="tsukuyomi-xapk-") as tmp:
                tmp_dir = Path(tmp)
                extracted = safe_extract_zip(pkg_path, tmp_dir, allowed_exts={".apk", ".json", ".png"})
                manifest_json = tmp_dir / "manifest.json"
                info_json = tmp_dir / "info.json"
                meta = None
                for candidate in (manifest_json, info_json):
                    if candidate.is_file():
                        try:
                            meta = json.loads(candidate.read_text(encoding="utf-8"))
                            break
                        except (OSError, json.JSONDecodeError):
                            pass
                if isinstance(meta, dict):
                    app_name = sanitize_desktop_value(str(meta.get("name") or meta.get("app_name") or ""))
                    if app_name:
                        info["name"] = app_name
                    info["version_name"] = sanitize_desktop_value(str(meta.get("version_name") or meta.get("release_version") or ""))
                    info["version_code"] = sanitize_desktop_value(str(meta.get("version_code") or ""))

                # Inspect base/all split APKs for ABIs and icon fallback
                abis_set: set[str] = set()
                apks = sorted(
                    (p for p in extracted if p.suffix.lower() == ".apk"),
                    key=lambda path: (path.name != "base.apk", path),
                )
                for apk in apks:
                    sub = inspect_android_package(apk, icon_out if not info["icon_extracted"] else None)
                    if sub.get("error"):
                        raise ValueError(f"{apk.name} is not a valid Android package.")
                    if not info["package"]:
                        info["package"] = sub["package"]
                    elif sub["package"] != info["package"]:
                        raise ValueError("The bundled APKs belong to different apps.")
                    if info["name"] == pkg_path.stem and sub.get("name") and sub["name"] != apk.stem:
                        info["name"] = sub["name"]
                    if not info["version_name"] and sub.get("version_name"):
                        info["version_name"] = sub["version_name"]
                    if sub.get("icon_extracted"):
                        info["icon_extracted"] = True
                    for abi in sub.get("abis", []):
                        abis_set.add(abi)

                if not info["icon_extracted"] and icon_out and (tmp_dir / "icon.png").is_file():
                    icon_out.parent.mkdir(parents=True, exist_ok=True)
                    icon_out.write_bytes((tmp_dir / "icon.png").read_bytes())
                    info["icon_extracted"] = True

                info["abis"] = sorted(abis_set)
    except (zipfile.BadZipFile, ValueError, OSError) as exc:
        info["error"] = str(exc)
        return info

    abis_list = info["abis"]
    if isinstance(abis_list, list) and abis_list:
        has_native_x86 = any(a in ("x86_64", "x86") for a in abis_list)
        has_arm = any(a in ("arm64-v8a", "armeabi-v7a", "armeabi") for a in abis_list)
        info["needs_arm_translation"] = has_arm and not has_native_x86

    if info["package"]:
        try:
            validate_android_pkg(str(info["package"]))
        except ValueError:
            info["package"] = ""
    if not info["package"]:
        info["error"] = "This file does not contain a valid Android app manifest."

    return info
