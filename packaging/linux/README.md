# Linux installer wrappers (future)

CI ships a flat install-layout zip:

```
rockchip-universal-imager-linux-x86_64/
  rockchip-universal-imager
  rkdeveloptool
  loader_binaries/
  README.txt
```

Optional later: `.deb` / AppImage / `.desktop` that installs that folder under
`/opt/rockchip-universal-imager/` and ships `99-rk-rockusb.rules` from the
rkdeveloptool submodule.
