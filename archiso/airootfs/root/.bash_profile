# Launch Tsukuyomi installer on tty1; leave other VTs as recovery shells.
if [[ -f ~/.bashrc ]]; then
  source ~/.bashrc
fi
if [[ "$(tty 2>/dev/null || true)" == /dev/tty1 ]]; then
  /usr/local/bin/tsukuyomi-installer-session
fi
