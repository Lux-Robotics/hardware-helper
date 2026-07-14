//! OS backends for Rockchip USB **detection** and **flash access**.
//!
//! | OS | Detect | Flash access |
//! |----|--------|----------------|
//! | macOS | libusb | none |
//! | Linux | libusb | udev |
//! | Windows | native Win32 | libwdi → libusb-win32 |
//!
//! Per OS, both concerns live in `platform/{os}/usb.rs`.

pub mod flashing;

#[cfg(unix)]
pub(crate) mod libusb_hotplug;

#[cfg(target_os = "linux")]
pub mod linux;

#[cfg(target_os = "macos")]
pub mod macos;

#[cfg(windows)]
pub mod windows;
