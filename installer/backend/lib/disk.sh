#!/usr/bin/env bash
# Guided whole-disk GPT layout: 2 GiB EFI System Partition + Btrfs root/LUKS partition.

tsukuyomi_partition_whole() {
  local esp_mib=$(( ${TSUKUYOMI_ESP_GIB:-2} * 1024 ))
  local esp_end_mib=$(( 1 + esp_mib ))

  log "wiping & creating GPT table on %s (ESP=%s MiB)" "$TSUKUYOMI_DISK" "$esp_mib"
  run wipefs -af "$TSUKUYOMI_DISK"
  run sgdisk --zap-all "$TSUKUYOMI_DISK"
  run parted -s "$TSUKUYOMI_DISK" mklabel gpt
  run parted -s "$TSUKUYOMI_DISK" mkpart "ESP" fat32 1MiB "${esp_end_mib}MiB"
  run parted -s "$TSUKUYOMI_DISK" set 1 esp on
  run parted -s "$TSUKUYOMI_DISK" mkpart "TSUKUYOMI" "${esp_end_mib}MiB" 100%

  run partprobe "$TSUKUYOMI_DISK"
  run udevadm settle

  ESP_DEV=$(part_dev "$TSUKUYOMI_DISK" 1)
  ROOT_PART=$(part_dev "$TSUKUYOMI_DISK" 2)
  export ESP_DEV ROOT_PART
  log "partitions ready: ESP=%s ROOT=%s" "$ESP_DEV" "$ROOT_PART"
}
