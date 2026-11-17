#!/usr/bin/env bash
# Target system configuration: locale, keymap, timezone, branding, user, initramfs.

tsukuyomi_configure() {
  tsukuyomi_cfg_locale
  tsukuyomi_cfg_keymap
  tsukuyomi_cfg_timezone
  tsukuyomi_cfg_branding
  tsukuyomi_cfg_sudo
  tsukuyomi_cfg_account
  tsukuyomi_cfg_initramfs
  tsukuyomi_cfg_crypttab
}

tsukuyomi_cfg_locale() {
  log "locale: %s" "$TSUKUYOMI_LOCALE"
  run sed -i "s|^#\(${TSUKUYOMI_LOCALE//./\\.} \)|\1|" /mnt/etc/locale.gen
  if [[ -z ${TSUKUYOMI_DRYRUN:-} && $TSUKUYOMI_LOCALE == *.* ]] && ! grep -q "^${TSUKUYOMI_LOCALE} " /mnt/etc/locale.gen; then
    printf '%s %s\n' "$TSUKUYOMI_LOCALE" "${TSUKUYOMI_LOCALE##*.}" >> /mnt/etc/locale.gen
  fi
  write_file /mnt/etc/locale.conf <<EOF
LANG=$TSUKUYOMI_LOCALE
EOF
  run arch-chroot /mnt locale-gen
}

tsukuyomi_cfg_keymap() {
  log "keymap: %s" "$TSUKUYOMI_KEYMAP"
  write_file /mnt/etc/vconsole.conf <<EOF
KEYMAP=$TSUKUYOMI_KEYMAP
EOF
}

tsukuyomi_cfg_timezone() {
  local tz=$TSUKUYOMI_TIMEZONE
  if [[ -z ${TSUKUYOMI_DRYRUN:-} && ! -f "/mnt/usr/share/zoneinfo/$tz" ]]; then
    log "timezone %s not found, falling back to UTC" "$tz"
    tz="UTC"
  fi
  log "timezone: %s" "$tz"
  run ln -sf "/usr/share/zoneinfo/$tz" /mnt/etc/localtime
  run arch-chroot /mnt hwclock --systohc
  run arch-chroot /mnt systemctl enable systemd-timesyncd.service
}

tsukuyomi_cfg_branding() {
  log "hostname & OS branding: %s" "$TSUKUYOMI_HOSTNAME"
  write_file /mnt/etc/hostname <<EOF
$TSUKUYOMI_HOSTNAME
EOF
  if [[ -f "$TSUKUYOMI_SHARE/os/os-release" ]]; then
    run install -m 0644 "$TSUKUYOMI_SHARE/os/os-release" /mnt/etc/os-release
  fi
  if [[ -f "$TSUKUYOMI_SHARE/os/lsb-release" ]]; then
    run install -m 0644 "$TSUKUYOMI_SHARE/os/lsb-release" /mnt/etc/lsb-release
  fi
  # Ensure i2c-dev loads for end-4 DDC/brightness integration
  run mkdir -p /mnt/etc/modules-load.d
  write_file /mnt/etc/modules-load.d/i2c-dev.conf <<'EOF'
i2c-dev
EOF
}

tsukuyomi_cfg_sudo() {
  run mkdir -p /mnt/etc/sudoers.d
  write_file /mnt/etc/sudoers.d/10-wheel <<'EOF'
%wheel ALL=(ALL:ALL) ALL
EOF
  run chmod 0440 /mnt/etc/sudoers.d/10-wheel
}

tsukuyomi_cfg_account() {
  local name=$TSUKUYOMI_USERNAME
  local full=$TSUKUYOMI_FULLNAME
  local shell_bin="/usr/bin/bash"
  if [[ ${TSUKUYOMI_LOGIN_SHELL:-bash} == fish ]] && chroot_has fish; then
    shell_bin="/usr/bin/fish"
  fi

  log "creating administrator account: %s (shell=%s)" "$name" "$shell_bin"
  run arch-chroot /mnt groupadd -f i2c
  run btrfs subvolume create "/mnt/home/$name"
  if [[ -n $full ]]; then
    run arch-chroot /mnt useradd -M -U -d "/home/$name" -s "$shell_bin" -G wheel,video,i2c,input,audio -c "$full" "$name"
  else
    run arch-chroot /mnt useradd -M -U -d "/home/$name" -s "$shell_bin" -G wheel,video,i2c,input,audio "$name"
  fi

  printf '%s:%s\n' "$name" "$TSUKUYOMI_PASSWORD_HASH" | run_secret \
    "arch-chroot /mnt chpasswd -e ($name via stdin)" \
    arch-chroot /mnt chpasswd -e
  run arch-chroot /mnt passwd -l root
}

tsukuyomi_cfg_initramfs() {
  local src="$TSUKUYOMI_SHARE/boot/mkinitcpio/tsukuyomi.conf"
  local content
  if [[ -f $src ]]; then
    content=$(<"$src")
  else
    content='HOOKS=(base udev autodetect microcode modconf kms keyboard keymap consolefont plymouth block encrypt resume filesystems fsck)'
  fi
  [[ ${TSUKUYOMI_ENCRYPT:-0} == 1 ]] || content=$(printf '%s\n' "$content" | sed -E '/^HOOKS=/ s/ encrypt\b//')
  run mkdir -p /mnt/etc/mkinitcpio.conf.d
  write_file /mnt/etc/mkinitcpio.conf.d/tsukuyomi.conf <<<"$content"
}

tsukuyomi_cfg_crypttab() {
  [[ ${TSUKUYOMI_ENCRYPT:-0} == 1 ]] || return 0
  local luks_uuid
  luks_uuid=$(dev_uuid "$LUKS_PART") || die "could not read LUKS UUID of %s" "$LUKS_PART"
  write_file /mnt/etc/crypttab <<EOF
root UUID=$luks_uuid none luks
EOF
}
