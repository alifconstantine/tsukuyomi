#!/bin/bash
# Build Tsukuyomi OS Live Installer ISO using mkarchiso.
set -e

src_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
cd "$src_dir"

[[ -r ${src_dir}/util-msg.sh ]] && source "${src_dir}/util-msg.sh"
import "${src_dir}/util.sh"

work_dir="${src_dir}/build"
outFolder="${src_dir}/out"

build_list_iso="tsukuyomi"
clean_first=true
verbose=false
build_in_ram=false
remove_build_dir=false
online_only=false

usage() {
    echo "Usage: ${0##*/} [options]"
    echo '    -c                 Disable clean work dir'
    echo '    -n                 Build a smaller ISO that uses online package mirrors'
    echo '    -r                 Enable building in RAM on systems with >23GB RAM'
    echo '    -w                 Remove build directory after ISO is built'
    echo "    -p <profile>       Profile [default: ${build_list_iso}]"
    echo '    -v                 Verbose output'
    echo '    -h                 This help'
    exit "${1:-0}"
}

opts='p:cnvhrw'
while getopts "${opts}" arg; do
    case "${arg}" in
        c) clean_first=false ;;
        n) online_only=true ;;
        p) build_list_iso="$OPTARG" ;;
        r) build_in_ram=true ;;
        w) remove_build_dir=true ;;
        v) verbose=true ;;
        h|?) usage 0 ;;
        *) echo "invalid argument '${arg}'"; usage 1 ;;
    esac
done
shift $((OPTIND - 1))

timer_start=$(get_timer)

if [[ "$build_in_ram" == "true" ]] && [[ $(grep MemTotal /proc/meminfo | awk '{print int($2/1024/1024)}') -gt 23 ]]; then
    work_dir="$(mktemp -d --suffix="-tsukuyomi-iso")"
fi

prepare_dir "${work_dir}"

import "${src_dir}/util-iso.sh"
import "${src_dir}/util-iso-mount.sh"

check_requirements

for sig in TERM HUP QUIT; do
    trap "trap_exit $sig \"Caught signal %s. Exiting...\" \"$sig\"" "$sig"
done
trap 'trap_exit INT "Aborted by user! Exiting..."' INT
trap 'trap_exit USR1 "An unknown error has occurred. Exiting..."' ERR

run_build "${build_list_iso}"
