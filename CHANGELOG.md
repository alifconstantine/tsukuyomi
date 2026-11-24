# Tsukuyomi OS Changelog

## 2026-11-24 — Audit & Hardening Release (pkgrel 38)
- **Arch Linux / Boot / Installer:**
  - Enforced GPG signature verification on `[cachyos]` and enabled `CheckSpace` in target `pacman.conf`.
  - Masked `cachyos-hooks` branding hooks (`cachyos-branding.hook`, `os-release.hook`, `lsb-release.hook`) and added `zz-tsukuyomi-branding.hook` so updates preserve `/etc/os-release` and `/etc/lsb-release`.
  - Added `btrfs-overlayfs` to `mkinitcpio` hooks for bootable Limine Snapper snapshots, bumped default ESP to 2 GiB with `fmask=0077,dmask=0077`, deduplicated EFI NVRAM entries, and enabled `snapper-cleanup.timer`, `fstrim.timer`, and `qemu-guest-agent.service` (on VM).
  - Cleaned live ISO boot errors (`zfs.conf`, 30s `systemd-time-wait-sync` stall, dangling systemd symlinks, `iwd`/`wpa_supplicant` conflict, legacy `end-4` dotfiles in `/etc/skel`), switched live initramfs compression to `zstd`, anchored `profiledef.sh`, and fixed `util-iso.sh` output ownership under `sudo`.
  - Fixed TUI `keyDisk` validation bypass & toggle double-action, UTF-8 Backspace handling, `nmcli` escaped colon parsing, and added early BIOS firmware warning.
- **Session, Hyprland, Store & Monitor:**
  - Bundled `ryoku-cursors` (`Bibata-Modern-Classic`), `ryoku-clamshell`, and all 6 Store Bundle helpers (`ryoku-pkg-*`, `ryoku-gpu-lib32`); moved `hyprglass` to `optdepends` to prevent rolling Hyprland ABI breaks.
  - Restored essential login hooks in `start-desktop`, propagated `TSUKUYOMI_SOFTWARE_RENDERER=1` from frame 1, added `inhibit_sleep = 3` and DPMS-off to `hypridle.conf`, removed 0.5s `loginctl` polling in `SddmShim.qml`, and updated `TimeFormat.qml` to read `~/.config/ryoku/shell.json`.
  - Rebranded `ryoku-cmd-folders` (`Tsukuyomi Folders`) and desktop `notify-send` labels in `ryoku-shell` (pkgrel 3).
  - Hardened `compat-store-setup` and `ryomanager` (pkgrel 3: WebKitGTK DMABUF/GPU policy safety for NVIDIA & `llvmpipe`, IPv4/IPv6, `zram` filter, LUKS/Btrfs mount mapping, NVIDIA RTD3 guard, Papirus icons, `xdg-open` zombie reaping, `iw` added to `base.packages`).
- **Windows & Android Compatibility (WinBridge + DroidBridge):**
  - Fixed Wayland HiDPI double-scaling (`LogPixels = 96` under `winewayland.drv`), added `force-stop` prefix recovery, Squirrel `Update.exe --processStart` + Public Desktop shortcut detection, broad Electron `--disable-gpu` on software renderers, sandboxed window refocus, and Bubblewrap hardening (`--cap-drop ALL`, `--unshare-uts`, `--unshare-cgroup-try`, cursor/PRIME env forwarding, `d3d8`).
  - Defaulted DroidBridge to `standard` Phone viewport on both Mesa and SwiftShader with `ro.sf.lcd_density` and monitor `reserved`/`transform` awareness, fixed `droid-system-init` `cmd_addon` `viewport` crash, disabled Waydroid container boot autostart, added 10-minute auto-idle RAM sleep + `OOMScoreAdjust=500`, atomic `/etc/fstab` & ACL revocation, and stale-session auto-recovery (33/33 unit tests passing).

## 2026-11-22 — Offline Windows & Android Compatibility + Dynamic Notch
- Added offline WinBridge (`wine-staging`, `dxvk-mingw-git`, `vkd3d-proton-mingw-git`, `umu-launcher`, `bubblewrap`) and DroidBridge (`waydroid`, `waydroid-image`, `gamescope`, pre-seeded `F-Droid` & `Aurora Store` APKs).
- Added Dynamic Notch (13 tabs + Hub-styled Settings window), Hub Compatibility page, Launcher `/win` & `/apk` filters, and Store Compat Add-ons (`winboat`, `faugus-launcher`, `proton-cachyos-native`).

## 2026-11-20 — Ryoku Desktop Migration & Flatpak Support
- Migrated target desktop from `end-4` to pinned Ryoku (`08ff328`) with QS Bar Islands, Tsukuyomi Hub, Tsukuyomi Store, Tsukuyomi Wallpapers (`ryogami`), Tsukuyomi Monitor (`ryomanager`), and optional Flatpak + Flathub installer integration.
