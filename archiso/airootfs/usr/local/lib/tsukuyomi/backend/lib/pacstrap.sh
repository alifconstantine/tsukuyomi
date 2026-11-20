#!/usr/bin/env bash
# Pacstrap CachyOS base + hardware drivers + the Ryoku desktop package.

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

# Pacman uses absolute --hookdir paths, and the last directory takes precedence.
# Keep masks outside the target so pacstrap can unpack the packaged hooks.
tsukuyomi_hooks_quiet() {
  local directory=$1 hook
  run mkdir -p "$directory" /mnt/etc/pacman.d/hooks
  for hook in 05-snap-pac-pre.hook zz-snap-pac-post.hook 80-limine-efi-deploy.hook 90-mkinitcpio-install.hook; do
    run ln -s /dev/null "$directory/$hook"
  done
}

# Build and install use the same package selection, including explicit driver profiles.
tsukuyomi_collect_packages() {
  local pkg_dir=$1 browser=$2 flatpak=$3 sec
  shift 3
  {
    cat "$pkg_dir/base.packages"
    printf '%s\n' tsukuyomi-local/tsukuyomi-ryoku-desktop
    for sec in "$@"; do
      read_pkg_section "$pkg_dir/hardware.packages" "$sec"
    done
    [[ -z $browser || $browser == none ]] || printf '%s\n' "$browser"
    [[ $flatpak != true ]] || printf '%s\n' flatpak
  } | awk '{ sub(/#.*/, ""); gsub(/[[:space:]]/, ""); if (length && !seen[$0]++) print }'
}

tsukuyomi_add_file_repo() {
  printf '\n[%s]\nSigLevel = Never\nServer = file://%s\n' "$1" "$2"
}

tsukuyomi_offline_config() {
  printf '[options]\nArchitecture = auto\nParallelDownloads = 8\nSigLevel = Never\n'
  tsukuyomi_add_file_repo tsukuyomi-offline "$1"
  if [[ -n ${2:-} ]]; then
    tsukuyomi_add_file_repo tsukuyomi-local "$2"
  fi
}

# Resolve against a fresh local database and check every archive before partitioning.
tsukuyomi_verify_baked_transaction() {
  local config=$1 db=$2
  shift 2
  local archive plan
  plan=$(pacman --config "$config" --dbpath "$db" -Sp --print-format '%l' --noconfirm "$@") || return 1
  [[ -n $plan ]] || return 1
  while IFS= read -r archive; do
    [[ $archive == file://* && -s ${archive#file://} ]] || {
      printf 'Missing bundled package: %s\n' "$archive" >&2
      return 1
    }
  done <<<"$plan"
}

TSUKUYOMI_PKG_WORK=""
TSUKUYOMI_OFFLINE_REPO=""
TSUKUYOMI_LOCAL_REPO=""
TSUKUYOMI_TARGET_PACKAGES=()

tsukuyomi_packages_prepare() {
  local pkg_dir="$TSUKUYOMI_SHARE/packages" sections packages
  local -a hw_sections
  sections=$(tsukuyomi_detect_hw_sections) || return 1
  mapfile -t hw_sections <<<"$sections"
  local manifest
  for manifest in base.packages hardware.packages; do
    [[ -r "$pkg_dir/$manifest" ]] || die "missing package list: %s" "$pkg_dir/$manifest"
  done
  packages=$(tsukuyomi_collect_packages "$pkg_dir" "${TSUKUYOMI_BROWSER:-none}" "${TSUKUYOMI_FLATPAK:-false}" "${hw_sections[@]}")
  mapfile -t TSUKUYOMI_TARGET_PACKAGES <<<"$packages"

  if [[ -n ${TSUKUYOMI_DRYRUN:-} ]]; then
    return 0
  fi

  TSUKUYOMI_PKG_WORK=$(mktemp -d)
  local offline="$TSUKUYOMI_SHARE/offline/repo"
  local custom="$TSUKUYOMI_SHARE/repo/x86_64"
  [[ -f "$custom/tsukuyomi-local.db" ]] ||
    die "bundled Ryoku desktop repository is missing; rebuild the ISO"
  TSUKUYOMI_LOCAL_REPO=$custom
  if [[ -d $offline ]]; then
    [[ -f "$offline/tsukuyomi-offline.db" ]] ||
      die "bundled offline repository is incomplete; rebuild the ISO"
    TSUKUYOMI_OFFLINE_REPO=$offline
    log "checking bundled packages for this hardware and browser"
    tsukuyomi_offline_config "$offline" "$TSUKUYOMI_LOCAL_REPO" >"$TSUKUYOMI_PKG_WORK/pacman.conf"
    mkdir "$TSUKUYOMI_PKG_WORK/db"
    pacman --config "$TSUKUYOMI_PKG_WORK/pacman.conf" --dbpath "$TSUKUYOMI_PKG_WORK/db" \
      --disable-sandbox -Sy --noconfirm
    tsukuyomi_verify_baked_transaction "$TSUKUYOMI_PKG_WORK/pacman.conf" "$TSUKUYOMI_PKG_WORK/db" \
      "${TSUKUYOMI_TARGET_PACKAGES[@]}" ||
      die "bundled package set is incomplete for this selection; rebuild the ISO"
  fi
}

tsukuyomi_pacstrap_online() {
  local config=$1
  shift
  if [[ -z ${TSUKUYOMI_DRYRUN:-} ]]; then
    cp /etc/pacman.conf "$config" || return 1
    if [[ -n $TSUKUYOMI_LOCAL_REPO ]]; then
      tsukuyomi_add_file_repo tsukuyomi-local "$TSUKUYOMI_LOCAL_REPO" >>"$config" || return 1
    fi
  fi
  run pacstrap -C "$config" -K /mnt --noconfirm "$@"
}

tsukuyomi_pacstrap() {
  local config="${TSUKUYOMI_PKG_WORK:-/tmp}/pacman.conf"
  local hooks="${TSUKUYOMI_PKG_WORK:-/tmp/tsukuyomi-dryrun}/hooks"
  local -a options=(--hookdir /mnt/etc/pacman.d/hooks --hookdir "$hooks")
  tsukuyomi_hooks_quiet "$hooks"

  if [[ -n $TSUKUYOMI_LOCAL_REPO ]]; then
    options+=(--cachedir "$TSUKUYOMI_LOCAL_REPO")
  fi

  if [[ -n $TSUKUYOMI_OFFLINE_REPO ]]; then
    log "installing %d package targets from the ISO" "${#TSUKUYOMI_TARGET_PACKAGES[@]}"
    # Pacman reads the archives directly off the ISO, without a second disk copy.
    run pacstrap -C "$config" -K /mnt --noconfirm --cachedir "$TSUKUYOMI_OFFLINE_REPO" \
      "${options[@]}" "${TSUKUYOMI_TARGET_PACKAGES[@]}" ||
      die "installation from the ISO failed; see the pacman error above"
  else
    tsukuyomi_ensure_keyring
    tsukuyomi_rank_mirrors
    log "installing %d package targets from online repositories" "${#TSUKUYOMI_TARGET_PACKAGES[@]}"
    if ! tsukuyomi_pacstrap_online "$config" "${options[@]}" "${TSUKUYOMI_TARGET_PACKAGES[@]}"; then
      log "pacstrap failed; retrying with alternate mirrors and keeping the download cache"
      tsukuyomi_mirrors_fallback || true
      tsukuyomi_pacstrap_online "$config" --needed "${options[@]}" "${TSUKUYOMI_TARGET_PACKAGES[@]}" ||
        die "package installation failed after retry; see the pacman error above"
    fi
  fi

  # The installed OS always uses the normal update repositories.
  run install -m 0644 /etc/pacman.conf /mnt/etc/pacman.conf
  run install -m 0644 /etc/pacman.d/cachyos-mirrorlist /mnt/etc/pacman.d/cachyos-mirrorlist
  if [[ -n $TSUKUYOMI_OFFLINE_REPO ]]; then
    run rm -f /mnt/var/lib/pacman/sync/tsukuyomi-offline.db
  fi
  if [[ -n $TSUKUYOMI_LOCAL_REPO ]]; then
    run rm -f /mnt/var/lib/pacman/sync/tsukuyomi-local.db
  fi
  log "writing /etc/fstab"
  run_sh "genfstab -U /mnt >> /mnt/etc/fstab"
}
