#!/usr/bin/env bash
# Bootstrap macOS build-server deps for Rockchip Universal Imager + rkdeveloptool.
#
# Safe over SSH (non-interactive where possible). Run as a normal admin user
# that can use Homebrew (not root). Example:
#
#   curl -fsSL … | bash          # if you host this somewhere
#   bash packaging/macos/bootstrap-build-deps.sh
#   bash packaging/macos/bootstrap-build-deps.sh --skip-tauri-cli
#
# Installs:
#   - Xcode Command Line Tools (if missing)
#   - Homebrew (if missing)
#   - brew: libusb pkg-config automake autoconf libtool
#   - zip/unzip (via brew if missing from system)
#   - rustup + stable (1.85+ expected by the project)
#   - Rust targets: aarch64-apple-darwin, x86_64-apple-darwin
#   - cargo install tauri-cli ^2 (optional: --skip-tauri-cli)
#
set -euo pipefail

SKIP_TAURI_CLI=0
for arg in "$@"; do
  case "$arg" in
    --skip-tauri-cli) SKIP_TAURI_CLI=1 ;;
    -h|--help)
      sed -n '2,20p' "$0"
      exit 0
      ;;
    *)
      echo "Unknown option: $arg" >&2
      exit 2
      ;;
  esac
done

if [[ "$(uname -s)" != "Darwin" ]]; then
  echo "This script is for macOS only." >&2
  exit 1
fi

if [[ "$(id -u)" -eq 0 ]]; then
  echo "Do not run as root. Run as the build user that will own Homebrew/rustup." >&2
  exit 1
fi

log() { printf '\n==> %s\n' "$*"; }
have() { command -v "$1" >/dev/null 2>&1; }

# ---------------------------------------------------------------------------
# Xcode Command Line Tools
# ---------------------------------------------------------------------------
install_clt() {
  if xcode-select -p >/dev/null 2>&1; then
    log "Xcode Command Line Tools already present: $(xcode-select -p)"
    return 0
  fi

  log "Installing Xcode Command Line Tools (non-interactive via softwareupdate)…"
  # Flag so softwareupdate lists the CLT package on headless Macs.
  local touchfile="/tmp/.com.apple.dt.CommandLineTools.installondemand.in-progress"
  sudo touch "$touchfile"

  local label
  label="$(softwareupdate -l 2>/dev/null \
    | grep -E '^\s*\*\s*Label:\s*Command Line Tools' \
    | sed -E 's/^[[:space:]]*\*[[:space:]]*Label:[[:space:]]*//' \
    | tail -n 1 || true)"

  if [[ -z "$label" ]]; then
    # Fallback listing style on some macOS versions
    label="$(softwareupdate -l 2>/dev/null \
      | grep -E 'Command Line Tools for Xcode' \
      | sed -E 's/^[[:space:]]*\*[[:space:]]*//' \
      | sed -E 's/^Label:[[:space:]]*//' \
      | tail -n 1 || true)"
  fi

  if [[ -z "$label" ]]; then
    sudo rm -f "$touchfile"
    echo "Could not find a CLT package via softwareupdate." >&2
    echo "On a machine with UI, run: xcode-select --install" >&2
    echo "Or open Settings → General → Software Update." >&2
    exit 1
  fi

  log "Installing: $label"
  sudo softwareupdate -i "$label" --verbose
  sudo rm -f "$touchfile"

  if ! xcode-select -p >/dev/null 2>&1; then
    # Point at default CLT path if needed
    sudo xcode-select --switch /Library/Developer/CommandLineTools 2>/dev/null || true
  fi

  if ! xcode-select -p >/dev/null 2>&1; then
    echo "CLT install finished but xcode-select -p still fails." >&2
    exit 1
  fi
  log "CLT OK: $(xcode-select -p)"
}

# ---------------------------------------------------------------------------
# Homebrew
# ---------------------------------------------------------------------------
install_homebrew() {
  if have brew; then
    log "Homebrew already present: $(brew --prefix)"
    return 0
  fi

  log "Installing Homebrew…"
  NONINTERACTIVE=1 /bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"

  # Apple Silicon default prefix
  if [[ -x /opt/homebrew/bin/brew ]]; then
    eval "$(/opt/homebrew/bin/brew shellenv)"
  elif [[ -x /usr/local/bin/brew ]]; then
    eval "$(/usr/local/bin/brew shellenv)"
  fi

  if ! have brew; then
    echo "Homebrew installed but 'brew' not on PATH. Add brew shellenv to your profile." >&2
    exit 1
  fi
}

ensure_brew_on_path() {
  if have brew; then
    return 0
  fi
  if [[ -x /opt/homebrew/bin/brew ]]; then
    eval "$(/opt/homebrew/bin/brew shellenv)"
  elif [[ -x /usr/local/bin/brew ]]; then
    eval "$(/usr/local/bin/brew shellenv)"
  fi
}

persist_brew_shellenv() {
  local profile=""
  case "${SHELL:-}" in
    */zsh)  profile="${ZDOTDIR:-$HOME}/.zprofile" ;;
    */bash) profile="$HOME/.bash_profile" ;;
    *)      profile="$HOME/.profile" ;;
  esac

  local line
  if [[ -x /opt/homebrew/bin/brew ]]; then
    line='eval "$(/opt/homebrew/bin/brew shellenv)"'
  elif [[ -x /usr/local/bin/brew ]]; then
    line='eval "$(/usr/local/bin/brew shellenv)"'
  else
    return 0
  fi

  if [[ -f "$profile" ]] && grep -Fq 'brew shellenv' "$profile" 2>/dev/null; then
    return 0
  fi
  log "Adding brew shellenv to $profile"
  {
    echo ""
    echo "# Homebrew (added by bootstrap-build-deps.sh)"
    echo "$line"
  } >>"$profile"
}

# ---------------------------------------------------------------------------
# Brew packages
# ---------------------------------------------------------------------------
install_brew_packages() {
  ensure_brew_on_path
  log "Updating Homebrew (quiet)…"
  brew update --quiet || brew update

  local pkgs=(libusb pkg-config automake autoconf libtool)
  # zip/unzip are usually system; brew as fallback if missing
  have zip   || pkgs+=(zip)
  have unzip || pkgs+=(unzip)

  log "Installing brew packages: ${pkgs[*]}"
  brew install "${pkgs[@]}"

  # Useful for dual-arch linking on Apple Silicon when building x86_64
  if [[ "$(uname -m)" == "arm64" ]]; then
    log "Apple Silicon: ensuring libusb is linked"
    brew link libusb --force 2>/dev/null || true
  fi
}

# ---------------------------------------------------------------------------
# Rust / rustup
# ---------------------------------------------------------------------------
install_rust() {
  if have rustup; then
    log "rustup already present"
  else
    log "Installing rustup (stable, default)…"
    curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs \
      | sh -s -- -y --default-toolchain stable --profile default
  fi

  # shellenv for this session
  # shellcheck source=/dev/null
  source "$HOME/.cargo/env"

  log "Updating stable toolchain…"
  rustup toolchain install stable --profile default
  rustup default stable
  rustup update stable

  log "Adding Apple targets (native + cross arch)…"
  rustup target add aarch64-apple-darwin
  rustup target add x86_64-apple-darwin

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
  ensure_brew_on_path

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

  check "xcode-select"   xcode-select -p
  check "clang"          have clang
  check "make"           have make
  check "git"            have git
  check "brew"           have brew
  check "pkg-config"     have pkg-config
  check "libusb (pc)"    pkg-config --exists libusb-1.0
  check "autoconf"       have autoconf
  check "automake"       have automake
  check "libtoolize/libtool"  bash -c 'command -v libtoolize >/dev/null || command -v glibtoolize >/dev/null || command -v libtool >/dev/null'
  check "zip"            have zip
  check "unzip"          have unzip
  check "rustup"         have rustup
  check "rustc"          have rustc
  check "cargo"          have cargo
  check "target aarch64" rustup target list --installed | grep -q aarch64-apple-darwin
  check "target x86_64"  rustup target list --installed | grep -q x86_64-apple-darwin
  if [[ "$SKIP_TAURI_CLI" -eq 0 ]]; then
    check "tauri-cli"    cargo tauri --version
  fi

  if [[ "$ok" -eq 1 ]]; then
    log "All checks passed."
    echo
    echo "Next (in the repo):"
    echo "  git submodule update --init --recursive"
    echo "  cargo tauri build --no-bundle --target aarch64-apple-darwin"
    echo "  # and/or: --target x86_64-apple-darwin"
  else
    log "Some checks failed — see FAIL lines above."
    exit 1
  fi
}

# ---------------------------------------------------------------------------
main() {
  log "macOS build-dep bootstrap (user=$(id -un), arch=$(uname -m))"
  install_clt
  install_homebrew
  ensure_brew_on_path
  persist_brew_shellenv
  install_brew_packages
  install_rust
  if [[ "$SKIP_TAURI_CLI" -eq 0 ]]; then
    install_tauri_cli
  else
    log "Skipping tauri-cli (--skip-tauri-cli)"
  fi
  verify
}

main
