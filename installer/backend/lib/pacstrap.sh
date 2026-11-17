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

TSUKUYOMI_OFFLINE_REPO=""
TSUKUYOMI_OFFLINE_CONF=""

tsukuyomi_offline_active() {
  [[ -n ${TSUKUYOMI_OFFLINE_REPO:-} && -f "$TSUKUYOMI_OFFLINE_REPO/tsukuyomi-offline.db.tar.gz" ]]
}

tsukuyomi_offline_prepare() {
  local cand="$TSUKUYOMI_SHARE/offline/repo"
  [[ -f "$cand/tsukuyomi-offline.db.tar.gz" ]] || return 0
  TSUKUYOMI_OFFLINE_REPO="$cand"
  TSUKUYOMI_OFFLINE_CONF="/tmp/tsukuyomi-offline-pacman.conf"
  if [[ -n ${TSUKUYOMI_DRYRUN:-} ]]; then
    log "offline: would configure [tsukuyomi-offline] -> file://%s" "$cand"
    return 0
  fi
  cat >"$TSUKUYOMI_OFFLINE_CONF" <<EOF
[options]
Architecture = auto
HoldPkg     = pacman glibc
ParallelDownloads = 8
SigLevel    = Never
LocalFileSigLevel = Never

[tsukuyomi-offline]
SigLevel = Never
Server = file://$cand
EOF
  log "offline: using baked [tsukuyomi-offline] repository at %s" "$cand"
}

tsukuyomi_pacstrap_with_retry() {
  local -a pkgs=("$@")

  if tsukuyomi_offline_active; then
    if run pacstrap -C "$TSUKUYOMI_OFFLINE_CONF" -K /mnt --noconfirm "${pkgs[@]}"; then
      [[ -f /etc/pacman.conf ]] && run install -m 0644 /etc/pacman.conf /mnt/etc/pacman.conf
      return 0
    fi
    log "offline pacstrap failed; falling back to online mirrors"
    TSUKUYOMI_OFFLINE_REPO=""
    TSUKUYOMI_OFFLINE_CONF=""
    tsukuyomi_rank_mirrors
  fi

  if run pacstrap -K -P /mnt --noconfirm "${pkgs[@]}"; then
    return 0
  fi

  log "pacstrap failed (mirror reset or transient TLS drop); cleaning partial cache, switching mirror tier, and retrying with --needed"
  run_sh 'rm -f /mnt/var/cache/pacman/pkg/*.part 2>/dev/null || true'
  tsukuyomi_mirrors_fallback || true

  if run pacstrap -K -P /mnt --noconfirm --needed --overwrite '*' "${pkgs[@]}"; then
    return 0
  fi

  log "retrying pacstrap once more with sequential downloads (ParallelDownloads=1)"
  tsukuyomi_tune_pacman_downloads 1
  run_sh 'rm -f /mnt/var/cache/pacman/pkg/*.part 2>/dev/null || true'
  run pacstrap -K -P /mnt --noconfirm --needed --overwrite '*' "${pkgs[@]}"
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

  if [[ -n ${TSUKUYOMI_BROWSER:-} && ${TSUKUYOMI_BROWSER:-none} != none ]]; then
    pkgs+=("$TSUKUYOMI_BROWSER")
  fi

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
  tsukuyomi_offline_prepare
  if ! tsukuyomi_offline_active; then
    tsukuyomi_rank_mirrors
  fi

  log "pacstrapping %d packages into /mnt" "${#unique_pkgs[@]}"
  tsukuyomi_pacstrap_with_retry "${unique_pkgs[@]}"

  log "writing /etc/fstab"
  run_sh "genfstab -U /mnt >> /mnt/etc/fstab"
}
