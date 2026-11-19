# Tsukuyomi OS ISO

Use the full `tsukuyomi-os` workspace with the sibling `tsukuyomi-shell` and `scripts` directories to build the offline installer. The build host needs Arch/CachyOS, archiso, Go, fakeroot, uv, the Arch and CachyOS keyrings, and the D-Bus, Cairo, and GObject Introspection development libraries for the Python wheels.

Run from this repository:

```bash
./buildiso.sh
```

The build downloads and verifies the target packages, then embeds them with the custom end-4 packages and Python 3.12 runtime. During installation, pacstrap reads the packages directly from the ISO.

For a smaller installer that fetches system packages from mirrors, or a build from this repository alone:

```bash
./buildiso.sh -n
```

Find the ISO and SHA-256 checksum in `out/tsukuyomi/`. Run `./testiso.sh` to boot the ISO in QEMU with a disposable virtual disk.
