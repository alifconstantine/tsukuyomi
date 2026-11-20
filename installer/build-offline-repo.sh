#!/usr/bin/env bash
# Bake the target's exact dependencies into a pacman repository for the live ISO.
set -euo pipefail

root_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
pkg_dir="$root_dir/packages"
cache="$root_dir/repo/offline-cache"
out="$root_dir/repo/offline/x86_64"
custom="$root_dir/repo/ryoku/x86_64"

source "$root_dir/installer/backend/lib/common.sh"
source "$root_dir/installer/backend/lib/pacstrap.sh"

(( EUID != 0 )) || die "run the offline repository builder as a regular user"
for tool in fakeroot pacman pacman-key repo-add flock; do
  command -v "$tool" >/dev/null || die "%s is required to build the offline repository" "$tool"
done
[[ -f "$custom/tsukuyomi-local.db" ]] || die "build the desktop repository first with installer/build-ryoku-repo.sh"

mkdir -p "$cache" "$(dirname "$out")"
exec 9>"$cache/build.lock"
flock 9
work=$(mktemp -d "$(dirname "$out")/.bake.XXXXXX")
trap 'rm -rf -- "$work"' EXIT
mkdir "$work/db" "$work/repo" "$work/verify-db"

keyring="$cache/gnupg"
if [[ ! -s "$keyring/pubring.gpg" ]]; then
  fakeroot pacman-key --gpgdir "$keyring" --init
fi
fakeroot pacman-key --gpgdir "$keyring" --populate archlinux cachyos

# Match the ISO's repository order while keeping the host's repos and DB untouched.
online="$work/pacman.conf"
sed "s|/etc/pacman.d/mirrorlist|$root_dir/archiso/airootfs/etc/pacman.d/mirrorlist|g" \
  "$root_dir/archiso/pacman.conf" >"$online"
tsukuyomi_add_file_repo tsukuyomi-local "$custom" >>"$online"
pac=(fakeroot pacman --noconfirm --disable-sandbox --config "$online" --dbpath "$work/db" --gpgdir "$keyring")
"${pac[@]}" -Sy

browsers=(none brave-bin firefox zen-browser-bin chromium)
plans=()
# Auto detection can select multiple GPU sections, with or without the VM section.
hardware=(amd intel nvidia vm)
for ((mask=1; mask < 1 << ${#hardware[@]}; mask++)); do
  sections=()
  for i in "${!hardware[@]}"; do
    (( mask & (1 << i) )) && sections+=("${hardware[i]}")
  done
  for browser in "${browsers[@]}"; do
    targets=$(tsukuyomi_collect_packages "$pkg_dir" "$browser" "${sections[@]}")
    plan="$work/plan-$mask-$browser"
    printf '%s\n' "$targets" >"$plan"
    mapfile -t selection <"$plan"
    if ! "${pac[@]}" -Sp --print-format '%r/%n %f' "${selection[@]}" >>"$work/resolved"; then
      die "package set cannot resolve (hardware: %s; browser: %s)" "${sections[*]}" "$browser"
    fi
    plans+=("$plan")
  done
done

sort -u "$work/resolved" -o "$work/resolved"
mapfile -t downloads < <(awk '$1 !~ /^tsukuyomi-local\// { print $1 }' "$work/resolved")
# Seed the private cache from matching host archives. Pacman can discard an
# invalid cached copy during verification without touching the host cache.
while read -r target archive; do
  [[ $target != tsukuyomi-local/* && ! -e "$cache/$archive" ]] || continue
  src="/var/cache/pacman/pkg/$archive"
  [[ -r $src ]] || continue
  ln "$src" "$cache/$archive" 2>/dev/null || cp --reflink=auto "$src" "$cache/$archive"
done <"$work/resolved"
log "downloading or reusing %d official packages" "${#downloads[@]}"
# Dependencies were resolved above for each supported selection. Download their union
# exactly as selected, including packages that need not coexist on an installed system.
if ! "${pac[@]}" --cachedir "$cache" -Swdd "${downloads[@]}"; then
  log "download failed; retrying once with the archives already cached"
  "${pac[@]}" --cachedir "$cache" -Swdd "${downloads[@]}"
fi
while read -r target archive; do
  [[ $target != tsukuyomi-local/* ]] || continue
  src="$cache/$archive"
  [[ -s $src ]] || die "missing resolved package archive: %s" "$archive"
  ln "$src" "$work/repo/$archive" 2>/dev/null || cp --reflink=auto "$src" "$work/repo/$archive"
done <"$work/resolved"
repo-add "$work/repo/tsukuyomi-offline.db.tar.gz" "$work/repo/"*.pkg.tar.* >"$work/repo-add.log" ||
  { cat "$work/repo-add.log" >&2; die "failed to index the bundled archives"; }

offline="$work/offline.conf"
tsukuyomi_offline_config "$work/repo" "$custom" >"$offline"
fakeroot pacman --config "$offline" --dbpath "$work/verify-db" --disable-sandbox -Sy
for plan in "${plans[@]}"; do
  mapfile -t targets <"$plan"
  tsukuyomi_verify_baked_transaction "$offline" "$work/verify-db" "${targets[@]}" ||
    die "offline package set cannot resolve: %s" "${plan##*/}"
done

if [[ -e $out ]]; then
  mv -- "$out" "$work/previous"
fi
if ! mv -- "$work/repo" "$out"; then
  [[ ! -e $work/previous ]] || mv -- "$work/previous" "$out"
  die "failed to publish the offline repository"
fi
log "offline repo ready at %s (%d tested hardware/browser selections)" "$out" "${#plans[@]}"
