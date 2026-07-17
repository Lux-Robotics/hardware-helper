#!/usr/bin/env bash
# Bootstrap Linux build-server deps for Rockchip Universal Imager + rkdeveloptool.
#
# Debian/Ubuntu (apt). Run over SSH as a sudo-capable user (not as root for rustup).
#
#   bash packaging/linux/bootstrap-build-deps.sh
#   bash packaging/linux/bootstrap-build-deps.sh --skip-tauri-cli
#   bash packaging/linux/bootstrap-build-deps.sh --skip-cross
#
# Installs:
#   - build-essential, pkg-config, autoconf, automake, libtool
#   - libusb-1.0-0-dev, libudev-dev, libssl-dev
#   - Tauri/WebKit GTK stack (webkit2gtk-4.1, appindicator, rsvg, patchelf)
#   - git, curl, wget, file, zip, unzip
#   - aarch64 cross toolchain (optional: --skip-cross)
#   - rustup + stable
#   - Rust targets: x86_64-unknown-linux-gnu, aarch64-unknown-linux-gnu
#   - cargo install tauri-cli ^2 (optional: --skip-tauri-cli)
#
set -euo pipefail

SKIP_TAURI_CLI=0
SKIP_CROSS=0
for arg in "$@"; do
  case "$arg" in
    --skip-tauri-cli) SKIP_TAURI_CLI=1 ;;
    --skip-cross)     SKIP_CROSS=1 ;;
    -h|--help)
      sed -n '2,22p' "$0"
      exit 0
      ;;
    *)
      echo "Unknown option: $arg" >&2
      exit 2
      ;;
  esac
done

if [[ "$(uname -s)" != "Linux" ]]; then
  echo "This script is for Linux only." >&2
  exit 1
fi

if [[ "$(id -u)" -eq 0 ]]; then
  echo "Do not run the whole script as root (rustup should own your user home)." >&2
  echo "Run as a normal user with sudo privileges." >&2
  exit 1
fi

if ! command -v sudo >/dev/null 2>&1; then
  echo "sudo is required." >&2
  exit 1
fi

if ! command -v apt-get >/dev/null 2>&1; then
  echo "This script expects apt-get (Debian/Ubuntu). Adapt for other distros." >&2
  exit 1
fi

log() { printf '\n==> %s\n' "$*"; }
have() { command -v "$1" >/dev/null 2>&1; }

# ---------------------------------------------------------------------------
# System packages (apt)
# ---------------------------------------------------------------------------
install_apt_packages() {
  log "Updating apt indices…"
  sudo apt-get update

  local pkgs=(
    # core build
    build-essential
    curl
    wget
    file
    git
    ca-certificates
    pkg-config
    autoconf
    automake
    libtool
    make
    # packaging
    zip
    unzip
    # USB / crypto for app + rkdeveloptool
    libusb-1.0-0-dev
    libudev-dev
    libssl-dev
    # Tauri 2 / WebKitGTK
    libwebkit2gtk-4.1-dev
    libayatana-appindicator3-dev
    librsvg2-dev
    patchelf
  )

  if [[ "$SKIP_CROSS" -eq 0 ]]; then
    pkgs+=(
      gcc-aarch64-linux-gnu
      g++-aarch64-linux-gnu
      # headers for native multiarch where available (best-effort)
      libc6-dev-arm64-cross
    )
  fi

  log "Installing apt packages…"
  sudo DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends "${pkgs[@]}"

  # Optional: multiarch libusb for linking aarch64 targets (may not exist on all releases)
  if [[ "$SKIP_CROSS" -eq 0 ]]; then
    log "Attempting aarch64 multiarch libusb (best-effort)…"
    sudo dpkg --add-architecture arm64 || true
    sudo apt-get update || true
    sudo DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends \
      libusb-1.0-0-dev:arm64 2>/dev/null || \
      echo "  (skipped libusb:arm64 — install a sysroot later if cross-link fails)"
  fi
}

# ---------------------------------------------------------------------------
# Rust
# ---------------------------------------------------------------------------
install_rust() {
  if have rustup; then
    log "rustup already present"
  else
    log "Installing rustup (stable, default)…"
    curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs \
      | sh -s -- -y --default-toolchain stable --profile default
  fi

  # shellcheck source=/dev/null
  source "$HOME/.cargo/env"

  log "Updating stable toolchain…"
  rustup toolchain install stable --profile default
  rustup default stable
  rustup update stable

  log "Adding Linux targets (host + aarch64)…"
  rustup target add x86_64-unknown-linux-gnu
  if [[ "$SKIP_CROSS" -eq 0 ]]; then
    rustup target add aarch64-unknown-linux-gnu
  fi

  # Default linker for aarch64 cross when using the apt cross gcc
  local cargo_cfg="$HOME/.cargo/config.toml"
  if [[ "$SKIP_CROSS" -eq 0 ]] && have aarch64-linux-gnu-gcc; then
    if [[ ! -f "$cargo_cfg" ]] || ! grep -q 'aarch64-unknown-linux-gnu' "$cargo_cfg" 2>/dev/null; then
      log "Writing aarch64 linker hint to $cargo_cfg"
      mkdir -p "$HOME/.cargo"
      {
        echo ""
        echo "# Added by packaging/linux/bootstrap-build-deps.sh"
        echo "[target.aarch64-unknown-linux-gnu]"
        echo 'linker = "aarch64-linux-gnu-gcc"'
      } >>"$cargo_cfg"
    fi
  fi

  log "Rust versions:"
  rustc -vV
  cargo -vV
  rustup show
}

install_tauri_cli() {
  # shellcheck source=/dev/null
  source "$HOME/.cargo/env"
  log "Installing tauri-cli ^2 (cargo install)…"
  cargo install tauri-cli --version "^2" --locked
  cargo tauri --version || true
}

# ---------------------------------------------------------------------------
# Verify
# ---------------------------------------------------------------------------
verify() {
  # shellcheck source=/dev/null
  [[ -f "$HOME/.cargo/env" ]] && source "$HOME/.cargo/env"

  log "Verification"
  local ok=1
  check() {
    local name="$1"
    shift
    if "$@"; then
      printf '  OK  %s\n' "$name"
    else
      printf '  FAIL %s\n' "$name"
      ok=0
    fi
  }

  check "gcc"            have gcc
  check "g++"            have g++
  check "make"           have make
  check "git"            have git
  check "pkg-config"     have pkg-config
  check "libusb (pc)"    pkg-config --exists libusb-1.0
  check "libudev (pc)"   pkg-config --exists libudev
  check "webkit2gtk"     pkg-config --exists webkit2gtk-4.1
  check "autoconf"       have autoconf
  check "automake"       have automake
  check "libtoolize"     have libtoolize
  check "patchelf"       have patchelf
  check "zip"            have zip
  check "unzip"          have unzip
  check "rustup"         have rustup
  check "rustc"          have rustc
  check "cargo"          have cargo
  check "target x86_64"  rustup target list --installed | grep -q x86_64-unknown-linux-gnu
  if [[ "$SKIP_CROSS" -eq 0 ]]; then
    check "aarch64-linux-gnu-gcc" have aarch64-linux-gnu-gcc
    check "target aarch64"        rustup target list --installed | grep -q aarch64-unknown-linux-gnu
  fi
  if [[ "$SKIP_TAURI_CLI" -eq 0 ]]; then
    check "tauri-cli"    cargo tauri --version
  fi

  if [[ "$ok" -eq 1 ]]; then
    log "All checks passed."
    echo
    echo "Next (in the repo):"
    echo "  git submodule update --init --recursive"
    echo "  cargo tauri build --no-bundle --target x86_64-unknown-linux-gnu"
    if [[ "$SKIP_CROSS" -eq 0 ]]; then
      echo "  cargo tauri build --no-bundle --target aarch64-unknown-linux-gnu"
    fi
  else
    log "Some checks failed — see FAIL lines above."
    exit 1
  fi
}

main() {
  log "Linux build-dep bootstrap (user=$(id -un), arch=$(uname -m))"
  install_apt_packages
  install_rust
  if [[ "$SKIP_TAURI_CLI" -eq 0 ]]; then
    install_tauri_cli
  else
    log "Skipping tauri-cli (--skip-tauri-cli)"
  fi
  verify
}

main
