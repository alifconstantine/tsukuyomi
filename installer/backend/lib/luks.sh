#!/usr/bin/env bash
# Optional LUKS2 full-disk root encryption.

tsukuyomi_luks_setup() {
  if [[ ${TSUKUYOMI_ENCRYPT:-0} != 1 ]]; then
    ROOT_DEV="$ROOT_PART"
    LUKS_PART=""
    export ROOT_DEV LUKS_PART
    log "encryption: disabled"
    return 0
  fi

  LUKS_PART="$ROOT_PART"
  log "formatting LUKS2 volume on %s" "$LUKS_PART"
  printf '%s' "$TSUKUYOMI_LUKS_PASSPHRASE" | run_secret \
    "cryptsetup luksFormat --type luks2 $LUKS_PART (passphrase via stdin)" \
    cryptsetup luksFormat --batch-mode --type luks2 --pbkdf argon2id --key-file=- "$LUKS_PART"

  printf '%s' "$TSUKUYOMI_LUKS_PASSPHRASE" | run_secret \
    "cryptsetup open $LUKS_PART root (passphrase via stdin)" \
    cryptsetup open --key-file=- "$LUKS_PART" root

  ROOT_DEV="/dev/mapper/root"
  export ROOT_DEV LUKS_PART
}
