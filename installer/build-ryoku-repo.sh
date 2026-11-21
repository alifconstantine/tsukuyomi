#!/usr/bin/env bash
# Create the local ISO repository from SHA-256-pinned upstream packages.
set -euo pipefail

root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
shell_src=${TSUKUYOMI_SHELL_DIR:-$root/../tsukuyomi-shell}
archive_cache=${TSUKUYOMI_RYOKU_CACHE:-/var/cache/pacman/pkg}
out="$root/repo/ryoku/x86_64"
[[ -x $shell_src/ryoku/stage-profile.sh ]] || { echo 'The Tsukuyomi shell checkout is required.' >&2; exit 1; }

mkdir -p "$(dirname "$out")"
exec 9>"$(dirname "$out")/build.lock"
flock 9
work=$(mktemp -d "$(dirname "$out")/.build.XXXXXXXX")
trap 'rm -rf -- "$work"' EXIT
mkdir "$work/archives" "$work/upstream" "$work/repo" "$work/build"

while read -r digest archive; do
    src="$archive_cache/$archive"
    if [[ ! -r $src ]]; then
        printf 'Pinned Ryoku package is missing from %s: %s\n' "$archive_cache" "$archive" >&2
        exit 1
    fi
    cp --reflink=auto "$src" "$work/archives/$archive"
done < "$root/packages/ryoku-input.sha256"
(cd "$work/archives" && sha256sum -c "$root/packages/ryoku-input.sha256")

for archive in "$work/archives/"*.pkg.tar.zst; do
    case ${archive##*/} in
        ryoku-desktop-hyprland-*)
            bsdtar -xf "$archive" -C "$work/upstream" usr/bin usr/share/ryoku/config ;;
        ryoku-desktop-*)
            bsdtar -xf "$archive" -C "$work/upstream" \
                usr/bin usr/lib/qt6/qml/Ryoku usr/lib/udev/rules.d/90-ryoku-gpu.rules \
                usr/share/ryoku/config \
                usr/share/ryoku/brand usr/share/ryoku/i18n ;;
        ryogami-*)
            mkdir -p "$work/wallpapers/payload"
            bsdtar -xf "$archive" -C "$work/wallpapers/payload" usr ;;
        *) mv -- "$archive" "$work/repo/" ;;
    esac
done

upstream="$work/upstream/usr/share/ryoku"
"$shell_src/ryoku/stage-profile.sh" "$upstream/config/quickshell" "$work/profile"
payload="$work/build/payload"
data="$payload/usr/share/ryoku"
skel="$payload/usr/share/tsukuyomi/ryoku/skel"
mkdir -p "$data/config" "$payload/usr/lib/qt6/qml" "$payload/usr/bin" "$skel"
cp -a "$upstream/brand" "$upstream/i18n" "$data/"
cp -a "$upstream/config/"{matugen,qt6ct} "$data/config/"
cp -a "$work/upstream/usr/lib/qt6/qml/Ryoku" "$payload/usr/lib/qt6/qml/"
mv "$work/profile/.config/"{hypr,quickshell} "$data/config/"
cp -a "$work/profile/." "$skel/"
cp -a "$data/config/"{hypr,matugen,qt6ct} "$skel/.config/"
for module in binds decoration perf_saver window_rules; do
    ln -sfn "/usr/share/ryoku/config/hypr/modules/$module.lua" "$skel/.config/hypr/modules/$module.lua"
done
ln -s /usr/share/ryoku/config/quickshell "$skel/.config/quickshell"
install -Dm644 "$shell_src/ryoku/tsukuyomi-store.desktop" "$payload/usr/share/applications/tsukuyomi-store.desktop"

for helper in ryostore ryostore-install ryoku-plugins-place ryoku-monitor ryoku-wm-hyprland ryoku-workspace ryoku-bt-audio \
    ryoku-bluetooth-power ryoku-bluetooth-reset ryoku-media ryoku-volume ryoku-gpu ryoku-gpu-detect; do
    install -m 755 "$work/upstream/usr/bin/$helper" "$payload/usr/bin/"
done
install -Dm644 "$work/upstream/usr/lib/udev/rules.d/90-ryoku-gpu.rules" \
    "$payload/usr/lib/udev/rules.d/90-ryoku-gpu.rules"
ln -s /usr/local/bin/tsukuyomi-lock "$payload/usr/bin/ryoku-qylock-lock"
cp -a "$root/system/lockscreen" "$payload/usr/share/tsukuyomi/session-lockscreen"
ln -s /usr/share/tsukuyomi/session-lockscreen/theme-config.sh "$payload/usr/bin/tsukuyomi-lock-theme"
ln -s session-lockscreen "$payload/usr/share/tsukuyomi/quickshell-lockscreen"
cp -a "$root/system/desktop/rootfs/." "$payload/"
install -Dm644 "$shell_src/ryoku/upstream/LICENSE" "$payload/usr/share/licenses/tsukuyomi-ryoku-desktop/LICENSE"
install -Dm644 "$shell_src/ryoku/upstream/NOTICE" "$payload/usr/share/licenses/tsukuyomi-ryoku-desktop/NOTICE"
install -m 644 "$root/system/desktop/autostart.lua" "$data/config/hypr/modules/autostart.lua"
install -m 644 "$root/system/desktop/autostart.lua" "$skel/.config/hypr/modules/autostart.lua"
install -m 644 "$root/system/desktop/hypridle.conf" "$skel/.config/hypr/"

wallpapers="$work/wallpapers"
for change in "$shell_src"/ryoku/wallpaper-patches/*.patch; do
    patch --batch --forward --fuzz=0 \
        -d "$wallpapers/payload/usr/lib/qt6/qml/Ryoku/Ryogami" -p1 < "$change"
done
sed -i 's/^Name=Ryogami Wallpapers$/Name=Tsukuyomi Wallpapers/' \
    "$wallpapers/payload/usr/share/applications/ryogami.desktop"
cp "$root/packages/pkgbuilds/ryogami/PKGBUILD" "$wallpapers/"
(cd "$wallpapers" && PKGDEST="$work/repo" makepkg --nodeps --noconfirm)

monitor="$work/monitor"
mkdir -p "$monitor"
cp "$root/packages/pkgbuilds/ryomanager/"{PKGBUILD,ryomanager.desktop} "$monitor/"
cp "$shell_src/ryoku/monitor-patches/01-tsukuyomi-monitor.patch" "$monitor/"
# makepkg caches the verified upstream archive between ISO builds.
monitor_cache=${TSUKUYOMI_SOURCE_CACHE:-$root/repo/ryoku/source-cache}
mkdir -p "$monitor_cache"
monitor_cache=$(realpath -- "$monitor_cache")
(cd "$monitor" && SRCDEST="$monitor_cache" PKGDEST="$work/repo" makepkg --nodeps --noconfirm)

cp "$root/packages/pkgbuilds/tsukuyomi-ryoku-desktop/PKGBUILD" "$work/build/"
(cd "$work/build" && PKGDEST="$work/repo" makepkg --nodeps --noconfirm)
repo-add "$work/repo/tsukuyomi-local.db.tar.gz" "$work/repo/"*.pkg.tar.zst
if [[ -e $out ]]; then mv -- "$out" "$work/previous"; fi
if ! mv -- "$work/repo" "$out"; then
    [[ ! -e $work/previous ]] || mv -- "$work/previous" "$out"
    exit 1
fi
