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
airootfs_image_tool_options=('-comp' 'zstd' '-Xcompression-level' '15' '-b' '1M')
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

# mkarchiso copies airootfs/ with --no-preserve=ownership,mode; preserve 0755 on all
# shell/python helpers in /etc/skel/.config and Tsukuyomi runtime asset dirs.
_tsukuyomi_profile_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
_tsukuyomi_airootfs="${_tsukuyomi_profile_dir}/airootfs"
while IFS= read -r -d '' _tsukuyomi_exec; do
  file_permissions["/${_tsukuyomi_exec#${_tsukuyomi_airootfs}/}"]="0:0:755"
done < <(
  find \
    "${_tsukuyomi_airootfs}/etc/skel/.config" \
    "${_tsukuyomi_airootfs}/usr/share/tsukuyomi/boot" \
    "${_tsukuyomi_airootfs}/usr/share/tsukuyomi/fastfetch" \
    "${_tsukuyomi_airootfs}/usr/share/tsukuyomi/lockscreen" \
    "${_tsukuyomi_airootfs}/usr/share/tsukuyomi/sddm" \
    -type f \( -perm -111 -o -name '*.sh' -o -name '*.py' \) \
    -print0 2>/dev/null
)
unset _tsukuyomi_exec _tsukuyomi_profile_dir _tsukuyomi_airootfs
