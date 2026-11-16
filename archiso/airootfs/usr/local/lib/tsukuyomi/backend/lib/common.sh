#!/usr/bin/env bash
# Shared logging, dry-run wrapper, and device helpers.

log() {
  printf '[tsukuyomi] '
  printf "$@"
  printf '\n'
}

step() {
  printf '@@TSUKUYOMI_STEP %s\n' "$1"
  log 'stage: %s' "$1"
}

die() {
  printf 'tsukuyomi-install: error: ' >&2
  printf "$@" >&2
  printf '\n' >&2
  exit 1
}

run() {
  if [[ -n ${TSUKUYOMI_DRYRUN:-} ]]; then
    printf 'DRYRUN:'
    printf ' %q' "$@"
    printf '\n'
    return 0
  fi
  "$@"
}

run_sh() {
  if [[ -n ${TSUKUYOMI_DRYRUN:-} ]]; then
    printf 'DRYRUN: %s\n' "$1"
    return 0
  fi
  bash -c "$1"
}

run_secret() {
  local desc=$1
  shift
  if [[ -n ${TSUKUYOMI_DRYRUN:-} ]]; then
    cat >/dev/null
    printf 'DRYRUN: %s\n' "$desc"
    return 0
  fi
  "$@"
}

write_file() {
  local path=$1
  if [[ -n ${TSUKUYOMI_DRYRUN:-} ]]; then
    cat >/dev/null
    printf 'DRYRUN: write %s\n' "$path"
    return 0
  fi
  mkdir -p "$(dirname "$path")"
  cat >"$path"
}

part_dev() {
  local disk=$1 num=$2
  if [[ $disk =~ [0-9]$ ]]; then
    printf '%sp%s\n' "$disk" "$num"
  else
    printf '%s%s\n' "$disk" "$num"
  fi
}

dev_uuid() {
  local dev=$1
  if [[ -n ${TSUKUYOMI_DRYRUN:-} ]]; then
    printf '00000000-0000-0000-0000-000000000000\n'
    return 0
  fi
  blkid -s UUID -o value "$dev"
}

chroot_has() {
  [[ -n ${TSUKUYOMI_DRYRUN:-} ]] && return 0
  arch-chroot /mnt command -v "$1" >/dev/null 2>&1
}

tsukuyomi_cleanup_mounts() {
  [[ -n ${TSUKUYOMI_DRYRUN:-} ]] && return 0
  swapoff -a 2>/dev/null || true
  if mountpoint -q /mnt; then
    umount -R /mnt 2>/dev/null || true
  fi
  if [[ -e /dev/mapper/root ]]; then
    cryptsetup close root 2>/dev/null || true
  fi
}

tsukuyomi_cleanup_on_err() {
  local rc=$1
  tsukuyomi_cleanup_mounts || true
  exit "$rc"
}
