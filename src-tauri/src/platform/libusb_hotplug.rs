//! Rockchip USB presence via **libusb** (macOS and Linux).
//!
//! Windows intentionally does **not** use this path for detection: a Rockchip
//! device may not have a libusb-compatible driver until libwdi installs one.
//! Windows detection lives in `platform/windows/usb.rs` (native APIs).

use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::{Arc, Mutex};
use std::thread::{self, JoinHandle};

use rusb::{Context, Device, Hotplug, HotplugBuilder, Registration, UsbContext};

const ROCKCHIP_VID: u16 = 0x2207;

pub type UsbCallback = Arc<dyn Fn(bool, u16, u16) + Send + Sync + 'static>;

struct MonitorState {
    stop: AtomicBool,
    join: Mutex<Option<JoinHandle<()>>>,
}

static MONITOR: Mutex<Option<Arc<MonitorState>>> = Mutex::new(None);

pub fn start(on_change: UsbCallback) -> bool {
    stop();
    let state = Arc::new(MonitorState {
        stop: AtomicBool::new(false),
        join: Mutex::new(None),
    });

    let state_c = state.clone();
    let handle = thread::spawn(move || hotplug_loop(state_c, on_change));
    *state.join.lock().unwrap() = Some(handle);
    *MONITOR.lock().unwrap() = Some(state);
    log_info("libusb hotplug monitoring started");
    true
}

pub fn stop() {
    let prev = MONITOR.lock().unwrap().take();
    if let Some(state) = prev {
        state.stop.store(true, Ordering::SeqCst);
        if let Some(j) = state.join.lock().unwrap().take() {
            let _ = j.join();
        }
    }
}

fn log_info(msg: &str) {
    crate::logging::write_line(&format!("[app] {msg}"));
}

fn hotplug_loop(state: Arc<MonitorState>, on_change: UsbCallback) {
    struct Handler {
        cb: UsbCallback,
    }

    impl<T: UsbContext> Hotplug<T> for Handler {
        fn device_arrived(&mut self, device: Device<T>) {
            if let Ok(desc) = device.device_descriptor() {
                if desc.vendor_id() == ROCKCHIP_VID {
                    (self.cb)(true, desc.vendor_id(), desc.product_id());
                }
            }
        }
        fn device_left(&mut self, device: Device<T>) {
            if let Ok(desc) = device.device_descriptor() {
                if desc.vendor_id() == ROCKCHIP_VID {
                    (self.cb)(false, desc.vendor_id(), desc.product_id());
                }
            }
        }
    }

    let Ok(ctx) = Context::new() else {
        log_info("libusb init failed; hotplug unavailable");
        return;
    };

    if !rusb::has_hotplug() {
        log_info("libusb hotplug not supported; falling back to poll");
        poll_loop(state, on_change, ctx);
        return;
    }

    let handler = Handler {
        cb: on_change.clone(),
    };
    let reg: Registration<Context> = match HotplugBuilder::new()
        .enumerate(true)
        .vendor_id(ROCKCHIP_VID)
        .register(&ctx, Box::new(handler))
    {
        Ok(r) => r,
        Err(_) => {
            log_info("hotplug register failed; falling back to poll");
            poll_loop(state, on_change, ctx);
            return;
        }
    };

    while !state.stop.load(Ordering::SeqCst) {
        let _ = ctx.handle_events(Some(std::time::Duration::from_millis(500)));
    }
    drop(reg);
}

fn poll_loop(state: Arc<MonitorState>, on_change: UsbCallback, ctx: Context) {
    let mut last: Option<(u16, u16)> = None;
    while !state.stop.load(Ordering::SeqCst) {
        let mut found = None;
        if let Ok(list) = ctx.devices() {
            for dev in list.iter() {
                if let Ok(desc) = dev.device_descriptor() {
                    if desc.vendor_id() == ROCKCHIP_VID {
                        found = Some((desc.vendor_id(), desc.product_id()));
                        break;
                    }
                }
            }
        }
        if found != last {
            match (last, found) {
                (Some((v, p)), None) => (on_change)(false, v, p),
                (_, Some((v, p))) => (on_change)(true, v, p),
                _ => {}
            }
            last = found;
        }
        thread::sleep(std::time::Duration::from_millis(1000));
    }
}
