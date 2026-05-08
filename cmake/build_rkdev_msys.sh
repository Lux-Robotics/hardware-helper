#!/usr/bin/env bash
set -euo pipefail

SRC_DIR="$1"
PREFIX="$2"
BIN_NAME="$3"
PATCH_WERROR="${4:-ON}"

if [[ -z "$SRC_DIR" || -z "$PREFIX" || -z "$BIN_NAME" ]]; then
  echo "build_rkdev_msys: missing arguments" >&2
  exit 1
fi

cd "$SRC_DIR"

if [[ "$PATCH_WERROR" == "ON" ]]; then
  if [[ -f Makefile ]]; then
    sed -i 's/-Werror//g' Makefile
  fi
fi

make clean || true
JOBS=$(nproc 2>/dev/null || echo 1)
make -j"$JOBS"

mkdir -p "$PREFIX/bin"
if [[ -f "$SRC_DIR/$BIN_NAME" ]]; then
  cp -f "$SRC_DIR/$BIN_NAME" "$PREFIX/bin/$BIN_NAME"
elif [[ "$BIN_NAME" == *.exe && -f "$SRC_DIR/${BIN_NAME%.exe}" ]]; then
  cp -f "$SRC_DIR/${BIN_NAME%.exe}" "$PREFIX/bin/$BIN_NAME"
else
  echo "rkdeveloptool binary not found in $SRC_DIR" >&2
  exit 1
fi
