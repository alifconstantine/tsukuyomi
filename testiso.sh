#!/usr/bin/env bash
# Boot a built Tsukuyomi ISO in QEMU (UEFI via OVMF) with a disposable virtual disk.
set -euo pipefail

SRC_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
PROFILE="${1:-tsukuyomi}"
OUT_DIR="$SRC_DIR/out/$PROFILE"
VM_DIR="${TSUKUYOMI_VM_DIR:-$SRC_DIR/.vm-test}"
DISK_IMG="$VM_DIR/tsukuyomi-test.qcow2"
DISK_SIZE="${TSUKUYOMI_VM_DISK:-32G}"
RAM_MB="${TSUKUYOMI_VM_RAM:-4096}"
CPUS="${TSUKUYOMI_VM_CPUS:-4}"

iso_path=$(ls -t "$OUT_DIR"/*.iso 2>/dev/null | head -n1 || true)
if [[ -z $iso_path ]]; then
  echo "testiso.sh: no ISO found in $OUT_DIR (run ./buildiso.sh first)" >&2
  exit 1
fi

command -v qemu-system-x86_64 >/dev/null 2>&1 || { echo "qemu-system-x86_64 is required" >&2; exit 1; }
command -v qemu-img >/dev/null 2>&1 || { echo "qemu-img is required" >&2; exit 1; }

ovmf_code=""
for cand in \
  /usr/share/edk2/x64/OVMF_CODE.4m.fd \
  /usr/share/edk2-ovmf/x64/OVMF_CODE.4m.fd \
  /usr/share/edk2/x64/OVMF_CODE.fd \
  /usr/share/OVMF/OVMF_CODE.fd; do
  if [[ -f $cand ]]; then
    ovmf_code=$cand
    break
  fi
done
[[ -n $ovmf_code ]] || { echo "OVMF_CODE.fd not found (install edk2-ovmf)" >&2; exit 1; }

ovmf_vars_tmpl="${ovmf_code/CODE/VARS}"
mkdir -p "$VM_DIR"
ovmf_vars="$VM_DIR/OVMF_VARS.fd"
if [[ ! -f $ovmf_vars ]]; then
  cp "$ovmf_vars_tmpl" "$ovmf_vars"
fi

if [[ ! -f $DISK_IMG ]]; then
  echo "Creating disposable ${DISK_SIZE} virtual disk: $DISK_IMG"
  qemu-img create -f qcow2 "$DISK_IMG" "$DISK_SIZE" >/dev/null
fi

accel_args=()
if [[ -w /dev/kvm ]]; then
  accel_args=(-enable-kvm -cpu host)
fi

echo "Booting $iso_path in QEMU UEFI (${RAM_MB} MiB RAM, ${CPUS} vCPUs)"
exec qemu-system-x86_64 \
  "${accel_args[@]}" \
  -m "$RAM_MB" \
  -smp "$CPUS" \
  -machine q35 \
  -drive if=pflash,format=raw,readonly=on,file="$ovmf_code" \
  -drive if=pflash,format=raw,file="$ovmf_vars" \
  -drive file="$DISK_IMG",if=virtio,format=qcow2 \
  -cdrom "$iso_path" \
  -boot order=d \
  -device virtio-vga-gl \
  -display gtk,gl=on \
  -nic user,model=virtio-net-pci \
  -usb -device usb-tablet
