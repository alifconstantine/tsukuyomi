#!/usr/bin/env bash
# Mirror ranking and tiered fallback for pacstrap (modeled on Ryoku's mirrors.sh).

TSUKUYOMI_MIRROR_TIER=0
TSUKUYOMI_MIRROR_SHIPPED=""

tsukuyomi_append_fallback_mirrors() {
  local list=$1
  local marker="# tsukuyomi fallback mirrors"
  grep -qF "$marker" "$list" 2>/dev/null && return 0
  # shellcheck disable=SC2016
  {
    printf '\n%s\n' "$marker"
    printf 'Server = https://fastly.mirror.pkgbuild.com/$repo/os/$arch\n'
    printf 'Server = https://mirrors.kernel.org/archlinux/$repo/os/$arch\n'
    printf 'Server = https://mirror.rackspace.com/archlinux/$repo/os/$arch\n'
    printf 'Server = https://geo.mirror.pkgbuild.com/$repo/os/$arch\n'
  } >>"$list" 2>/dev/null || true
}

tsukuyomi_mirror_tier1_reflector() {
  local out=$1
  command -v reflector >/dev/null 2>&1 || return 1
  timeout 45 reflector --protocol https --age 12 --sort rate --latest 10 --save "$out" 2>/dev/null \
    && grep -q '^Server' "$out"
}

tsukuyomi_mirror_tier2_status_api() {
  local out=$1 json
  command -v jq >/dev/null 2>&1 || return 1
  json=$(curl -fsSL --retry 3 --max-time 25 https://archlinux.org/mirrors/status/json/ 2>/dev/null) || return 1
  printf '%s' "$json" | jq -er '
    [.urls[] | select(.protocol == "https" and .active and (.completion_pct // 0) == 1)]
    | sort_by(.score) | .[:12][] | "Server = " + .url + "$repo/os/$arch"
  ' >"$out" 2>/dev/null || return 1
  grep -q '^Server' "$out"
}

tsukuyomi_tune_pacman_downloads() {
  local parallel=${1:-4}
  local conf=/etc/pacman.conf
  [[ -f $conf ]] || return 0
  if grep -qE '^[[:space:]]*#?[[:space:]]*ParallelDownloads' "$conf" 2>/dev/null; then
    sed -i "s/^[[:space:]]*#\\?[[:space:]]*ParallelDownloads.*/ParallelDownloads = ${parallel}/" "$conf"
  else
    sed -i "/^\[options\]/a ParallelDownloads = ${parallel}" "$conf"
  fi
  grep -qE '^[[:space:]]*DisableDownloadTimeout' "$conf" 2>/dev/null \
    || sed -i '/^\[options\]/a DisableDownloadTimeout' "$conf"
}

tsukuyomi_rank_mirrors() {
  local list=/etc/pacman.d/mirrorlist
  TSUKUYOMI_MIRROR_TIER=0

  if [[ -n ${TSUKUYOMI_DRYRUN:-} ]]; then
    log "mirrors: would tune ParallelDownloads=8 and rank Arch mirrors"
    return 0
  fi

  tsukuyomi_tune_pacman_downloads 8
  TSUKUYOMI_MIRROR_SHIPPED=$(mktemp) && cp -- "$list" "$TSUKUYOMI_MIRROR_SHIPPED" 2>/dev/null || TSUKUYOMI_MIRROR_SHIPPED=""

  local ranked
  ranked=$(mktemp) || return 0

  if tsukuyomi_mirror_tier2_status_api "$ranked"; then
    cp -- "$ranked" "$list" 2>/dev/null || true
    TSUKUYOMI_MIRROR_TIER=2
    log "mirrors: ranked top HTTPS mirrors via Arch mirror-status API"
  elif tsukuyomi_mirror_tier1_reflector "$ranked"; then
    cp -- "$ranked" "$list" 2>/dev/null || true
    TSUKUYOMI_MIRROR_TIER=1
    log "mirrors: ranked mirrors via reflector"
  else
    TSUKUYOMI_MIRROR_TIER=3
    log "mirrors: keeping bundled mirrorlist"
  fi
  rm -f -- "$ranked"
  tsukuyomi_append_fallback_mirrors "$list"
}

tsukuyomi_mirrors_fallback() {
  local list=/etc/pacman.d/mirrorlist
  if [[ -n ${TSUKUYOMI_DRYRUN:-} ]]; then
    log "mirrors: would switch to fallback mirror tier with ParallelDownloads=2"
    return 0
  fi

  tsukuyomi_tune_pacman_downloads 2
  local ranked
  ranked=$(mktemp) || return 1

  if [[ $TSUKUYOMI_MIRROR_TIER != 1 ]] && tsukuyomi_mirror_tier1_reflector "$ranked"; then
    cp -- "$ranked" "$list" 2>/dev/null || true
    TSUKUYOMI_MIRROR_TIER=1
    log "mirrors: switched to reflector fallback mirrors (ParallelDownloads=2)"
  elif [[ -n ${TSUKUYOMI_MIRROR_SHIPPED:-} && -s ${TSUKUYOMI_MIRROR_SHIPPED:-} ]]; then
    cp -- "$TSUKUYOMI_MIRROR_SHIPPED" "$list" 2>/dev/null || true
    TSUKUYOMI_MIRROR_TIER=3
    log "mirrors: switched to bundled CDN mirrors (ParallelDownloads=2)"
  else
    rm -f -- "$ranked"
    return 1
  fi
  rm -f -- "$ranked"
  tsukuyomi_append_fallback_mirrors "$list"
}
