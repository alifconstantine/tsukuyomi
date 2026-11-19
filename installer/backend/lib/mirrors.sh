#!/usr/bin/env bash
# Use the bundled CDN mirrorlist first and rank fresh mirrors only after a failure.

tsukuyomi_append_fallback_mirrors() {
  local list=$1
  local marker="# tsukuyomi fallback mirrors"
  grep -qF "$marker" "$list" 2>/dev/null && return 0
  # shellcheck disable=SC2016
  {
    printf '\n%s\n' "$marker"
    printf 'Server = https://fastly.mirror.pkgbuild.com/$repo/os/$arch\n'
    printf 'Server = https://geo.mirror.pkgbuild.com/$repo/os/$arch\n'
    printf 'Server = https://mirrors.kernel.org/archlinux/$repo/os/$arch\n'
    printf 'Server = https://mirror.rackspace.com/archlinux/$repo/os/$arch\n'
  } >>"$list" 2>/dev/null || true
}

tsukuyomi_mirrors_reflector() {
  local out=$1
  command -v reflector >/dev/null 2>&1 || return 1
  timeout 25 reflector --protocol https --age 24 --sort rate --latest 10 --save "$out" 2>/dev/null \
    && grep -q '^Server' "$out"
}

tsukuyomi_mirrors_status_api() {
  local out=$1 json
  command -v jq >/dev/null 2>&1 || return 1
  json=$(curl -fsSL --retry 2 --max-time 15 https://archlinux.org/mirrors/status/json/ 2>/dev/null) || return 1
  printf '%s' "$json" | jq -er '
    [.urls[] | select(.protocol == "https" and .active and (.completion_pct // 0) == 1)]
    | sort_by(.score) | .[:10][] | "Server = " + .url + "$repo/os/$arch"
  ' >"$out" 2>/dev/null || return 1
  grep -q '^Server' "$out"
}

tsukuyomi_tune_pacman_downloads() {
  local parallel=${1:-8}
  local conf=/etc/pacman.conf
  [[ -f $conf ]] || return 0
  if grep -qE '^[[:space:]]*#?[[:space:]]*ParallelDownloads' "$conf" 2>/dev/null; then
    sed -i "s/^[[:space:]]*#\\?[[:space:]]*ParallelDownloads.*/ParallelDownloads = ${parallel}/" "$conf"
  else
    sed -i "/^\[options\]/a ParallelDownloads = ${parallel}" "$conf"
  fi
  # Keep pacman's low-speed timeout enabled so a stalled transport can fail over.
  sed -i '/^[[:space:]]*DisableDownloadTimeout[[:space:]]*$/d' "$conf"
}

tsukuyomi_rank_mirrors() {
  if [[ -n ${TSUKUYOMI_DRYRUN:-} ]]; then
    log "mirrors: would use the bundled CDN mirrorlist (ParallelDownloads=8)"
    return 0
  fi

  tsukuyomi_tune_pacman_downloads 8
  tsukuyomi_append_fallback_mirrors /etc/pacman.d/mirrorlist
  log "mirrors: using the bundled CDN mirrorlist (ParallelDownloads=8)"
}

tsukuyomi_mirrors_fallback() {
  if [[ -n ${TSUKUYOMI_DRYRUN:-} ]]; then
    log "mirrors: would rank alternate mirrors (ParallelDownloads=2)"
    return 0
  fi

  tsukuyomi_tune_pacman_downloads 2 || return 1
  local list=/etc/pacman.d/mirrorlist ranked
  ranked=$(mktemp) || return 1

  if tsukuyomi_mirrors_reflector "$ranked" || tsukuyomi_mirrors_status_api "$ranked"; then
    if cp -- "$ranked" "$list"; then
      log "mirrors: switched to alternate mirrors (ParallelDownloads=2)"
    fi
  fi
  rm -f -- "$ranked"
  tsukuyomi_append_fallback_mirrors "$list"
}
