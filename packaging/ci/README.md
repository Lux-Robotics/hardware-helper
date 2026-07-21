# CI helpers

| File | Role |
|------|------|
| `ci-env.sh` | PATH / workspace helpers for self-hosted bash steps |
| `package-cell.sh` | One OS/arch: portable zip + real installer (NSIS / DMG / deb) |

## Workflows

```
package.yaml
  ├─ build-rkdeveloptool.yaml  → rkdeveloptool-<os>-<arch>
  ├─ build-app.yaml            → app-<os>-<arch>  (.app on macOS)
  └─ package matrix (6 cells)  → portable-* + installer-* artifacts
```

### Portable zip contents

- **macOS:** `Rockchip Universal Imager.app` + `rkdeveloptool` + `loader_binaries/`
- **Windows/Linux:** app binary + `rkdeveloptool` + `loader_binaries/`

No `portable` marker.

### Installers

| OS | Tool | Output |
|----|------|--------|
| Windows | NSIS (`makensis`) | `*-setup.exe` |
| macOS | `hdiutil` | `*.dmg` (`.app` + companions + Applications symlink) |
| Linux | `dpkg-deb` | `*.deb` → `/opt/rockchip-universal-imager` |

### Linux runners

| Product | Runner labels |
|---------|----------------|
| `linux-x86_64` | `[self-hosted, Linux, X64]` |
| `linux-aarch64` | `[self-hosted, Linux, ARM64]` (native app + companion) |

Bootstrap both with `packaging/linux/bootstrap-build-deps.sh`.