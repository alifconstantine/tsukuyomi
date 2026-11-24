#!/usr/bin/env bash
# Format ESP + Btrfs subvolumes (@, @home, @log, @pkg, @snapshots, @swap) and mount.

TSUKUYOMI_BTRFS_OPTS="compress=zstd:1,noatime"

tsukuyomi_filesystems() {
  log "formatting ESP (%s) and Btrfs root (%s)" "$ESP_DEV" "$ROOT_DEV"
  run mkfs.vfat -F32 -n TSUKUYOMI "$ESP_DEV"
  run mkfs.btrfs -f -L tsukuyomi "$ROOT_DEV"

  run mount "$ROOT_DEV" /mnt
  run btrfs subvolume create /mnt/@
  run btrfs subvolume create /mnt/@home
  run btrfs subvolume create /mnt/@log
  run btrfs subvolume create /mnt/@pkg
  [[ ${TSUKUYOMI_SUBVOL_SNAPSHOTS:-1} == 1 ]] && run btrfs subvolume create /mnt/@snapshots
  (( ${TSUKUYOMI_SWAP_GIB:-0} > 0 )) && run btrfs subvolume create /mnt/@swap
  run umount /mnt
}

tsukuyomi_mount() {
  local o=$TSUKUYOMI_BTRFS_OPTS
  run mount -o "$o,subvol=@" "$ROOT_DEV" /mnt
  if [[ -z ${TSUKUYOMI_DRYRUN:-} ]]; then
    mount --make-private /mnt
  fi
  run mkdir -p /mnt/home /mnt/var/log /mnt/var/cache/pacman/pkg /mnt/boot
  [[ ${TSUKUYOMI_SUBVOL_SNAPSHOTS:-1} == 1 ]] && run mkdir -p /mnt/.snapshots

  run mount -o "$o,subvol=@home" "$ROOT_DEV" /mnt/home
  run mount -o "$o,subvol=@log" "$ROOT_DEV" /mnt/var/log
  run mount -o "$o,subvol=@pkg" "$ROOT_DEV" /mnt/var/cache/pacman/pkg
  [[ ${TSUKUYOMI_SUBVOL_SNAPSHOTS:-1} == 1 ]] && run mount -o "$o,subvol=@snapshots" "$ROOT_DEV" /mnt/.snapshots
  run mount -o fmask=0077,dmask=0077 "$ESP_DEV" /mnt/boot

  if [[ -z ${TSUKUYOMI_DRYRUN:-} ]]; then
    local esp_avail_kib
    esp_avail_kib=$(df -k --output=avail /mnt/boot | tail -1 | tr -d ' ')
    (( esp_avail_kib >= 65536 )) || die "/boot has %s KiB free; need >= 64 MiB" "$esp_avail_kib"
  fi

  if (( ${TSUKUYOMI_SWAP_GIB:-0} > 0 )); then
    log "creating %s GiB swapfile in @swap" "$TSUKUYOMI_SWAP_GIB"
    run mkdir -p /mnt/swap
    run mount -o noatime,subvol=@swap "$ROOT_DEV" /mnt/swap
    run btrfs filesystem mkswapfile --size "${TSUKUYOMI_SWAP_GIB}g" /mnt/swap/swapfile
    run swapon /mnt/swap/swapfile
  fi
}
