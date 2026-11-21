# Tsukuyomi OS ISO

Build from the full `tsukuyomi-os` workspace with the sibling `tsukuyomi-shell` and `scripts` directories. The build host needs Arch/CachyOS, `archiso`, Go, `base-devel`, `jq`, and the Arch and CachyOS keyrings. Building Tsukuyomi Monitor also uses Node.js, npm, pkgconf, GTK 3, and WebKitGTK 4.1.

Put the exact upstream Ryoku packages listed in [the input manifest](packages/ryoku-input.sha256) in `/var/cache/pacman/pkg` or set `TSUKUYOMI_RYOKU_CACHE` to an archive directory. Run the build from this repository.

```bash
./buildiso.sh
```

The build verifies the pinned Ryoku archives, packages the desktop and Tsukuyomi Wallpapers, and builds Tsukuyomi Monitor from its pinned source. Set `TSUKUYOMI_SOURCE_CACHE` to override the Monitor source cache at `repo/ryoku/source-cache/`. The first build fetches the source archive and populates the npm and Go dependency caches. The ISO embeds the desktop and CachyOS package repositories, which pacstrap reads during installation. The installer sets the selected browser in the dock and keeps the Tsukuyomi boot, SDDM, and lockscreen stack.

The smaller ISO bundles the same desktop package and fetches the other system packages from mirrors.

```bash
./buildiso.sh -n
```

Find the ISO and SHA-256 checksum in `out/tsukuyomi/`. Run `./testiso.sh` to boot the ISO in QEMU with a disposable virtual disk.
