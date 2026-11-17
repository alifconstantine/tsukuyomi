#!/usr/bin/env bash
# Deploy end-4 (tsukuyomi-shell), fastfetch, SDDM theme, Plymouth theme, and AUR/venv deps.

tsukuyomi_deploy_desktop() {
  local user=$TSUKUYOMI_USERNAME

  log "deploying /etc/skel (tsukuyomi-shell + fastfetch) to target user %s" "$user"
  run mkdir -p /mnt/etc/skel /mnt/usr/local/bin /mnt/usr/share/tsukuyomi
  run cp -a /etc/skel/. /mnt/etc/skel/
  run cp -a /etc/skel/. "/mnt/home/$user/"
  run arch-chroot /mnt chown -R "$user:$user" "/home/$user"
  run arch-chroot /mnt chmod 0700 "/home/$user"

  local bin_name
  for bin_name in \
    tsukuyomi-fetch \
    tsukuyomi-boot-apply \
    tsukuyomi-lock \
    tsukuyomi-greeter \
    tsukuyomi-wayland-session \
    tsukuyomi-greeter-guard; do
    if [[ -x "/usr/local/bin/$bin_name" ]]; then
      run install -m 0755 "/usr/local/bin/$bin_name" "/mnt/usr/local/bin/$bin_name"
    fi
  done
  run cp -a "$TSUKUYOMI_SHARE/." /mnt/usr/share/tsukuyomi/

  if [[ -d "$TSUKUYOMI_SHARE/lockscreen" ]]; then
    run find /mnt/usr/share/tsukuyomi/lockscreen -maxdepth 1 -type f \( -name '*.sh' -o -name 'tsukuyomi-lock' \) -exec chmod 0755 {} +
    if [[ ! -x /mnt/usr/local/bin/tsukuyomi-lock && -f "$TSUKUYOMI_SHARE/lockscreen/tsukuyomi-lock" ]]; then
      run install -m 0755 "$TSUKUYOMI_SHARE/lockscreen/tsukuyomi-lock" /mnt/usr/local/bin/tsukuyomi-lock
    fi
  fi

  # Plymouth theme + ShowDelay=0 so loading bar renders immediately on boot
  if [[ -d "$TSUKUYOMI_SHARE/boot/plymouth/tsukuyomi" ]]; then
    log "installing Tsukuyomi Plymouth theme (ShowDelay=0)"
    run mkdir -p /mnt/usr/share/plymouth/themes/tsukuyomi /mnt/etc/plymouth
    run cp -a "$TSUKUYOMI_SHARE/boot/plymouth/tsukuyomi/." /mnt/usr/share/plymouth/themes/tsukuyomi/
    write_file /mnt/etc/plymouth/plymouthd.conf <<'EOF'
[Daemon]
Theme=tsukuyomi
ShowDelay=0
DeviceTimeout=8
EOF
    run chmod 0644 /mnt/etc/plymouth/plymouthd.conf
    run arch-chroot /mnt plymouth-set-default-theme tsukuyomi
  fi

  # SDDM Wayland kiosk greeter + dark Tsukuyomi theme (Ryoku clockwork/orbital)
  if [[ -d "$TSUKUYOMI_SHARE/sddm/themes/tsukuyomi" ]]; then
    log "configuring Tsukuyomi SDDM Wayland greeter (default session: Hyprland)"
    run mkdir -p /mnt/etc/sddm.conf.d /mnt/usr/share/sddm/themes/tsukuyomi /mnt/etc/systemd/system
    run install -m 0644 "$TSUKUYOMI_SHARE/sddm/10-tsukuyomi.conf" /mnt/etc/sddm.conf.d/10-tsukuyomi.conf
    run cp -a "$TSUKUYOMI_SHARE/sddm/themes/tsukuyomi/." /mnt/usr/share/sddm/themes/tsukuyomi/
    for bin_name in tsukuyomi-greeter tsukuyomi-wayland-session tsukuyomi-greeter-guard; do
      if [[ ! -x "/mnt/usr/local/bin/$bin_name" && -f "$TSUKUYOMI_SHARE/sddm/$bin_name" ]]; then
        run install -m 0755 "$TSUKUYOMI_SHARE/sddm/$bin_name" "/mnt/usr/local/bin/$bin_name"
      fi
    done
    if [[ -f "$TSUKUYOMI_SHARE/sddm/tsukuyomi-greeter-guard.service" ]]; then
      run install -m 0644 "$TSUKUYOMI_SHARE/sddm/tsukuyomi-greeter-guard.service" /mnt/etc/systemd/system/tsukuyomi-greeter-guard.service
    fi

    # Fallback cursor theme for SDDM weston kiosk / greeter surface
    if [[ -n ${TSUKUYOMI_DRYRUN:-} || ! -f /mnt/usr/share/icons/default/index.theme ]]; then
      run mkdir -p /mnt/usr/share/icons/default
      write_file /mnt/usr/share/icons/default/index.theme <<'EOF'
[Icon Theme]
Inherits=Bibata-Modern-Classic
EOF
      run chmod 0644 /mnt/usr/share/icons/default/index.theme
    fi

    # Unlock gnome-keyring cleanly with login password via SDDM PAM
    if [[ -f /mnt/etc/pam.d/sddm ]]; then
      if ! grep -qE '^[[:space:]]*-?auth.*pam_gnome_keyring\.so' /mnt/etc/pam.d/sddm; then
        run sed -i '/^[[:space:]]*auth[[:space:]].*include[[:space:]].*system-login/a auth optional pam_gnome_keyring.so' /mnt/etc/pam.d/sddm
      fi
      if ! grep -qE '^[[:space:]]*-?session.*pam_gnome_keyring\.so' /mnt/etc/pam.d/sddm; then
        run sed -i '/^[[:space:]]*session[[:space:]].*include[[:space:]].*system-login/a session optional pam_gnome_keyring.so auto_start' /mnt/etc/pam.d/sddm
      fi
    elif [[ -n ${TSUKUYOMI_DRYRUN:-} ]]; then
      log "(dry-run) wiring pam_gnome_keyring.so into /mnt/etc/pam.d/sddm"
    fi
  fi

  # Carry live NetworkManager Wi-Fi connections into target
  if [[ -d /etc/NetworkManager/system-connections ]] && compgen -G "/etc/NetworkManager/system-connections/*.nmconnection" >/dev/null; then
    log "copying saved Wi-Fi connection profiles"
    run mkdir -p /mnt/etc/NetworkManager/system-connections
    run cp -a /etc/NetworkManager/system-connections/*.nmconnection /mnt/etc/NetworkManager/system-connections/
    run chmod 0600 /mnt/etc/NetworkManager/system-connections/*.nmconnection
  fi

  # Temporary DNS inside chroot so uv, font fallback, and AUR helpers can resolve hosts
  local made_resolv=0
  local saved_resolv_link=""
  if [[ -z ${TSUKUYOMI_DRYRUN:-} && ! -e /mnt/etc/resolv.conf && -e /etc/resolv.conf ]]; then
    if [[ -L /mnt/etc/resolv.conf ]]; then
      saved_resolv_link=$(readlink /mnt/etc/resolv.conf 2>/dev/null || true)
    fi
    cp -L --remove-destination /etc/resolv.conf /mnt/etc/resolv.conf 2>/dev/null && made_resolv=1 || true
  fi

  # Install local [tsukuyomi-local] AUR repo packages if staged, else staged PKGBUILDs + paru/yay
  tsukuyomi_install_aur_layer "$user"

  # Guarantee Google Sans Flex is installed even if AUR/local repo skipped it
  tsukuyomi_ensure_google_sans_flex

  # Prepare end-4 Python venv if online (non-fatal if offline)
  if [[ -f "$TSUKUYOMI_SHARE/shell/requirements.txt" ]] && chroot_has uv; then
    log "setting up end-4 Quickshell Python environment (.venv)"
    run arch-chroot /mnt runuser -u "$user" -- env \
      "HOME=/home/$user" "USER=$user" "LOGNAME=$user" "UV_LINK_MODE=copy" bash -c \
      "mkdir -p ~/.local/state/quickshell && uv venv --prompt .venv ~/.local/state/quickshell/.venv -p 3.12 && uv pip install --python ~/.local/state/quickshell/.venv/bin/python -r /usr/share/tsukuyomi/shell/requirements.txt" \
      || log "warning: uv Python venv setup skipped or offline; run 'uv pip install' on first boot if needed"
  fi

  if (( made_resolv == 1 )); then
    rm -f /mnt/etc/resolv.conf 2>/dev/null || true
    if [[ -n $saved_resolv_link ]]; then
      ln -s "$saved_resolv_link" /mnt/etc/resolv.conf 2>/dev/null || true
    fi
  fi

  # Refresh font cache so newly installed icon/UI fonts are immediately discovered
  run arch-chroot /mnt fc-cache -f || true

  # Seed end-4 user directories, dark-mode gsettings, and initial wallpaper/Material You palette
  tsukuyomi_seed_end4_defaults "$user"

  # Point default web browser if one was selected
  tsukuyomi_set_default_browser "$user"

  local -a enable_services=(
    sddm.service
    NetworkManager.service
    bluetooth.service
    rtkit-daemon.service
    power-profiles-daemon.service
  )
  if [[ -f /mnt/etc/systemd/system/tsukuyomi-greeter-guard.service || ( -n ${TSUKUYOMI_DRYRUN:-} && -f "$TSUKUYOMI_SHARE/sddm/tsukuyomi-greeter-guard.service" ) ]]; then
    enable_services+=(tsukuyomi-greeter-guard.service)
  fi
  log "enabling target systemd services (%s)" "${enable_services[*]}"
  run arch-chroot /mnt systemctl enable "${enable_services[@]}"
  run arch-chroot /mnt systemctl set-default graphical.target

  run mkdir -p /mnt/etc/systemd/user/default.target.wants
  if [[ -n ${TSUKUYOMI_DRYRUN:-} || -f /mnt/usr/lib/systemd/user/ydotool.service ]]; then
    run ln -sf /usr/lib/systemd/user/ydotool.service /mnt/etc/systemd/user/default.target.wants/ydotool.service
  fi
}

tsukuyomi_set_default_browser() {
  local user=$1 desktop=""
  case "${TSUKUYOMI_BROWSER:-}" in
    brave-bin) desktop="brave-browser.desktop" ;;
    firefox) desktop="firefox.desktop" ;;
    zen-browser-bin) desktop="zen.desktop" ;;
    chromium) desktop="chromium.desktop" ;;
    *) return 0 ;;
  esac
  if [[ -n ${TSUKUYOMI_DRYRUN:-} || -f "/mnt/usr/share/applications/$desktop" ]]; then
    log "default browser: %s" "$desktop"
    run mkdir -p "/mnt/home/$user/.config"
    write_file "/mnt/home/$user/.config/mimeapps.list" <<EOF
[Default Applications]
text/html=$desktop
x-scheme-handler/http=$desktop
x-scheme-handler/https=$desktop
x-scheme-handler/about=$desktop
x-scheme-handler/unknown=$desktop
EOF
    run arch-chroot /mnt chown "$user:$user" "/home/$user/.config/mimeapps.list"
  fi
}

tsukuyomi_ensure_google_sans_flex() {
  if [[ -z ${TSUKUYOMI_DRYRUN:-} ]] && [[ -d /mnt/usr/share/fonts ]] && find /mnt/usr/share/fonts -iname '*GoogleSansFlex*' 2>/dev/null | grep -q .; then
    return 0
  fi
  if [[ -n ${TSUKUYOMI_DRYRUN:-} ]]; then
    log "(dry-run) ensuring Google Sans Flex font is installed in /usr/share/fonts/google-sans-flex"
    return 0
  fi
  if chroot_has git; then
    log "fetching Google Sans Flex variable font (end-4/google-sans-flex)"
    run arch-chroot /mnt bash -c \
      'rm -rf /usr/share/fonts/google-sans-flex && git clone --depth=1 https://github.com/end-4/google-sans-flex /usr/share/fonts/google-sans-flex && rm -rf /usr/share/fonts/google-sans-flex/.git' \
      || log "warning: could not fetch Google Sans Flex font offline; install ttf-google-sans-flex later"
  fi
}

tsukuyomi_seed_end4_defaults() {
  local user=$1

  if chroot_has xdg-user-dirs-update; then
    log "creating XDG user directories for %s" "$user"
    run arch-chroot /mnt runuser -u "$user" -- env "HOME=/home/$user" "USER=$user" "LOGNAME=$user" \
      xdg-user-dirs-update || true
  fi

  if chroot_has gsettings && chroot_has dbus-run-session; then
    log "applying end-4 GTK/GNOME dark theme and font defaults"
    run arch-chroot /mnt runuser -u "$user" -- env "HOME=/home/$user" "USER=$user" "LOGNAME=$user" \
      dbus-run-session -- bash -c "
        gsettings set org.gnome.desktop.interface font-name 'Google Sans Flex Medium 11 @opsz=11,wght=500'
        gsettings set org.gnome.desktop.interface color-scheme 'prefer-dark'
        gsettings set org.gnome.desktop.interface gtk-theme 'adw-gtk3-dark'
      " || log "warning: gsettings default setup skipped"
  fi

  local init_wall="/home/$user/Pictures/Wallpapers/default_wallpaper.png"
  if [[ -z ${TSUKUYOMI_DRYRUN:-} && ! -f "/mnt$init_wall" ]]; then
    init_wall="/home/$user/.config/quickshell/ii/assets/images/default_wallpaper.png"
  fi

  if [[ -n ${TSUKUYOMI_DRYRUN:-} || -f "/mnt$init_wall" ]]; then
    log "seeding initial end-4 wallpaper config and Material You palette"
    run arch-chroot /mnt runuser -u "$user" -- env \
      "HOME=/home/$user" "USER=$user" "LOGNAME=$user" \
      "XDG_CONFIG_HOME=/home/$user/.config" \
      "XDG_CACHE_HOME=/home/$user/.cache" \
      "XDG_STATE_HOME=/home/$user/.local/state" \
      "ILLOGICAL_IMPULSE_VIRTUAL_ENV=/home/$user/.local/state/quickshell/.venv" \
      bash -c '
        wall="$1"
        cfg_dir="$HOME/.config/illogical-impulse"
        state_gen="$HOME/.local/state/quickshell/user/generated"
        script_dir="$HOME/.config/quickshell/ii/scripts/colors"
        mkdir -p "$cfg_dir" "$state_gen/wallpaper"
        if [[ ! -s "$cfg_dir/config.json" ]] && command -v jq >/dev/null 2>&1; then
          jq -n --arg p "$wall" "{background: {wallpaperPath: \$p}}" > "$cfg_dir/config.json"
        fi
        if command -v matugen >/dev/null 2>&1; then
          matugen --source-color-index 0 image "$wall" --mode dark --type scheme-tonal-spot >/dev/null 2>&1 || true
        fi
        if [[ -f "$HOME/.local/state/quickshell/.venv/bin/activate" && -f "$script_dir/generate_colors_material.py" ]]; then
          # shellcheck disable=SC1091
          source "$HOME/.local/state/quickshell/.venv/bin/activate"
          python3 "$script_dir/generate_colors_material.py" \
            --path "$wall" --mode dark --scheme scheme-tonal-spot \
            --termscheme "$script_dir/terminal/scheme-base.json" --blend_bg_fg \
            --harmony 0.6 --harmonize_threshold 100 --term_fg_boost 0.35 \
            --cache "$state_gen/color.txt" > "$state_gen/material_colors.scss" 2>/dev/null || true
          deactivate
          [[ -x "$script_dir/applycolor.sh" ]] && "$script_dir/applycolor.sh" >/dev/null 2>&1 || true
        fi
      ' _ "$init_wall" || log "warning: initial Material You theme generation skipped"
  fi
}

tsukuyomi_install_staged_pkgbuilds() {
  local user=$1
  local pkgbuild_dir name work
  local -a staged_dirs=(
    "$TSUKUYOMI_SHARE/packages/pkgbuilds/ttf-google-sans-flex"
    "$TSUKUYOMI_SHARE/shell/dist-arch/illogical-impulse-bibata-modern-classic-bin"
    "$TSUKUYOMI_SHARE/shell/dist-arch/illogical-impulse-microtex-git"
  )

  for pkgbuild_dir in "${staged_dirs[@]}"; do
    [[ -f "$pkgbuild_dir/PKGBUILD" ]] || continue
    name=$(basename "$pkgbuild_dir")
    log "PKGBUILD: building & installing %s" "$name"
    work="/tmp/tsukuyomi-pkg-$name"
    run rm -rf "/mnt$work"
    run mkdir -p "/mnt$work"
    run cp -a "$pkgbuild_dir/." "/mnt$work/"
    run arch-chroot /mnt chown -R "$user:$user" "$work"
    run arch-chroot /mnt runuser -u "$user" -- env "HOME=/home/$user" "USER=$user" "LOGNAME=$user" \
      bash -c "cd '$work' && timeout 600 makepkg -Afsi --noconfirm --needed" \
      || log "warning: local PKGBUILD %s failed or timed out" "$name"
    run rm -rf "/mnt$work"
  done
}

tsukuyomi_install_aur_layer() {
  local user=$1
  local aur_file="$TSUKUYOMI_SHARE/packages/end4-aur.packages"
  local local_repo="$TSUKUYOMI_SHARE/repo/x86_64"

  if [[ -f "$local_repo/tsukuyomi-local.db.tar.gz" ]]; then
    log "installing end-4 custom packages from staged [tsukuyomi-local] repo"
    local -a local_pkgs=()
    shopt -s nullglob
    local_pkgs=("$local_repo"/*.pkg.tar.zst)
    shopt -u nullglob
    if (( ${#local_pkgs[@]} > 0 )); then
      run mkdir -p /mnt/tmp/tsukuyomi-repo
      run cp -a "${local_pkgs[@]}" /mnt/tmp/tsukuyomi-repo/
      run arch-chroot /mnt bash -c 'pacman -U --noconfirm --needed /tmp/tsukuyomi-repo/*.pkg.tar.zst && rm -rf /tmp/tsukuyomi-repo'
      return 0
    fi
  fi

  [[ ${TSUKUYOMI_INSTALL_AUR:-1} == 1 && -f $aur_file ]] || return 0

  write_file /mnt/etc/sudoers.d/99-tsukuyomi-aur-tmp <<EOF
$user ALL=(ALL:ALL) NOPASSWD: ALL
EOF
  run chmod 0440 /mnt/etc/sudoers.d/99-tsukuyomi-aur-tmp

  tsukuyomi_install_staged_pkgbuilds "$user"

  local -a aur_pkgs=()
  mapfile -t aur_pkgs < <(grep -vE '^[[:space:]]*(#|$|illogical-impulse-|ttf-google-sans-flex$)' "$aur_file" || true)

  local helper=""
  if chroot_has paru; then
    helper="paru"
  elif chroot_has yay; then
    helper="yay"
  fi

  if (( ${#aur_pkgs[@]} > 0 )) && [[ -n $helper ]]; then
    log "installing %d end-4 AUR package(s) via %s (one-by-one)" "${#aur_pkgs[@]}" "$helper"
    local pkg
    for pkg in "${aur_pkgs[@]}"; do
      log "AUR: installing %s" "$pkg"
      run arch-chroot /mnt runuser -u "$user" -- env "HOME=/home/$user" "USER=$user" "LOGNAME=$user" \
        timeout 600 "$helper" -S --noconfirm --skipreview --needed "$pkg" \
        || log "warning: AUR package %s failed or timed out (installable later via %s -S %s)" "$pkg" "$helper" "$pkg"
    done
  fi

  run rm -f /mnt/etc/sudoers.d/99-tsukuyomi-aur-tmp
}
