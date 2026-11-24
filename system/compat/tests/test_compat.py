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
    def test_antigravity_prefix_migrates_standalone_tray_setting(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            prefix = Path(tmp) / "antigravity"
            options = {"sandbox": False, "wayland": False, "dxvk": False}
            imports = []

            def capture_import(argv, *, env, **_kwargs):
                self.assertNotIn("DISPLAY", env)
                self.assertNotIn("WAYLAND_DISPLAY", env)
                self.assertIn("winex11.drv,winewayland.drv=", env["WINEDLLOVERRIDES"])
                imports.append(Path(argv[-1]).read_text())

            with mock.patch.object(tsukuyomi_win, "detect_hypr_monitor", return_value={"scale": 1}), \
                    mock.patch.object(tsukuyomi_win, "detect_theme_dark", return_value=True), \
                    mock.patch.dict(os.environ, {"DISPLAY": ":0", "WAYLAND_DISPLAY": "wayland-1"}), \
                    mock.patch.object(tsukuyomi_win.subprocess, "run", side_effect=capture_import):
                tsukuyomi_win._apply_prefix_hardening_and_theme(prefix, **options)
                tsukuyomi_win._apply_prefix_hardening_and_theme(prefix, hide_standalone_tray=True, **options)
                tsukuyomi_win._apply_prefix_hardening_and_theme(prefix, **options)

            self.assertEqual(len(imports), 2)
            self.assertNotIn("ShowSystray", imports[0])
            self.assertIn('"ShowSystray"=dword:00000000', imports[1])

    def test_phone_viewport_preserves_width_on_short_display(self) -> None:
        with mock.patch.object(
            tsukuyomi_droid, "detect_hypr_monitor",
            return_value={"width": 1920, "height": 1200, "scale": 1.5},
        ):
            self.assertEqual(tsukuyomi_droid._phone_viewport("auto"), (480, 688))
            self.assertEqual(tsukuyomi_droid._phone_viewport("compact"), (390, 688))
            self.assertEqual(tsukuyomi_droid._phone_viewport("wide"), (550, 688))

    def test_duplicate_launch_focuses_existing_window_in_locked_prefix(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            prefix = root / "antigravity"
            prefix.mkdir()
            exe = prefix / "Antigravity.exe"
            exe.touch()
            args = tsukuyomi_win.argparse.Namespace(app_id="antigravity", extra_args=[])
            record = {"slug": "antigravity", "exe": str(exe)}
            with mock.patch.object(tsukuyomi_win, "xdg_runtime_dir", return_value=root), \
                    mock.patch.object(tsukuyomi_win, "prefixes_dir", return_value=root), \
                    mock.patch.object(tsukuyomi_win, "read_json", return_value=record), \
                    mock.patch.object(tsukuyomi_win, "_launch_registered_app") as run, \
                    mock.patch.object(tsukuyomi_win, "_focus_running_app", return_value=True) as focus, \
                    tsukuyomi_win._installation_prefix("antigravity", fresh=False):
                self.assertEqual(tsukuyomi_win.cmd_run(args), 0)
                run.assert_not_called()
                focus.assert_called_once_with(prefix, exe)

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
                with mock.patch.object(tsukuyomi_droid, "refresh_desktop_caches") as refresh:
                    res = tsukuyomi_droid.sync_desktop()
                    self.assertTrue(res["ok"])
                    tsukuyomi_droid.sync_desktop()
                    refresh.assert_called_once()

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

            with mock.patch.dict(os.environ, {"XDG_DATA_HOME": str(data_home), "XDG_RUNTIME_DIR": tmp}):
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

                    with tsukuyomi_win._installation_prefix("demo-app", fresh=False):
                        self.assertEqual(tsukuyomi_win.main(["uninstall", "demo-app"]), 1)
                        self.assertTrue(desktop.is_file())
                        self.assertTrue(exe.is_file())

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
                            ["wine", "x.exe"], env={"HOME": str(Path.home()), "TEST_HOST_CREDENTIAL": "unset-me"}, prefix=prefix,
                            ro_binds=[(Path.home(), Path("/mnt/x"))], cwd=None,
                        )
            joined = " ".join(argv)
            self.assertNotIn(str(rt / "bus"), joined)
            self.assertNotIn(f"--ro-bind {Path.home()} /mnt/x", joined)
            self.assertNotIn("--dev-bind /dev/input", joined)
            self.assertNotIn("--ro-bind /etc /etc", joined)
            self.assertNotIn("pipewire-0-manager", joined)
            self.assertNotIn("TEST_HOST_CREDENTIAL", joined)
            self.assertIn("--clearenv", argv)
            self.assertEqual(argv[-2:], ["wine", "x.exe"])

    def test_wine_maintenance_stays_in_sandbox_and_waits_for_registry(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            prefix = Path(tmp)
            env = {"WINEPREFIX": tmp}
            with mock.patch.object(tsukuyomi_win, "_build_bwrap_argv", return_value=["bwrap", "setup"]) as sandbox, \
                    mock.patch.object(tsukuyomi_win.subprocess, "Popen") as run:
                process = run.return_value.__enter__.return_value
                process.wait.return_value = 0
                tsukuyomi_win._run_prefix_setup(["wineboot", "--init"], env=env, prefix=prefix,
                                                sandbox=True, timeout=120)
            self.assertIn("wineserver -w", sandbox.call_args.args[0][2])
            self.assertEqual(run.call_args.args[0], ["bwrap", "setup"])
            process.wait.assert_called_once_with(timeout=120)

    def test_setup_reports_success_with_autolaunched_app_still_running(self) -> None:
        candidates = [{"exe": "/example/App.exe"}]
        process = mock.Mock(stdout=io.BytesIO(b"0\n"))
        with mock.patch.object(tsukuyomi_win.subprocess, "Popen", return_value=process) as popen, \
                mock.patch.object(tsukuyomi_win, "scan_shortcuts", return_value=candidates), \
                mock.patch.object(tsukuyomi_win.signal, "signal"):
            result = tsukuyomi_win._run_sandbox_setup(
                ["bwrap", "setup"], env={}, lock_fd=9, prefix=Path("/example"),
                before_lnks={}, before_exes={},
            )
        self.assertEqual(result, candidates)
        self.assertEqual(popen.call_args.kwargs["pass_fds"], (9,))
        self.assertTrue(popen.call_args.kwargs["start_new_session"])
        process.wait.assert_not_called()
        process.terminate.assert_not_called()

    def test_setup_waits_for_delegated_installer_when_no_app_found_yet(self) -> None:
        candidates = [{"exe": "/example/App.exe"}]
        process = mock.Mock(stdout=io.BytesIO(b"0\n"))
        process.wait.return_value = 0
        with mock.patch.object(tsukuyomi_win.subprocess, "Popen", return_value=process), \
                mock.patch.object(tsukuyomi_win, "scan_shortcuts", side_effect=[[], candidates]), \
                mock.patch.object(tsukuyomi_win.signal, "signal"):
            result = tsukuyomi_win._run_sandbox_setup(
                ["bwrap", "setup"], env={}, lock_fd=9, prefix=Path("/example"),
                before_lnks={}, before_exes={},
            )
        process.wait.assert_called_once_with()
        self.assertEqual(result, candidates)

    def test_cancelling_pending_setup_stops_its_supervisor(self) -> None:
        status = mock.MagicMock()
        status.__enter__.return_value.readline.side_effect = tsukuyomi_win.InstallCancelled
        process = mock.Mock(stdout=status)
        process.poll.return_value = None
        with mock.patch.object(tsukuyomi_win.subprocess, "Popen", return_value=process):
            with self.assertRaises(tsukuyomi_win.InstallCancelled):
                tsukuyomi_win._run_sandbox_setup(
                    ["bwrap", "setup"], env={}, lock_fd=9, prefix=Path("/example"),
                    before_lnks={}, before_exes={},
                )
        process.terminate.assert_called_once_with()
        process.wait.assert_called_once_with(timeout=5)

    def test_prefix_rejects_links_outside_its_tree(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            prefix = Path(tmp) / "prefix"
            prefix.mkdir()
            (prefix / ".cache").symlink_to(Path(tmp))
            with self.assertRaises(ValueError):
                tsukuyomi_win._prefix_path(prefix, ".cache")

    def test_umu_cannot_claim_bubblewrap_isolation(self) -> None:
        with self.assertRaisesRegex(ValueError, "Wine Staging"):
            tsukuyomi_win._check_runner("umu", True)

    def test_setup_exposes_only_selected_file_by_default(self) -> None:
        root = Path("/mnt/installer")
        src = Path.home() / "Downloads" / "App.exe"
        self.assertEqual(tsukuyomi_win._installer_binds(src, root, False), [(src, root / src.name)])
        with self.assertRaisesRegex(ValueError, "dedicated folder"):
            tsukuyomi_win._installer_binds(src, root, True)

    def test_windows_shortcut_arguments_round_trip(self) -> None:
        argv = ["--profile", r'C:\\Program Files\\Vendor\\Profile', "", r'C:\\folder\\', 'a"b']
        command = subprocess.list2cmdline(argv)
        self.assertEqual(win_lnk.split_windows_args(command), argv)

    def test_windows_file_headers_checked_before_install(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            base = Path(tmp)
            for name in ("App.exe", "App.msi", "App.lnk"):
                path = base / name
                path.write_bytes(b"<html>download error</html>")
                self.assertIn("error", win_lnk.inspect_pe(path), name)

    def test_windows_setup_uses_mapped_working_directory_and_nsis_fallback(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            source = root / "Setup.exe"
            stub = bytearray(1024)
            stub[:2] = b"MZ"
            struct.pack_into("<I", stub, 60, 64)
            stub[64:70] = b"PE\x00\x00\x64\x86"
            signature = b"\xef\xbe\xad\xdeNullsoftInst"
            stub[516:516 + len(signature)] = signature
            source.write_bytes(stub)
            self.assertTrue(win_lnk.inspect_pe(source)["nsis_archive"])
            prefix = root / "app"
            (prefix / "drive_c").mkdir(parents=True)
            (prefix / "dosdevices").mkdir()
            args = mock.Mock(mode="isolated", progress=False, share_installer_folder=False)
            with mock.patch.dict(os.environ, {"XDG_DATA_HOME": tmp, "XDG_RUNTIME_DIR": tmp}), \
                 mock.patch.object(tsukuyomi_win, "_ensure_prefix", return_value=prefix), \
                 mock.patch.object(tsukuyomi_win, "_build_bwrap_argv", return_value=["bwrap"]) as build, \
                 mock.patch.object(tsukuyomi_win, "_run_sandbox_setup", return_value=[]), \
                 mock.patch("sys.stdout", io.StringIO()):
                self.assertEqual(tsukuyomi_win._install_in_prefix(
                    args, source, [], "Example", "app", lock_fd=0, sandbox=True,
                    wayland=False, dxvk=False, runner="wine", antigravity_setup=False, nsis_setup=True,
                ), 0)
            self.assertEqual(build.call_args.kwargs["cwd"], prefix / "drive_c")
            self.assertIn("powershell.exe=n", build.call_args.kwargs["env"]["WINEDLLOVERRIDES"])
            self.assertFalse((prefix / "dosdevices" / "e:").is_symlink())

    def test_windows_scan_finds_uppercase_and_local_install(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            prefix = Path(tmp) / "demo"
            user = os.environ.get("USER") or Path.home().name
            exe = prefix / "drive_c" / "users" / user / "AppData" / "Local" / "Vendor" / "APP.EXE"
            exe.parent.mkdir(parents=True)
            before = tsukuyomi_win._snapshot_lnk_and_exe(prefix)
            exe.write_bytes(b"MZ")
            found = tsukuyomi_win.scan_shortcuts(prefix, *before)
            self.assertEqual([item["exe"] for item in found], [str(exe)])

    def test_portable_pin_refuses_download_folder_bundle(self) -> None:
        self.assertFalse(tsukuyomi_win._is_safe_portable_bundle_dir(Path.home() / "Downloads"))
        with tempfile.TemporaryDirectory() as tmp:
            app_dir = Path(tmp) / "MyPortableApp"
            app_dir.mkdir()
            (app_dir / "app.exe").write_bytes(b"MZ")
            for index in range(221):
                (app_dir / f"resource-{index}.xml").touch()
            self.assertTrue(tsukuyomi_win._is_safe_portable_bundle_dir(app_dir))

    def test_file_uri_decoding(self) -> None:
        self.assertEqual(compat_common.decode_file_uri("file:///home/u/My%20Setup.exe"), "/home/u/My Setup.exe")
        self.assertEqual(compat_common.decode_file_uri("/plain/path.exe"), "/plain/path.exe")
        with self.assertRaises(ValueError):
            compat_common.decode_file_uri("file://another-computer/share/Setup.exe")

    def test_windows_launcher_maps_file_uri_to_sandbox_drive(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            prefix = root / "app"
            executable = prefix / "drive_c" / "App.exe"
            executable.parent.mkdir(parents=True)
            executable.touch()
            (prefix / "dosdevices").mkdir()
            document = root / "My Document.txt"
            document.touch()
            args = mock.Mock(extra_args=[document.as_uri()])
            with mock.patch.object(tsukuyomi_win, "_ensure_prefix"), \
                 mock.patch.object(tsukuyomi_win, "_build_bwrap_argv", return_value=["bwrap"]) as build, \
                 mock.patch.object(tsukuyomi_win.subprocess, "run", return_value=subprocess.CompletedProcess([], 0)):
                self.assertEqual(tsukuyomi_win._launch_registered_app(args, {"sandbox": True}, prefix, executable), 0)
            self.assertEqual(build.call_args.args[0][-1], "E:\\f0\\My Document.txt")
            self.assertEqual(build.call_args.kwargs["ro_binds"], [(document, Path("/mnt/tsukuyomi-open/f0/My Document.txt"))])
            self.assertFalse((prefix / "dosdevices" / "e:").is_symlink())

    def test_windows_cancel_cleans_only_the_new_prefix(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            with mock.patch.dict(os.environ, {"XDG_DATA_HOME": tmp, "XDG_RUNTIME_DIR": tmp}):
                installed = tsukuyomi_win.prefixes_dir() / "demo"
                installed.mkdir(parents=True)
                with self.assertRaises(tsukuyomi_win.InstallCancelled):
                    with tsukuyomi_win._installation_prefix("demo", fresh=True) as (work, _):
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

    def test_android_install_accepts_file_uri_and_reports_backend_stages(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            apk = Path(tmp) / "Sample App.apk"
            with zipfile.ZipFile(apk, "w") as zf:
                zf.writestr("AndroidManifest.xml", _build_synthetic_axml("org.tsukuyomi.demo", "1", "Demo"))
            desktop = Path(tmp) / "applications" / "waydroid.org.tsukuyomi.demo.desktop"
            desktop.parent.mkdir()
            desktop.write_text("[Desktop Entry]\nName=Demo\n")
            out, err = io.StringIO(), io.StringIO()
            with mock.patch.dict(os.environ, {"XDG_DATA_HOME": tmp, "XDG_RUNTIME_DIR": tmp}), \
                 mock.patch.object(tsukuyomi_droid, "_ensure_container_ready"), \
                 mock.patch.object(tsukuyomi_droid, "_session_running", return_value=True), \
                 mock.patch.object(tsukuyomi_droid, "_wait_for_session_boot", return_value=True) as wait, \
                 mock.patch.object(tsukuyomi_droid, "_seed_default_stores_if_needed"), \
                 mock.patch.object(tsukuyomi_droid, "sync_desktop", return_value={"synced": ["org.tsukuyomi.demo"]}), \
                 mock.patch.object(tsukuyomi_droid, "run_cmd", return_value=subprocess.CompletedProcess([], 0)) as run, \
                 mock.patch("sys.stdout", out), mock.patch("sys.stderr", err):
                self.assertEqual(tsukuyomi_droid.main(["install", apk.as_uri(), "--progress"]), 0)
            wait.assert_called_once_with()
            run.assert_called_once_with([tsukuyomi_droid.PLATFORM, "install", str(apk)], timeout=180)
            self.assertTrue(json.loads(out.getvalue())["launcherReady"])
            self.assertEqual(
                err.getvalue().splitlines(),
                [f"TSUKUYOMI_PROGRESS {stage}" for stage in ("inspect", "runtime", "boot", "install", "stores", "launcher")],
            )

    def test_android_idle_sleep_skips_an_install_or_an_open_window(self) -> None:
        with tempfile.TemporaryDirectory() as tmp, \
             mock.patch.dict(os.environ, {"XDG_RUNTIME_DIR": tmp}), \
             mock.patch.object(tsukuyomi_droid, "has_open_android_window", return_value=True) as visible, \
             mock.patch.object(tsukuyomi_droid, "run_cmd") as run:
            with tsukuyomi_droid.droid_lock():
                self.assertEqual(tsukuyomi_droid.main(["sleep", "--idle"]), 0)
            visible.assert_not_called()
            self.assertEqual(tsukuyomi_droid.main(["sleep", "--idle"]), 0)
            visible.assert_called_once_with()
            run.assert_not_called()

    def test_android_adb_does_not_guess_a_container_address(self) -> None:
        with mock.patch.object(tsukuyomi_droid.shutil, "which", return_value="/usr/bin/adb"), \
             mock.patch.object(tsukuyomi_droid, "_waydroid_ip", return_value=None), \
             mock.patch.object(tsukuyomi_droid, "run_cmd") as run:
            result = tsukuyomi_droid._adb_waydroid("install", "app.apk")
        self.assertNotEqual(result.returncode, 0)
        run.assert_not_called()

    def test_android_defaults_to_standard_phone_size_and_respects_reserved_insets(self) -> None:
        self.assertEqual(tsukuyomi_droid.default_config()["phoneSize"], "standard")
        with mock.patch.object(
            tsukuyomi_droid, "detect_hypr_monitor",
            return_value={"width": 1366, "height": 768, "scale": 1.0, "reservedX": 0, "reservedY": 100},
        ):
            w, h = tsukuyomi_droid._phone_viewport("standard")
            self.assertLessEqual(h, 668)
            self.assertLessEqual(w, 480)

    def test_bwrap_hardening_caps_and_cursor_env(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            prefix = root / "pfx"
            prefix.mkdir()
            (root / "pipewire-0").touch()
            env = {
                "USER": "tester",
                "HOME": str(root),
                "WINEPREFIX": str(prefix),
                "XCURSOR_THEME": "Bibata-Modern-Classic",
                "XCURSOR_SIZE": "24",
                "WAYLAND_DISPLAY": "wayland-1",
            }
            with mock.patch.object(tsukuyomi_win.shutil, "which", return_value="/usr/bin/bwrap"), \
                 mock.patch.object(tsukuyomi_win, "xdg_runtime_dir", return_value=root), \
                 mock.patch.object(tsukuyomi_win, "shared_dir", return_value=root / "shared"):
                argv = tsukuyomi_win._build_bwrap_argv(["wine", "app.exe"], env=env, prefix=prefix, ro_binds=[], cwd=prefix)
            self.assertIn("--cap-drop", argv)
            self.assertIn("ALL", argv)
            self.assertIn("--unshare-uts", argv)
            self.assertIn("XCURSOR_THEME", argv)
            self.assertNotIn("/dev/snd", argv)

    def test_win_wayland_skips_logpixels_double_scaling(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            prefix = Path(tmp) / "pfx"
            (prefix / "drive_c").mkdir(parents=True)
            with mock.patch.object(tsukuyomi_win, "detect_hypr_monitor", return_value={"width": 3840, "height": 2160, "scale": 2.0}), \
                 mock.patch.object(tsukuyomi_win, "detect_theme_dark", return_value=True), \
                 mock.patch.object(tsukuyomi_win, "_run_prefix_setup"):
                tsukuyomi_win._apply_prefix_hardening_and_theme(prefix, sandbox=True, wayland=True, dxvk=True)
                meta_wl = tsukuyomi_win.read_json(prefix / ".tsukuyomi-prefix.json", {})
                self.assertEqual(meta_wl["appliedState"]["dpi"], 96)
                tsukuyomi_win._apply_prefix_hardening_and_theme(prefix, sandbox=True, wayland=False, dxvk=True)
                meta_xw = tsukuyomi_win.read_json(prefix / ".tsukuyomi-prefix.json", {})
                self.assertEqual(meta_xw["appliedState"]["dpi"], 192)


if __name__ == "__main__":
    unittest.main(verbosity=2)
