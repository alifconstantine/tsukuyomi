#!/bin/bash
# Tsukuyomi OS ISO build helpers (adapted from CachyOS-Live-ISO).

error_function() {
    if [[ -p ${logpipe:-} ]]; then
        rm "$logpipe"
    fi
    if (( ! BASH_SUBSHELL )); then
        error "A failure occurred in %s()." "$1"
        plain "Aborting..."
    fi
    umount_fs
    umount_img
    exit 2
}

run_safe() {
    local restoretrap func="$1"
    set -e
    set -E
    restoretrap=$(trap -p ERR)
    trap 'error_function $func' ERR

    if ${verbose}; then
        run_log "$func"
    else
        "$func"
    fi

    eval "$restoretrap"
    set +E
    set +e
}

check_umount() {
    if mountpoint -q "$1"; then
        umount -l "$1"
    fi
}

trap_exit() {
    local sig=$1; shift
    error "$@"
    umount_fs
    trap -- "$sig"
    kill "-$sig" "$$"
}

fetch_cachyos_mirrorlist() {
    mkdir -p "${src_dir}/archiso/airootfs/etc/pacman.d"
    local _mirrorlist_url="https://github.com/CachyOS/CachyOS-PKGBUILDS/raw/master/cachyos-mirrorlist/cachyos-mirrorlist"
    if ! curl -fsSL --retry 2 --max-time 20 "${_mirrorlist_url}" > "${src_dir}/archiso/airootfs/etc/pacman.d/cachyos-mirrorlist.tmp"; then
        warning "Could not refresh CachyOS mirrorlist online; keeping existing mirrorlist if present"
        rm -f "${src_dir}/archiso/airootfs/etc/pacman.d/cachyos-mirrorlist.tmp"
        return 0
    fi
    mv "${src_dir}/archiso/airootfs/etc/pacman.d/cachyos-mirrorlist.tmp" "${src_dir}/archiso/airootfs/etc/pacman.d/cachyos-mirrorlist"
}

generate_environment() {
    cat << 'EOF' > "${src_dir}/archiso/airootfs/etc/environment"
ZPOOL_VDEV_NAME_PATH=1
EOF
}

generate_version_tag() {
    echo "$1" > "${src_dir}/archiso/airootfs/etc/version-tag"
}

generate_edition_tag() {
    echo "$1" > "${src_dir}/archiso/airootfs/etc/edition-tag"
}

prepare_profile() {
    profile=$1
    info "Profile: [%s]" "${profile}"

    local _iso_version
    _iso_version="$(date +%y%m%d)"

    # Prepare the target payload before mkarchiso starts. Sudo users build the
    # custom packages and sync as their unprivileged account.
    local workspace_scripts="${src_dir}/../scripts"
    local -a as_builder=()
    if (( EUID == 0 )) && [[ -n ${SUDO_USER:-} ]]; then
        as_builder=(runuser -u "$SUDO_USER" --)
    fi
    if [[ -x "$workspace_scripts/sync-to-iso.sh" ]]; then
        "${as_builder[@]}" "$workspace_scripts/sync-to-iso.sh" --manifests-only
        if ! $online_only; then
            "${as_builder[@]}" "$workspace_scripts/build-end4-repo.sh" --with-offline
        fi
        "${as_builder[@]}" env TSUKUYOMI_ONLINE_ONLY="$online_only" "$workspace_scripts/sync-to-iso.sh" --keep-manifests
    elif ! $online_only; then
        die "Offline ISO requires the tsukuyomi-os workspace with tsukuyomi-shell. Use -n to build an online ISO from this checkout."
    fi

    fetch_cachyos_mirrorlist

    mkdir -p "${src_dir}/archiso/airootfs/etc/systemd/system"
    ln -sf /dev/null "${src_dir}/archiso/airootfs/etc/systemd/system/cachyos-rate-mirrors.timer"
    ln -sf /usr/lib/systemd/system/multi-user.target "${src_dir}/archiso/airootfs/etc/systemd/system/default.target"

    if [[ "$profile" == "tsukuyomi" || "$profile" == "desktop" ]]; then
        cp "${src_dir}/archiso/packages_live.x86_64" "${src_dir}/archiso/packages.x86_64"
    else
        die "Unknown profile: [%s] (supported: tsukuyomi)" "${profile}"
    fi

    generate_environment
    generate_version_tag "${_iso_version}"
    generate_edition_tag "tsukuyomi"

    if (( EUID == 0 )) && [[ -n ${SUDO_UID:-} && -n ${SUDO_GID:-} ]]; then
        chown -R "${SUDO_UID}:${SUDO_GID}" "${src_dir}/archiso/packages.x86_64" \
            "${src_dir}/archiso/airootfs/etc/pacman.d/cachyos-mirrorlist" \
            "${src_dir}/archiso/airootfs/etc/environment" \
            "${src_dir}/archiso/airootfs/etc/version-tag" \
            "${src_dir}/archiso/airootfs/etc/edition-tag" \
            "${src_dir}/archiso/airootfs/etc/systemd/system" 2>/dev/null || true
    fi

    iso_file=$(gen_iso_fn).iso
}

run_build() {
    prepare_profile "$1"
    local _profile="$1"

    msg "Prepare [work: ${work_dir}, out: ${outFolder}]"

    if $clean_first; then
        msg2 "Deleting previous build directory..."
        umount_fs
        [[ -d ${work_dir} ]] && sudo rm -rf "${work_dir}"
    fi

    msg2 "Copying archiso profile into ${work_dir}"
    mkdir -p "${work_dir}"
    cp -a --reflink=auto "${src_dir}/archiso" "${work_dir}/archiso"
    if $online_only; then
        rm -rf -- "${work_dir}/archiso/airootfs/usr/share/tsukuyomi/offline" \
            "${work_dir}/archiso/airootfs/usr/share/tsukuyomi/shell/python"
    fi

    msg "Start [Build ISO]"

    mkdir -p "$outFolder/$_profile"
    cd "${work_dir}/archiso/"
    sudo mkarchiso -v -w "${work_dir}" -o "$outFolder/$_profile" "${work_dir}/archiso/"
    sudo chown -R "$USER" "$outFolder"

    cp "${work_dir}/iso/tsukuyomi/pkglist.x86_64.txt" "$outFolder/$_profile/$(gen_iso_fn).pkgs.txt" 2>/dev/null || true
    local built_iso="$outFolder/$_profile/tsukuyomi-$(date --date="@${SOURCE_DATE_EPOCH:-$(date +%s)}" +%Y.%m.%d)-x86_64.iso"
    if [[ -f "$built_iso" ]]; then
        mv "$built_iso" "$outFolder/$_profile/${iso_file}"
    fi

    msg "Done [Build ISO] ${iso_file}"

    cd "$outFolder/$_profile"
    for f in *.iso; do
        [[ -e $f ]] || continue
        if [[ ! -e $f.sha256 || $f -nt $f.sha256 ]]; then
            create_chksums "$f"
        fi
    done

    show_elapsed_time "${FUNCNAME[0]}" "${timer_start}"
    if [[ "$remove_build_dir" == "true" ]]; then
        msg "Removing build directory ($work_dir)..."
        umount_fs
        [[ -d ${work_dir} ]] && sudo rm -rf "${work_dir}"
    fi
}

gen_iso_fn() {
    printf 'tsukuyomi-%s-linux-%s\n' "${profile}" "$(date +%y%m%d)"
}
