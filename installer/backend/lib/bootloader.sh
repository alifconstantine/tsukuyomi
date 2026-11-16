#!/usr/bin/env bash
# Target Limine bootloader + UKI initramfs + Snapper snapshots.

tsukuyomi_root_cmdline() {
  local root_uuid
  if [[ ${TSUKUYOMI_ENCRYPT:-0} == 1 ]]; then
    local luks_uuid
    luks_uuid=$(dev_uuid "$LUKS_PART") || die "could not read LUKS UUID"
    printf 'cryptdevice=UUID=%s:root root=/dev/mapper/root rootflags=subvol=@ rw\n' "$luks_uuid"
  else
    root_uuid=$(dev_uuid "$ROOT_DEV") || die "could not read root UUID"
    printf 'root=UUID=%s rootflags=subvol=@ rw\n' "$root_uuid"
  fi
}

tsukuyomi_bootloader() {
  local cmdline
  cmdline=$(tsukuyomi_root_cmdline)
  log "Limine cmdline: %s" "$cmdline"

  # Deploy /etc/default/limine
  local def_tmpl="$TSUKUYOMI_SHARE/boot/limine/default.conf"
  if [[ -f $def_tmpl ]]; then
    local def_content
    def_content=$(<"$def_tmpl")
    def_content=${def_content//@@CMDLINE@@/$cmdline}
    write_file /mnt/etc/default/limine <<<"$def_content"
  fi

  # Deploy /boot/limine.conf (ESP root only so no duplicate config shadows it)
  if [[ -f "$TSUKUYOMI_SHARE/boot/limine/limine.conf" ]]; then
    run install -m 0644 "$TSUKUYOMI_SHARE/boot/limine/limine.conf" /mnt/boot/limine.conf
  fi
  run rm -rf /mnt/boot/limine /mnt/boot/EFI/limine/limine.conf

  # Build UKI + initramfs
  if chroot_has limine-mkinitcpio; then
    log "building UKI via limine-mkinitcpio"
    run arch-chroot /mnt limine-mkinitcpio
    chroot_has limine-update && run arch-chroot /mnt limine-update
  else
    log "building initramfs via mkinitcpio -P"
    run arch-chroot /mnt mkinitcpio -P
  fi

  # Install Limine EFI binary + fallback path
  log "installing Limine EFI binaries & NVRAM boot entry"
  run mkdir -p /mnt/boot/EFI/limine /mnt/boot/EFI/BOOT
  run cp -f /mnt/usr/share/limine/BOOTX64.EFI /mnt/boot/EFI/limine/limine_x64.efi
  run cp -f /mnt/usr/share/limine/BOOTX64.EFI /mnt/boot/EFI/BOOT/BOOTX64.EFI

  if [[ -z ${TSUKUYOMI_DRYRUN:-} ]]; then
    local esp_disk esp_partnum
    esp_disk=$(lsblk -no pkname "$ESP_DEV" 2>/dev/null | head -n1 || true)
    esp_partnum=$(cat "/sys/class/block/$(basename "$ESP_DEV")/partition" 2>/dev/null || echo 1)
    if [[ -n $esp_disk ]]; then
      efibootmgr --create --disk "/dev/$esp_disk" --part "$esp_partnum" \
        --label "Tsukuyomi OS" --loader '\EFI\limine\limine_x64.efi' --unicode || true
    fi
  else
    printf 'DRYRUN: efibootmgr --create --label "Tsukuyomi OS" --loader \\EFI\\limine\\limine_x64.efi\n'
  fi

  # Snapper configuration when @snapshots subvolume exists
  if [[ ${TSUKUYOMI_SUBVOL_SNAPSHOTS:-1} == 1 ]] && chroot_has snapper; then
    log "configuring Snapper for root snapshots + Limine menu integration"
    run arch-chroot /mnt umount /.snapshots || true
    run arch-chroot /mnt rmdir /.snapshots || true
    run arch-chroot /mnt snapper --no-dbus -c root create-config /
    run arch-chroot /mnt btrfs subvolume delete /.snapshots || true
    run arch-chroot /mnt mkdir -p /.snapshots
    run arch-chroot /mnt mount -a
    run arch-chroot /mnt chmod 750 /.snapshots
    chroot_has limine-snapper-sync && run arch-chroot /mnt systemctl enable limine-snapper-sync.service
  fi
}

tsukuyomi_finalize() {
  tsukuyomi_hooks_restore
  log "unmounting target filesystems cleanly"
  tsukuyomi_cleanup_mounts
}
