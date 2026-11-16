#!/usr/bin/env bash
# Pre-flight validation before touching any target disk.

tsukuyomi_preflight() {
  if [[ -z ${TSUKUYOMI_DRYRUN:-} ]]; then
    (( EUID == 0 )) || die "tsukuyomi-install must run as root"
    [[ -d /sys/firmware/efi ]] || die "UEFI firmware is required for Limine UKI installation"
  fi

  [[ -n ${TSUKUYOMI_DISK:-} ]] || die "TSUKUYOMI_DISK is required"
  if [[ -z ${TSUKUYOMI_DRYRUN:-} ]]; then
    [[ -b $TSUKUYOMI_DISK ]] || die "target disk is not a block device: %s" "$TSUKUYOMI_DISK"
  fi

  [[ $TSUKUYOMI_HOSTNAME =~ ^[a-zA-Z0-9][a-zA-Z0-9-]{0,62}$ ]] \
    || die "invalid hostname: %s" "$TSUKUYOMI_HOSTNAME"

  [[ $TSUKUYOMI_USERNAME =~ ^[a-z_][a-z0-9_-]{0,31}$ ]] \
    || die "invalid username: %s" "$TSUKUYOMI_USERNAME"

  [[ -n ${TSUKUYOMI_PASSWORD_HASH:-} ]] || die "TSUKUYOMI_PASSWORD_HASH is required"

  if [[ ${TSUKUYOMI_ENCRYPT:-0} == 1 ]]; then
    [[ -n ${TSUKUYOMI_LUKS_PASSPHRASE:-} ]] \
      || die "TSUKUYOMI_LUKS_PASSPHRASE is required when encryption is enabled"
  fi

  [[ -d $TSUKUYOMI_SHARE ]] || die "Tsukuyomi data directory not found: %s" "$TSUKUYOMI_SHARE"

  tsukuyomi_cleanup_mounts
  log "preflight passed (disk=%s, user=%s, host=%s, encrypt=%s)" \
    "$TSUKUYOMI_DISK" "$TSUKUYOMI_USERNAME" "$TSUKUYOMI_HOSTNAME" "$TSUKUYOMI_ENCRYPT"
}
