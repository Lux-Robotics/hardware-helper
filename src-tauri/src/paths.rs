//! Resolve app / companion / resource directories (portable-first layout).

use std::path::{Path, PathBuf};

pub fn platform_name() -> &'static str {
    if cfg!(target_os = "windows") {
        "windows"
    } else if cfg!(target_os = "macos") {
        "macos"
    } else {
        "linux"
    }
}

pub fn executable_dir() -> PathBuf {
    std::env::current_exe()
        .ok()
        .and_then(|p| p.parent().map(|d| d.to_path_buf()))
        .unwrap_or_else(|| PathBuf::from("."))
}

/// Directory for companions (rkdeveloptool, portable marker, optional libusb).
pub fn companion_dir() -> PathBuf {
    let exe_dir = executable_dir();
    if cfg!(target_os = "macos") {
        if let (Some(contents), Some(macos)) = (
            exe_dir.parent(),
            exe_dir.file_name().and_then(|s| s.to_str()),
        ) {
            if macos == "MacOS" && contents.file_name().and_then(|s| s.to_str()) == Some("Contents")
            {
                if let Some(bundle) = contents.parent() {
                    if bundle.extension().and_then(|s| s.to_str()) == Some("app") {
                        if let Some(parent) = bundle.parent() {
                            return parent.to_path_buf();
                        }
                    }
                }
            }
        }
    }
    exe_dir
}

pub fn is_portable_build() -> bool {
    companion_dir().join("portable").is_file()
}

pub fn rkdeveloptool_name() -> &'static str {
    if cfg!(target_os = "windows") {
        "rkdeveloptool.exe"
    } else {
        "rkdeveloptool"
    }
}

pub fn rkdeveloptool_path() -> Result<PathBuf, String> {
    let name = rkdeveloptool_name();
    let candidates = [companion_dir().join(name), executable_dir().join(name)];
    for path in candidates {
        if path.is_file() {
            return Ok(path);
        }
    }
    // Dev convenience: repo-adjacent build (optional)
    let dev = PathBuf::from(env!("CARGO_MANIFEST_DIR"))
        .join("../target")
        .join(name);
    if dev.is_file() {
        return Ok(dev);
    }
    Err(format!(
        "rkdeveloptool is missing - place {} next to the app (portable layout).",
        name
    ))
}

pub fn resource_dir() -> PathBuf {
    if cfg!(target_os = "macos") {
        if let Some(resources) = executable_dir().parent().map(|p| p.join("Resources")) {
            if resources.is_dir() {
                return resources;
            }
        }
    }
    executable_dir()
}

/// loader_binaries next to app, in resources, or from repo during dev.
pub fn loader_binaries_dir() -> PathBuf {
    let candidates = [
        companion_dir().join("loader_binaries"),
        resource_dir().join("loader_binaries"),
        executable_dir().join("loader_binaries"),
        PathBuf::from(env!("CARGO_MANIFEST_DIR")).join("../loader_binaries"),
    ];
    for c in candidates {
        if c.is_dir() {
            return c;
        }
    }
    companion_dir().join("loader_binaries")
}

pub fn loader_path(filename: &str) -> Option<PathBuf> {
    let p = loader_binaries_dir().join(filename);
    if p.is_file() {
        Some(p)
    } else {
        None
    }
}

#[allow(dead_code)]
pub fn exists_beside(name: impl AsRef<Path>) -> bool {
    companion_dir().join(name).is_file()
}
