# Launch Tsukuyomi installer on tty1; leave other VTs as recovery shells.
if [[ "$(tty)" == /dev/tty1 ]]; then
  /usr/local/bin/tsukuyomi-installer-session
fi
