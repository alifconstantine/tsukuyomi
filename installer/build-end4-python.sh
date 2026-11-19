#!/usr/bin/env bash
# Prepare the Python interpreter and wheels used by the end-4 shell in an offline install.
set -euo pipefail

root_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
requirements="${1:?path to end-4 requirements.txt is required}"
out="$root_dir/repo/end4-python"
digest=$(sha256sum <"$requirements")
command -v uv >/dev/null || { echo "uv is required to prepare the end-4 Python runtime" >&2; exit 1; }

if [[ -x "$out/interpreter/bin/python3.12" && -r "$out/requirements.sha256" ]] \
  && [[ $(<"$out/requirements.sha256") == "$digest" ]] \
  && compgen -G "$out/wheels/*.whl" >/dev/null; then
  echo "Reusing the bundled end-4 Python runtime"
  exit 0
fi

mkdir -p "$(dirname "$out")"
work=$(mktemp -d "$(dirname "$out")/.end4-python.XXXXXX")
trap 'rm -rf -- "$work"' EXIT
mkdir -p "$work/bundle/wheels"

uv python install 3.12
python=$(uv python find --managed-python 3.12)
python_root=$(dirname "$(dirname "$(realpath "$python")")")
cp -a --reflink=auto "$python_root" "$work/bundle/interpreter"
uv tool run --python "$python" pip wheel --disable-pip-version-check \
  --wheel-dir "$work/bundle/wheels" -r "$requirements"

uv venv --offline --python "$work/bundle/interpreter/bin/python3.12" "$work/check"
uv pip install --offline --no-index --find-links "$work/bundle/wheels" \
  --python "$work/check/bin/python" -r "$requirements"
"$work/check/bin/python" -c 'import cairo, cv2, dbus, gi, materialyoucolor, numpy, PIL'
printf '%s\n' "$digest" > "$work/bundle/requirements.sha256"

if [[ -e $out ]]; then
  mv -- "$out" "$work/previous"
fi
if ! mv -- "$work/bundle" "$out"; then
  [[ ! -e $work/previous ]] || mv -- "$work/previous" "$out"
  exit 1
fi
