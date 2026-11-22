#!/usr/bin/env bash
# Deploy the Ryoku desktop profile and Tsukuyomi system themes.

tsukuyomi_deploy_desktop() {
  local user=$TSUKUYOMI_USERNAME

  log "deploying Tsukuyomi desktop defaults for %s" "$user"
  local desktop_skel=/mnt/usr/share/tsukuyomi/ryoku/skel
  local user_home="/mnt/home/$user"
  if [[ -z ${TSUKUYOMI_DRYRUN:-} && ! -r "$desktop_skel/.config/ryoku/shell.json" ]]; then
    die "missing packaged Ryoku desktop defaults"
  fi
  run mkdir -p /mnt/etc/skel /mnt/usr/local/bin /mnt/usr/share/tsukuyomi
  run cp -a /etc/skel/. /mnt/etc/skel/
  run cp -a "$desktop_skel/." /mnt/etc/skel/
  run cp -a /mnt/etc/skel/. "$user_home/"
  tsukuyomi_seed_ryoku_dock "$user"
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
  if [[ -n ${TSUKUYOMI_DRYRUN:-} ]]; then
    run cp -a "$TSUKUYOMI_SHARE/." /mnt/usr/share/tsukuyomi/
  else
    local share_item
    for share_item in "$TSUKUYOMI_SHARE"/*; do
      [[ -e $share_item ]] || continue
      case ${share_item##*/} in offline|repo) continue ;; esac
      run cp -a "$share_item" /mnt/usr/share/tsukuyomi/
    done
  fi

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
    log "configuring Tsukuyomi SDDM Wayland greeter (default session: Tsukuyomi)"
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

  # Point default web browser if one was selected
  tsukuyomi_set_default_browser "$user"

  if chroot_has update-mime-database; then
    run arch-chroot /mnt update-mime-database /usr/share/mime || true
  fi
  if chroot_has update-desktop-database; then
    run arch-chroot /mnt update-desktop-database /usr/share/applications || true
  fi

  if [[ ${TSUKUYOMI_FLATPAK:-false} == true ]]; then
    log "registering the Flathub system remote"
    if ! run arch-chroot /mnt flatpak remote-add --system --from --if-not-exists \
      flathub /usr/share/tsukuyomi/flathub.flatpakrepo; then
      log "Flathub setup can be retried from Tsukuyomi Store after login"
    fi
  fi

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


}

tsukuyomi_browser_desktop_entry() {
  case "${TSUKUYOMI_BROWSER:-}" in
    brave-bin) printf '%s\n' brave-browser.desktop ;;
    firefox) printf '%s\n' firefox.desktop ;;
    zen-browser-bin) printf '%s\n' zen.desktop ;;
    chromium) printf '%s\n' chromium.desktop ;;
  esac
}

tsukuyomi_set_default_browser() {
  local user=$1 desktop
  desktop=$(tsukuyomi_browser_desktop_entry)
  [[ -n $desktop ]] || return 0
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

# Bind the initial dock to the same desktop ID used by the browser association.
tsukuyomi_seed_ryoku_dock() {
  local user=$1 browser updated
  local config="/mnt/home/$user/.config/ryoku/shell.json"
  browser=$(tsukuyomi_browser_desktop_entry)
  [[ -n $browser ]] || return 0
  if [[ -z ${TSUKUYOMI_DRYRUN:-} && ! -f "/mnt/usr/share/applications/$browser" ]]; then
    return 0
  fi
  log "pinning %s to the initial dock" "$browser"
  if [[ -n ${TSUKUYOMI_DRYRUN:-} ]]; then return 0; fi
  updated=$(jq --arg browser "${browser%.desktop}"     '.dock.pinned |= (.[0:2] + [$browser] + .[2:])' "$config")
  printf '%s\n' "$updated" >"$config"
}
