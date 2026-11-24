# Tsukuyomi OS ISO

ISO builder, boot stack (`Limine` UKI + `Plymouth` + `SDDM` Wayland kiosk + `tsukuyomi-lock`), Bubble Tea v2 TUI installer, and offline compatibility runtime (`WinBridge` + `DroidBridge`) for **Tsukuyomi OS** (CachyOS + Hyprland + Ryoku).

## Build Prerequisites

Build from the full `tsukuyomi-os` workspace alongside the sibling `tsukuyomi-shell/` and `scripts/` directories on an Arch/CachyOS host with:

- `archiso`, `base-devel`, `fakeroot`, `git`, `go`, `jq`, `curl`, `libarchive` (`bsdtar`), and the Arch + CachyOS keyrings
- `nodejs`, `npm`, `pkgconf`, `gtk3`, and `webkit2gtk-4.1` (for building **Tsukuyomi Monitor** / `ryomanager`)
- `qemu-desktop` and `edk2-ovmf` (optional, for `./testiso.sh` UEFI VM testing)

Place the pinned upstream Ryoku archives listed in [packages/ryoku-input.sha256](packages/ryoku-input.sha256) (including `ryoku-cursors`) in `/var/cache/pacman/pkg` or set `TSUKUYOMI_RYOKU_CACHE` to their directory.

## Build the ISO

### Offline ISO (recommended)

```bash
./buildiso.sh
```

The build pipeline automatically:
1. Fetches and SHA-256 verifies pre-seeded Android store APKs (`F-Droid.apk`, `AuroraStore.apk`) via `installer/fetch-compat-apks.sh` ([packages/compat-apks.sha256](packages/compat-apks.sha256)).
2. Verifies pinned Ryoku archives and builds the local desktop repo (`tsukuyomi-ryoku-desktop`, `ryoku-shell`, `ryogami`, `ryomanager`, `ryoku-cursors`, Store helpers) via `installer/build-ryoku-repo.sh`. Source archives and Go/npm caches are stored in `repo/ryoku/source-cache/` (override with `TSUKUYOMI_SOURCE_CACHE`).
3. Builds and validates all 150 hardware × browser × Flatpak combinations for the embedded offline CachyOS/Arch repository (`installer/build-offline-repo.sh`), including offline Windows (`wine-staging`, `wine-mono`, `wine-gecko`, `dxvk-mingw-git`, `vkd3d-proton-mingw-git`, `umu-launcher`, `bubblewrap`) and Android (`waydroid`, `waydroid-image`, `android-tools`, `gamescope`) runtimes.
4. Syncs assets and builds the `tsukuyomi-tui` binary via `../scripts/sync-to-iso.sh`, then runs `mkarchiso`.

### Online ISO (smaller image)

Bundles the Tsukuyomi desktop repository and fetches base system packages from mirrors during installation:

```bash
./buildiso.sh -n
```

Output ISO and `.sha256` checksum are written to `out/tsukuyomi/`.

## Test in QEMU (UEFI)

```bash
./testiso.sh
```

Boots the latest built ISO in UEFI QEMU (`edk2-ovmf`) with a disposable virtual disk. Override defaults with `TSUKUYOMI_VM_ISO`, `TSUKUYOMI_VM_RAM`, or `TSUKUYOMI_VM_DISK`.

## Verification

```bash
cd installer/tui && go test -v ./...
python3 -m unittest discover -s system/compat/tests -v
```
