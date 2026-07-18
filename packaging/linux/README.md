# Linux packaging

## Build-server bootstrap

On a Debian/Ubuntu self-hosted runner (SSH):

```bash
bash packaging/linux/bootstrap-build-deps.sh
# optional: --skip-tauri-cli  --skip-cross
```

Installs apt packages (build tools, libusb, WebKitGTK/Tauri deps), aarch64
cross GCC, rustup + targets, and `tauri-cli`.

Shared CI path helpers (used by GitHub Actions bash steps on all OSes):
`packaging/ci/ci-env.sh`.

## Packaging

- **Portable zip:** app + `rkdeveloptool` + `loader_binaries/`
- **Installer:** `.deb` → `/opt/rockchip-universal-imager/` + `.desktop` entry

`linux-aarch64` GUI is not built on x86_64 hosts yet; companion tool still is.
