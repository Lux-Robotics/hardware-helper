#!/usr/bin/env bash
# Thin wrapper: run the PowerShell Windows bootstrap from Git Bash / MSYS2.
#
# Prefer elevated PowerShell for a full install:
#   powershell -ExecutionPolicy Bypass -File packaging/windows/bootstrap-build-deps.ps1
#
# This script just re-invokes that .ps1 with the same flags.
#
set -euo pipefail

ROOT="$(cd "$(dirname "$0")" && pwd)"
PS1="$ROOT/bootstrap-build-deps.ps1"

if [[ ! -f "$PS1" ]]; then
  echo "Missing $PS1" >&2
  exit 1
fi

# Map bash-style flags to PowerShell switches
PS_ARGS=()
for arg in "$@"; do
  case "$arg" in
    --skip-tauri-cli)   PS_ARGS+=(-SkipTauriCli) ;;
    --skip-llvm-mingw)  PS_ARGS+=(-SkipLlvmMingw) ;;
    --skip-vs)          PS_ARGS+=(-SkipVsBuildTools) ;;
    --skip-winget)      PS_ARGS+=(-SkipWingetTools) ;;
    -h|--help)
      sed -n '2,12p' "$0"
      echo ""
      echo "PowerShell help: see comments at top of bootstrap-build-deps.ps1"
      exit 0
      ;;
    *)
      echo "Unknown option: $arg" >&2
      exit 2
      ;;
  esac
done

if command -v powershell.exe >/dev/null 2>&1; then
  exec powershell.exe -NoProfile -ExecutionPolicy Bypass -File "$PS1" "${PS_ARGS[@]+"${PS_ARGS[@]}"}"
elif command -v pwsh.exe >/dev/null 2>&1; then
  exec pwsh.exe -NoProfile -ExecutionPolicy Bypass -File "$PS1" "${PS_ARGS[@]+"${PS_ARGS[@]}"}"
else
  echo "powershell.exe not found. Open an elevated PowerShell and run:" >&2
  echo "  $PS1" >&2
  exit 1
fi
