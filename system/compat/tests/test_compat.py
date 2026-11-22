#!/usr/bin/env python3
"""Unit and security tests for Tsukuyomi WinBridge and DroidBridge backends."""

from __future__ import annotations

import importlib.machinery
import importlib.util
import io
import json
import os
import stat
import struct
import subprocess
import sys
import tempfile
import unittest
import zipfile
from pathlib import Path
from unittest import mock

LIB_DIR = Path(__file__).resolve().parents[2] / "desktop" / "rootfs" / "usr" / "lib" / "tsukuyomi"
sys.path.insert(0, str(LIB_DIR))

import compat_common  # noqa: E402
import droid_apk  # noqa: E402
import win_lnk  # noqa: E402


def _load_script(name: str):
    path = str(LIB_DIR / name)
    loader = importlib.machinery.SourceFileLoader(name.replace("-", "_"), path)
    spec = importlib.util.spec_from_loader(loader.name, loader)
    assert spec is not None
    mod = importlib.util.module_from_spec(spec)
    loader.exec_module(mod)
    return mod


tsukuyomi_win = _load_script("tsukuyomi-win")
tsukuyomi_droid = _load_script("tsukuyomi-droid")


def _build_synthetic_lnk(target: str, args: str) -> bytes:
    header = bytearray(76)
    struct.pack_into("<I", header, 0, 0x4C)
    header[4:20] = bytes.fromhex("0114020000000000c000000000000046")
    # HasLinkInfo (0x02) | HasArguments (0x20) | IsUnicode (0x80)
    struct.pack_into("<I", header, 20, 0x02 | 0x20 | 0x80)

    target_bytes = target.encode("cp1252") + b"\x00"
    link_info_hdr = 28
    link_info_size = link_info_hdr + len(target_bytes) + 1
    link_info = bytearray(link_info_size)
    struct.pack_into("<IIIIIII", link_info, 0, link_info_size, link_info_hdr, 0x01, 0, link_info_hdr, 0, link_info_hdr + len(target_bytes))
    link_info[link_info_hdr : link_info_hdr + len(target_bytes)] = target_bytes
    link_info[-1] = 0

    args_u16 = args.encode("utf-16-le")
    args_block = struct.pack("<H", len(args)) + args_u16
    return bytes(header) + bytes(link_info) + args_block


def _build_synthetic_axml(package: str, version_name: str, label: str) -> bytes:
    strings = [
        "package", "versionName", "label", "manifest", "application",
        package, version_name, label,
    ]
    # Build UTF-16 string pool
    pool_data = bytearray()
    offsets: list[int] = []
    for s in strings:
        offsets.append(len(pool_data))
        enc = s.encode("utf-16-le")
        pool_data.extend(struct.pack("<H", len(s)))
        pool_data.extend(enc)
        pool_data.extend(b"\x00\x00")
    while len(pool_data) % 4 != 0:
        pool_data.append(0)

    hdr_size = 28
    strings_start = hdr_size + len(offsets) * 4
    pool_size = strings_start + len(pool_data)
    pool_chunk = struct.pack("<HHIIIIIII", 0x0001, hdr_size, pool_size, len(strings), 0, 0, strings_start, 0, 0)[:28]
    # Re-pack exact 28-byte header
    pool_chunk = struct.pack("<HHIIIII", 0x0001, hdr_size, pool_size, len(strings), 0, 0, strings_start) + struct.pack("<I", 0)
    for off in offsets:
        pool_chunk += struct.pack("<I", off)
    pool_chunk += bytes(pool_data)

    def make_start_elem(tag_idx: int, attrs: list[tuple[int, int]]) -> bytes:
        attr_bytes = bytearray()
        for name_i, val_i in attrs:
            attr_bytes.extend(struct.pack("<IIIHBBI", 0xFFFFFFFF, name_i, val_i, 8, 0, 0x03, val_i))
        csize = 36 + len(attr_bytes)
        hdr = struct.pack(
            "<HHIIIIIHHHHHH",
            0x0102, 16, csize, 1, 0xFFFFFFFF,
            0xFFFFFFFF, tag_idx, 20, 20, len(attrs), 0, 0, 0,
        )
        return hdr + bytes(attr_bytes)

    elem1 = make_start_elem(3, [(0, 5), (1, 6)])  # manifest: package, versionName
    elem2 = make_start_elem(4, [(2, 7)])          # application: label
    body = pool_chunk + elem1 + elem2
    return struct.pack("<HHI", 0x0003, 8, 8 + len(body)) + body


class CompatTests(unittest.TestCase):
    def test_validators_reject_injection(self) -> None:
        self.assertEqual(compat_common.validate_slug("notepad-plus-2"), "notepad-plus-2")
        with self.assertRaises(ValueError):
            compat_common.validate_slug("../evil")
        with self.assertRaises(ValueError):
            compat_common.validate_slug("bad;rm -rf")

        self.assertEqual(compat_common.validate_android_pkg("com.example.app_1"), "com.example.app_1")
        with self.assertRaises(ValueError):
            compat_common.validate_android_pkg("com.example.$(id)")
        with self.assertRaises(ValueError):
            compat_common.validate_android_pkg("invalid")

    def test_sanitize_and_exec_quoting(self) -> None:
        dirty = "My App\nExec=sh -c evil\x00"
        cleaned = compat_common.sanitize_desktop_value(dirty)
        self.assertNotIn("\n", cleaned)
        self.assertNotIn("\x00", cleaned)

        exe_line = compat_common.format_desktop_exec(["/usr/lib/tsukuyomi/win-launch", "app-1", "100%"])
        self.assertIn("100%%", exe_line)

    def test_zip_slip_and_symlink_blocked(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            tmp_dir = Path(tmp)
            evil_zip = tmp_dir / "evil.xapk"
            with zipfile.ZipFile(evil_zip, "w") as zf:
                zf.writestr("../../.bashrc", "pwned")
            with self.assertRaises(ValueError):
                compat_common.safe_extract_zip(evil_zip, tmp_dir / "out")

            sym_zip = tmp_dir / "sym.xapk"
            with zipfile.ZipFile(sym_zip, "w") as zf:
                zi = zipfile.ZipInfo("link.apk")
                zi.external_attr = (stat.S_IFLNK | 0o777) << 16
                zf.writestr(zi, "/etc/passwd")
            with self.assertRaises(ValueError):
                compat_common.safe_extract_zip(sym_zip, tmp_dir / "out2")

    def test_lnk_parser(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            lnk = Path(tmp) / "App.lnk"
            lnk.write_bytes(_build_synthetic_lnk(r"C:\Program Files\Demo\demo.exe", "--lang=id"))
            parsed = win_lnk.parse_lnk(lnk)
            self.assertIsNotNone(parsed)
            assert parsed is not None
            self.assertEqual(parsed["target"], r"C:\Program Files\Demo\demo.exe")
            self.assertEqual(parsed["arguments"], "--lang=id")

    def test_apk_inspector_axml_and_abi(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            tmp_dir = Path(tmp)
            apk = tmp_dir / "sample.apk"
            icon_out = tmp_dir / "icon.png"
            axml = _build_synthetic_axml("org.tsukuyomi.sample", "2.1.0", "Tsukuyomi Sample")
            fake_png = b"\x89PNG\r\n\x1a\n" + b"\x00" * 32
            with zipfile.ZipFile(apk, "w") as zf:
                zf.writestr("AndroidManifest.xml", axml)
                zf.writestr("lib/arm64-v8a/libnative.so", b"ELF")
                zf.writestr("res/mipmap-xxxhdpi/ic_launcher.png", fake_png)

            info = droid_apk.inspect_android_package(apk, icon_out)
            self.assertEqual(info["package"], "org.tsukuyomi.sample")
            self.assertEqual(info["version_name"], "2.1.0")
            self.assertEqual(info["name"], "Tsukuyomi Sample")
            self.assertEqual(info["abis"], ["arm64-v8a"])
            self.assertTrue(info["needs_arm_translation"])
            self.assertTrue(info["icon_extracted"])
            self.assertTrue(icon_out.is_file())

    def test_droid_sync_desktop_hides_system_and_writes_icons_first(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            data_home = Path(tmp) / "share"
            apps_dir = data_home / "applications"
            wd_icons = data_home / "waydroid" / "data" / "icons"
            apps_dir.mkdir(parents=True)
            wd_icons.mkdir(parents=True)

            (apps_dir / "waydroid.com.android.settings.desktop").write_text("[Desktop Entry]\nName=Settings\n", encoding="utf-8")
            (apps_dir / "waydroid.org.fdroid.fdroid.desktop").write_text("[Desktop Entry]\nName=F-Droid\n", encoding="utf-8")
            (wd_icons / "org.fdroid.fdroid.png").write_bytes(b"\x89PNG\r\n\x1a\n1234")

            with mock.patch.dict(os.environ, {"XDG_DATA_HOME": str(data_home)}):
                with mock.patch("compat_common.refresh_desktop_caches"):
                    res = tsukuyomi_droid.sync_desktop()
                    self.assertTrue(res["ok"])

            settings_txt = (apps_dir / "waydroid.com.android.settings.desktop").read_text(encoding="utf-8")
            fdroid_txt = (apps_dir / "waydroid.org.fdroid.fdroid.desktop").read_text(encoding="utf-8")
            self.assertIn("NoDisplay=true", settings_txt)
            self.assertIn("NoDisplay=false", fdroid_txt)
            self.assertIn("X-Tsukuyomi-Runtime=android", fdroid_txt)
            self.assertIn("StartupWMClass=waydroid.org.fdroid.fdroid", fdroid_txt)
            self.assertTrue((data_home / "icons" / "hicolor" / "256x256" / "apps" / "waydroid.org.fdroid.fdroid.png").is_file())

    def test_win_export_and_uninstall(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            data_home = Path(tmp) / "share"
            prefix = data_home / "tsukuyomi" / "windows" / "prefixes" / "demo-app"
            exe = prefix / "drive_c" / "Program Files" / "Demo" / "demo.exe"
            exe.parent.mkdir(parents=True)
            exe.write_bytes(b"MZ")

            with mock.patch.dict(os.environ, {"XDG_DATA_HOME": str(data_home)}):
                with mock.patch("compat_common.refresh_desktop_caches"):
                    rc = tsukuyomi_win.main([
                        "export-desktop",
                        "demo-app",
                        "--select",
                        json.dumps([{"name": "Demo App", "exe": str(exe)}]),
                    ])
                    self.assertEqual(rc, 0)
                    desktop = data_home / "applications" / "tsukuyomi-win-demo-app.desktop"
                    self.assertTrue(desktop.is_file())
                    txt = desktop.read_text(encoding="utf-8")
                    self.assertIn("X-Tsukuyomi-Runtime=windows", txt)
                    self.assertIn("StartupWMClass=demo.exe", txt)

                    rc2 = tsukuyomi_win.main(["uninstall", "demo-app"])
                    self.assertEqual(rc2, 0)
                    self.assertFalse(desktop.exists())
                    self.assertFalse(prefix.exists())

    def test_exec_quoting_escapes_shell_metachars(self) -> None:
        line = compat_common.format_desktop_exec(["/usr/bin/x", "a $(id) `id` b"])
        self.assertIn('"a \\$(id) \\`id\\` b"', line)

    def test_zip_bomb_limit_streams(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            tmp_dir = Path(tmp)
            bomb = tmp_dir / "bomb.xapk"
            with zipfile.ZipFile(bomb, "w", compression=zipfile.ZIP_DEFLATED) as zf:
                zf.writestr("base.apk", b"\x00" * (2 * 1024 * 1024))
            with self.assertRaises(ValueError):
                compat_common.safe_extract_zip(bomb, tmp_dir / "out", max_total_bytes=1024 * 1024)
            self.assertFalse((tmp_dir / "out" / "base.apk").exists())

    def test_apk_inspector_reports_corrupt_archive(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            bad = Path(tmp) / "broken.apk"
            bad.write_bytes(b"not a zip")
            info = droid_apk.inspect_android_package(bad)
            self.assertIn("error", info)
            self.assertEqual(info["package"], "")

    def test_bwrap_never_exposes_session_bus_or_home(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            rt = Path(tmp) / "rt"
            rt.mkdir()
            (rt / "bus").write_text("", encoding="utf-8")
            prefix = Path(tmp) / "pfx"
            prefix.mkdir()
            with mock.patch.dict(os.environ, {"XDG_RUNTIME_DIR": str(rt), "XDG_DATA_HOME": str(Path(tmp) / "share")}):
                with mock.patch.object(tsukuyomi_win.shutil, "which", return_value="/usr/bin/bwrap"):
                    with mock.patch.object(tsukuyomi_win, "shared_dir", return_value=Path(tmp) / "shared"):
                        argv = tsukuyomi_win._build_bwrap_argv(
                            ["wine", "x.exe"], env={}, prefix=prefix,
                            ro_binds=[(Path.home(), Path("/mnt/x"))], cwd=None,
                        )
            joined = " ".join(argv)
            self.assertNotIn(str(rt / "bus"), joined)
            self.assertNotIn(f"--ro-bind {Path.home()} /mnt/x", joined)
            self.assertEqual(argv[-2:], ["wine", "x.exe"])

    def test_portable_pin_refuses_download_folder_bundle(self) -> None:
        self.assertFalse(tsukuyomi_win._is_safe_portable_bundle_dir(Path.home() / "Downloads"))
        with tempfile.TemporaryDirectory() as tmp:
            app_dir = Path(tmp) / "MyPortableApp"
            app_dir.mkdir()
            (app_dir / "app.exe").write_bytes(b"MZ")
            self.assertTrue(tsukuyomi_win._is_safe_portable_bundle_dir(app_dir))

    def test_file_uri_decoding(self) -> None:
        self.assertEqual(tsukuyomi_win._decode_uri_path("file:///home/u/My%20Setup.exe"), "/home/u/My Setup.exe")
        self.assertEqual(tsukuyomi_win._decode_uri_path("/plain/path.exe"), "/plain/path.exe")

    def test_windows_cancel_cleans_only_the_new_prefix(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            with mock.patch.dict(os.environ, {"XDG_DATA_HOME": tmp, "XDG_RUNTIME_DIR": tmp}):
                installed = tsukuyomi_win.prefixes_dir() / "demo"
                installed.mkdir(parents=True)
                with self.assertRaises(tsukuyomi_win.InstallCancelled):
                    with tsukuyomi_win._installation_prefix("demo", fresh=True) as work:
                        self.assertEqual(work.name, "demo-2")
                        raise tsukuyomi_win.InstallCancelled
                self.assertTrue(installed.is_dir())
                self.assertFalse(work.exists())

    def test_windows_scan_does_not_export_unchanged_apps(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            prefix = Path(tmp)
            existing = prefix / "drive_c" / "Program Files" / "Existing.exe"
            existing.parent.mkdir(parents=True)
            existing.touch()
            before = tsukuyomi_win._snapshot_lnk_and_exe(prefix)
            self.assertEqual(tsukuyomi_win.scan_shortcuts(prefix, *before), [])
            new_app = existing.with_name("New App.exe")
            new_app.touch()
            self.assertEqual([app["exe"] for app in tsukuyomi_win.scan_shortcuts(prefix, *before)], [str(new_app)])

    def test_android_install_requires_package_manager_success(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            apk = io.BytesIO()
            with zipfile.ZipFile(apk, "w") as zf:
                zf.writestr("AndroidManifest.xml", _build_synthetic_axml("org.tsukuyomi.demo", "1", "Demo"))
            bundle = Path(tmp) / "Demo.xapk"
            with zipfile.ZipFile(bundle, "w") as zf:
                zf.writestr("base.apk", apk.getvalue())
            out = io.StringIO()
            failed = subprocess.CompletedProcess([], 0, "Failure [INSTALL_FAILED_UPDATE_INCOMPATIBLE]", "")
            with mock.patch.dict(os.environ, {"XDG_DATA_HOME": tmp, "XDG_RUNTIME_DIR": tmp}), \
                 mock.patch.object(tsukuyomi_droid, "_ensure_container_and_session", return_value=True), \
                 mock.patch.object(tsukuyomi_droid, "_adb_waydroid", return_value=failed), \
                 mock.patch("sys.stdout", out):
                result = tsukuyomi_droid.main(["install", str(bundle)])
                self.assertFalse(tsukuyomi_droid.apps_db_path().exists())
            self.assertEqual(result, 1)
            self.assertFalse(json.loads(out.getvalue())["ok"])

    def test_android_adb_does_not_guess_a_container_address(self) -> None:
        with mock.patch.object(tsukuyomi_droid.shutil, "which", return_value="/usr/bin/adb"), \
             mock.patch.object(tsukuyomi_droid, "_waydroid_ip", return_value=None), \
             mock.patch.object(tsukuyomi_droid, "run_cmd") as run:
            result = tsukuyomi_droid._adb_waydroid("install", "app.apk")
        self.assertNotEqual(result.returncode, 0)
        run.assert_not_called()


if __name__ == "__main__":
    unittest.main(verbosity=2)
