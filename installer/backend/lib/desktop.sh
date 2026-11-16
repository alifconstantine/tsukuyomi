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

  # Temporary DNS inside chroot so uv and AUR helpers can resolve hosts
  local made_resolv=0
  if [[ -z ${TSUKUYOMI_DRYRUN:-} && ! -e /mnt/etc/resolv.conf && -e /etc/resolv.conf ]]; then
    cp -L /etc/resolv.conf /mnt/etc/resolv.conf 2>/dev/null && made_resolv=1 || true
  fi

  # Install local [tsukuyomi-local] AUR repo packages if staged, else per-package paru/yay
  tsukuyomi_install_aur_layer "$user"

  # Prepare end-4 Python venv if online (non-fatal if offline)
  if [[ -f "$TSUKUYOMI_SHARE/shell/requirements.txt" ]] && chroot_has uv; then
    log "setting up end-4 Quickshell Python environment (.venv)"
    run arch-chroot /mnt runuser -u "$user" -- env "HOME=/home/$user" "USER=$user" "LOGNAME=$user" bash -c \
      "mkdir -p ~/.local/state/quickshell && uv venv --prompt .venv ~/.local/state/quickshell/.venv -p 3.12 && uv pip install --python ~/.local/state/quickshell/.venv/bin/python -r /usr/share/tsukuyomi/shell/requirements.txt" \
      || log "warning: uv Python venv setup skipped or offline; run 'uv pip install' on first boot if needed"
  fi

  if (( made_resolv == 1 )); then
    rm -f /mnt/etc/resolv.conf 2>/dev/null || true
  fi

  # Refresh font cache so newly installed icon/UI fonts are immediately discovered
  run arch-chroot /mnt fc-cache -f || true

  # Point default web browser if one was selected
  tsukuyomi_set_default_browser "$user"

  log "enabling target systemd services (sddm, NetworkManager, bluetooth, rtkit, power-profiles-daemon)"
  run arch-chroot /mnt systemctl enable \
    sddm.service \
    NetworkManager.service \
    bluetooth.service \
    rtkit-daemon.service \
    power-profiles-daemon.service

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

  local helper=""
  if chroot_has paru; then
    helper="paru"
  elif chroot_has yay; then
    helper="yay"
  fi
  [[ -n $helper ]] || return 0

  log "installing %d end-4 AUR package(s) via %s (one-by-one)" "${#aur_pkgs[@]}" "$helper"
  write_file /mnt/etc/sudoers.d/99-tsukuyomi-aur-tmp <<EOF
$user ALL=(ALL:ALL) NOPASSWD: ALL
EOF
  run chmod 0440 /mnt/etc/sudoers.d/99-tsukuyomi-aur-tmp

  local pkg
  for pkg in "${aur_pkgs[@]}"; do
    log "AUR: installing %s" "$pkg"
    run arch-chroot /mnt runuser -u "$user" -- env "HOME=/home/$user" "USER=$user" "LOGNAME=$user" \
      timeout 600 "$helper" -S --noconfirm --skipreview --needed "$pkg" \
      || log "warning: AUR package %s failed or timed out (installable later via %s -S %s)" "$pkg" "$helper" "$pkg"
  done

  run rm -f /mnt/etc/sudoers.d/99-tsukuyomi-aur-tmp
}
