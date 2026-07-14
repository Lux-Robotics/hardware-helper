# Windows installer wrappers (future)

CI currently ships an **install-layout zip** built by `package-installer.sh`:

```
rockchip-universal-imager-windows-x86_64/
  rockchip-universal-imager.exe
  rkdeveloptool.exe
  libusb-1.0.dll          # when built with MinGW
  loader_binaries/
  README.txt
```

A real installer (NSIS or WiX MSI) should extract that folder under
`%LocalAppData%\Programs\Rockchip Universal Imager\` (or similar) and
create a Start Menu shortcut to `rockchip-universal-imager.exe`.

Tauri’s built-in bundler (`nsis` / `msi`) can replace this once
`externalBin` + `resources` are wired for `rkdeveloptool` and loaders.
