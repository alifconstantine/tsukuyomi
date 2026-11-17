#!/usr/bin/env bash
# shellcheck disable=SC2034

iso_name="tsukuyomi"
iso_label="TSUKUYOMI_$(date --date="@${SOURCE_DATE_EPOCH:-$(date +%s)}" +%Y%m)"
iso_publisher="Tsukuyomi OS"
iso_application="Tsukuyomi OS Live Installer"
iso_version="$(date --date="@${SOURCE_DATE_EPOCH:-$(date +%s)}" +%Y.%m.%d)"
install_dir="tsukuyomi"
buildmodes=('iso')
bootmodes=('bios.syslinux' 'uefi.systemd-boot')
arch="x86_64"
pacman_conf="pacman.conf"
airootfs_image_type="squashfs"
airootfs_image_tool_options=('-comp' 'xz' '-Xbcj' 'x86' '-b' '1M' '-Xdict-size' '1M')
file_permissions=(
  ["/etc/shadow"]="0:0:400"
  ["/etc/gshadow"]="0:0:400"
  ["/root"]="0:0:750"
  ["/etc/polkit-1/rules.d"]="0:0:750"
  ["/etc/sudoers.d"]="0:0:750"
  ["/etc/sudoers.d/g_wheel"]="0:0:440"
  ["/root/.gnupg"]="0:0:700"
  ["/usr/local/bin/choose-mirror"]="0:0:755"
  ["/usr/local/bin/tsukuyomi-installer-session"]="0:0:755"
  ["/usr/local/bin/tsukuyomi-tui"]="0:0:755"
  ["/usr/local/bin/tsukuyomi-install"]="0:0:755"
  ["/usr/local/bin/tsukuyomi-fetch"]="0:0:755"
  ["/usr/local/bin/tsukuyomi-boot-apply"]="0:0:755"
  ["/usr/local/bin/tsukuyomi-lock"]="0:0:755"
  ["/usr/local/bin/tsukuyomi-greeter"]="0:0:755"
  ["/usr/local/bin/tsukuyomi-wayland-session"]="0:0:755"
  ["/usr/local/bin/tsukuyomi-greeter-guard"]="0:0:755"
  ["/usr/local/lib/tsukuyomi/backend/tsukuyomi-install"]="0:0:755"
)
