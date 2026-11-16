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

  if [[ -x /usr/local/bin/tsukuyomi-fetch ]]; then
    run install -m 0755 /usr/local/bin/tsukuyomi-fetch /mnt/usr/local/bin/tsukuyomi-fetch
  fi
  if [[ -x /usr/local/bin/tsukuyomi-boot-apply ]]; then
    run install -m 0755 /usr/local/bin/tsukuyomi-boot-apply /mnt/usr/local/bin/tsukuyomi-boot-apply
  fi
  run cp -a "$TSUKUYOMI_SHARE/." /mnt/usr/share/tsukuyomi/

  # Plymouth theme
  if [[ -d "$TSUKUYOMI_SHARE/boot/plymouth/tsukuyomi" ]]; then
    log "installing Tsukuyomi Plymouth theme"
    run mkdir -p /mnt/usr/share/plymouth/themes/tsukuyomi
    run cp -a "$TSUKUYOMI_SHARE/boot/plymouth/tsukuyomi/." /mnt/usr/share/plymouth/themes/tsukuyomi/
    run arch-chroot /mnt plymouth-set-default-theme tsukuyomi
  fi

  # SDDM dark theme & config
  if [[ -d "$TSUKUYOMI_SHARE/sddm/themes/tsukuyomi" ]]; then
    log "configuring Tsukuyomi SDDM greeter (default session: Hyprland)"
    run mkdir -p /mnt/etc/sddm.conf.d /mnt/usr/share/sddm/themes/tsukuyomi
    run install -m 0644 "$TSUKUYOMI_SHARE/sddm/10-tsukuyomi.conf" /mnt/etc/sddm.conf.d/10-tsukuyomi.conf
    run cp -a "$TSUKUYOMI_SHARE/sddm/themes/tsukuyomi/." /mnt/usr/share/sddm/themes/tsukuyomi/
  fi

  # Carry live NetworkManager Wi-Fi connections into target
  if [[ -d /etc/NetworkManager/system-connections ]] && compgen -G "/etc/NetworkManager/system-connections/*.nmconnection" >/dev/null; then
    log "copying saved Wi-Fi connection profiles"
    run mkdir -p /mnt/etc/NetworkManager/system-connections
    run cp -a /etc/NetworkManager/system-connections/*.nmconnection /mnt/etc/NetworkManager/system-connections/
    run chmod 0600 /mnt/etc/NetworkManager/system-connections/*.nmconnection
  fi

  # Install local [tsukuyomi-local] AUR repo packages if staged, else best-effort paru
  tsukuyomi_install_aur_layer "$user"

  # Prepare end-4 Python venv if online (non-fatal if offline)
  if [[ -f "$TSUKUYOMI_SHARE/shell/requirements.txt" ]] && chroot_has uv; then
    log "setting up end-4 Quickshell Python environment (.venv)"
    run arch-chroot /mnt su - "$user" -c \
      "mkdir -p ~/.local/state/quickshell && uv venv --prompt .venv ~/.local/state/quickshell/.venv -p 3.12 && uv pip install --python ~/.local/state/quickshell/.venv/bin/python -r /usr/share/tsukuyomi/shell/requirements.txt" \
      || log "warning: uv Python venv setup skipped or offline; run 'uv pip install' on first boot if needed"
  fi

  log "enabling target systemd services (sddm, NetworkManager, bluetooth, rtkit, power-profiles-daemon)"
  run arch-chroot /mnt systemctl enable \
    sddm.service \
    NetworkManager.service \
    bluetooth.service \
    rtkit-daemon.service \
    power-profiles-daemon.service

  # Enable ydotool user service globally for new users (end-4 virtual input helper)
  run mkdir -p /mnt/etc/systemd/user/default.target.wants
  if [[ -n ${TSUKUYOMI_DRYRUN:-} || -f /mnt/usr/lib/systemd/user/ydotool.service ]]; then
    run ln -sf /usr/lib/systemd/user/ydotool.service /mnt/etc/systemd/user/default.target.wants/ydotool.service
  fi
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
  local -a aur_pkgs=()
  mapfile -t aur_pkgs < <(grep -vE '^[[:space:]]*(#|$|illogical-impulse-)' "$aur_file" || true)
  (( ${#aur_pkgs[@]} > 0 )) || return 0

  if chroot_has paru; then
    log "installing end-4 AUR dependencies via paru (%d packages)" "${#aur_pkgs[@]}"
    write_file /mnt/etc/sudoers.d/99-tsukuyomi-aur-tmp <<EOF
$user ALL=(ALL:ALL) NOPASSWD: ALL
EOF
    run chmod 0440 /mnt/etc/sudoers.d/99-tsukuyomi-aur-tmp
    run arch-chroot /mnt su - "$user" -c \
      "paru -S --noconfirm --skipreview --needed ${aur_pkgs[*]}" \
      || log "warning: some AUR packages failed to build (installable later via paru)"
    run rm -f /mnt/etc/sudoers.d/99-tsukuyomi-aur-tmp
  fi
}
