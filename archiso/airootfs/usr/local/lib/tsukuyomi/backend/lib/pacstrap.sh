#!/usr/bin/env bash
# Pacstrap CachyOS base + hardware drivers + end-4 repository dependencies.

read_pkg_section() {
  local file=$1 sec=$2
  awk -v sec="[$sec]" '
    $0 == sec { f = 1; next }
    /^\[/ { f = 0 }
    f && NF && $0 !~ /^[[:space:]]*#/ { print }
  ' "$file"
}

tsukuyomi_detect_hw_sections() {
  if [[ ${TSUKUYOMI_PROFILE:-auto} != auto ]]; then
    case "$TSUKUYOMI_PROFILE" in
      amd) printf '%s\n' amd ;;
      intel) printf '%s\n' intel ;;
      nvidia|amd-nvidia) printf '%s\n' amd intel nvidia ;;
      vm) printf '%s\n' vm ;;
      *) die "unknown TSUKUYOMI_PROFILE: %s" "$TSUKUYOMI_PROFILE" ;;
    esac
    return 0
  fi

  local -a sections=()
  if command -v systemd-detect-virt >/dev/null 2>&1 && systemd-detect-virt -q --vm 2>/dev/null; then
    sections+=(vm)
  fi
  if command -v lspci >/dev/null 2>&1; then
    local vga
    vga=$(lspci -nn | grep -iE 'vga|3d|display' || true)
    [[ $vga == *1002:* ]] && sections+=(amd)
    [[ $vga == *8086:* ]] && sections+=(intel)
    [[ $vga == *10de:* ]] && sections+=(nvidia)
  fi
  (( ${#sections[@]} )) || sections=(vm)
  printf '%s\n' "${sections[@]}" | awk '!seen[$0]++'
}

tsukuyomi_ensure_keyring() {
  run_sh 'systemctl start pacman-init.service 2>/dev/null || true'
  if [[ -n ${TSUKUYOMI_DRYRUN:-} ]]; then
    return 0
  fi
  if [[ -z "$(pacman-key --list-keys 2>/dev/null)" ]]; then
    log "initializing pacman keyring (archlinux + cachyos)"
    run pacman-key --init
    run pacman-key --populate archlinux cachyos
  fi
}

TSUKUYOMI_MASKED_HOOKS=(05-snap-pac-pre.hook zz-snap-pac-post.hook 80-limine-efi-deploy.hook)

tsukuyomi_hooks_quiet() {
  run mkdir -p /mnt/etc/pacman.d/hooks
  local h
  for h in "${TSUKUYOMI_MASKED_HOOKS[@]}"; do
    run ln -sf /dev/null "/mnt/etc/pacman.d/hooks/$h"
  done
}

tsukuyomi_hooks_restore() {
  local h p
  for h in "${TSUKUYOMI_MASKED_HOOKS[@]}"; do
    p="/mnt/etc/pacman.d/hooks/$h"
    if [[ -n ${TSUKUYOMI_DRYRUN:-} || -L $p ]]; then
      run rm -f "$p"
    fi
  done
}

tsukuyomi_pacstrap() {
  local base_file="$TSUKUYOMI_SHARE/packages/base.packages"
  local hw_file="$TSUKUYOMI_SHARE/packages/hardware.packages"
  local end4_file="$TSUKUYOMI_SHARE/packages/end4-repo.packages"

  [[ -f $base_file ]] || die "missing package list: %s" "$base_file"
  [[ -f $end4_file ]] || die "missing package list: %s" "$end4_file"

  local -a pkgs=()
  mapfile -t pkgs < <(grep -vE '^[[:space:]]*(#|$)' "$base_file")

  local sec
  while IFS= read -r sec; do
    [[ -n $sec && -f $hw_file ]] || continue
    mapfile -t -O "${#pkgs[@]}" pkgs < <(read_pkg_section "$hw_file" "$sec")
  done < <(tsukuyomi_detect_hw_sections)

  mapfile -t -O "${#pkgs[@]}" pkgs < <(grep -vE '^[[:space:]]*(#|$)' "$end4_file")

  # Deduplicate while preserving order
  local -a unique_pkgs=()
  local -A seen=()
  local p
  for p in "${pkgs[@]}"; do
    p=${p%%#*}
    p=${p// /}
    [[ -n $p && -z ${seen[$p]+x} ]] || continue
    seen[$p]=1
    unique_pkgs+=("$p")
  done

  tsukuyomi_ensure_keyring
  tsukuyomi_hooks_quiet

  if command -v reflector >/dev/null 2>&1 && [[ -z ${TSUKUYOMI_DRYRUN:-} ]]; then
    log "ranking fastest Arch mirrors"
    reflector --latest 10 --protocol https --sort rate --save /etc/pacman.d/mirrorlist 2>/dev/null || true
  fi

  log "pacstrapping %d packages into /mnt" "${#unique_pkgs[@]}"
  run pacstrap -K /mnt --noconfirm "${unique_pkgs[@]}"

  log "writing /etc/fstab"
  run_sh "genfstab -U /mnt >> /mnt/etc/fstab"
}
