#!/bin/sh
# Bakes assets/environments/*.ktx from the procedural KovaLink skies.
#
#   sh tool/gpu/make_environments.sh
#
# Filament cmgen (v1.77.2, Apache-2.0) needs glibc >= 2.38, newer than the
# Amazon Linux 2023 worker, so it runs inside the existing Ubuntu 24.04 dev
# image. Override CMGEN_DIR / CMGEN_IMAGE for other hosts; set CMGEN to a
# native cmgen binary to skip docker.
set -eu
cd "$(dirname "$0")/../.."
OUT=build/environments
CMGEN_DIR=${CMGEN_DIR:-$HOME/kova/toolchain/filament-v1.77.2/filament}
CMGEN_IMAGE=${CMGEN_IMAGE:-kova-openpilot-dev:ubuntu24.04}
dart run tool/gpu/make_environments.dart "$OUT"
mkdir -p assets/environments
for hdr in "$OUT"/*.hdr; do
  name=$(basename "$hdr" .hdr)
  if [ -n "${CMGEN:-}" ]; then
    "$CMGEN" --quiet --no-mirror --format=ktx --size=128 --deploy="$OUT/$name" "$hdr"
  else
    sudo docker run --rm -u "$(id -u):$(id -g)" \
      -v "$CMGEN_DIR":/f:ro -v "$PWD/$OUT":/w "$CMGEN_IMAGE" \
      /f/bin/cmgen --quiet --no-mirror --format=ktx --size=128 --deploy="/w/$name" "/w/$name.hdr"
  fi
  cp "$OUT/$name/${name}_ibl.ktx" assets/environments/
  cp "$OUT/$name/${name}_skybox.ktx" assets/environments/
done
ls -l assets/environments
