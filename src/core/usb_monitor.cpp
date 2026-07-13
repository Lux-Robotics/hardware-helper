#include "core/usb_monitor.h"

#include "core/logging.h"

#ifndef _WIN32

#include <atomic>
#include <thread>

#include <libusb.h>

namespace rui {
namespace {

// All Rockchip parts enumerate under this vendor ID in Maskrom and loader
// (rockusb) modes; the PID identifies the SoC (see loader_map.h).
constexpr unsigned short kRockchipVid = 0x2207;

libusb_context* g_ctx = nullptr;
libusb_hotplug_callback_handle g_cb_handle = 0;
std::thread g_event_thread;
std::atomic<bool> g_stop{false};
UsbChangeCallback g_on_change;

int LIBUSB_CALL hotplug_cb(libusb_context* /*ctx*/, libusb_device* dev,
                           libusb_hotplug_event event, void* /*user_data*/) {
    // Reads from the cached descriptor - no device open, no interface claim,
    // so this never contends with rkdeveloptool's exclusive claim.
    libusb_device_descriptor desc{};
    if (libusb_get_device_descriptor(dev, &desc) != LIBUSB_SUCCESS) {
        return 0; // stay registered
    }
    const bool present = (event == LIBUSB_HOTPLUG_EVENT_DEVICE_ARRIVED);
    if (g_on_change) {
        g_on_change(present, desc.idVendor, desc.idProduct);
    }
    return 0; // returning non-zero would deregister the callback
}

} // namespace

bool start_usb_monitor(UsbChangeCallback on_change) {
    if (g_ctx != nullptr) {
        return true; // already running
    }

    if (libusb_init(&g_ctx) != LIBUSB_SUCCESS) {
        logging::write("app", "libusb init failed; hotplug detection unavailable");
        g_ctx = nullptr;
        return false;
    }

    if (libusb_has_capability(LIBUSB_CAP_HAS_HOTPLUG) == 0) {
        logging::write("app", "libusb hotplug not supported on this platform");
        libusb_exit(g_ctx);
        g_ctx = nullptr;
        return false;
    }

    g_on_change = std::move(on_change);
    g_stop.store(false);

    const int rc = libusb_hotplug_register_callback(
        g_ctx,
        static_cast<libusb_hotplug_event>(LIBUSB_HOTPLUG_EVENT_DEVICE_ARRIVED |
                                          LIBUSB_HOTPLUG_EVENT_DEVICE_LEFT),
        LIBUSB_HOTPLUG_ENUMERATE, // also fire for devices already connected at startup
        kRockchipVid,
        LIBUSB_HOTPLUG_MATCH_ANY, // any product ID (any SoC)
        LIBUSB_HOTPLUG_MATCH_ANY, // any device class
        hotplug_cb, nullptr, &g_cb_handle);

    if (rc != LIBUSB_SUCCESS) {
        logging::write("app", "libusb hotplug registration failed");
        libusb_exit(g_ctx);
        g_ctx = nullptr;
        g_on_change = nullptr;
        return false;
    }

    g_event_thread = std::thread([]() {
        // Servicing events is not device I/O - it just dispatches arrival/
        // departure notifications; the 1s timeout only bounds how quickly the
        // loop notices the stop flag. No rkdeveloptool/USB transfer happens
        // here.
        while (!g_stop.load()) {
            timeval tv{};
            tv.tv_sec = 1;
            libusb_handle_events_timeout_completed(g_ctx, &tv, nullptr);
        }
    });

    logging::write("app", "libusb hotplug monitoring started");
    return true;
}

void stop_usb_monitor() {
    if (g_ctx == nullptr) {
        return;
    }

    g_stop.store(true);
#if defined(LIBUSB_API_VERSION) && (LIBUSB_API_VERSION >= 0x01000105)
    // Wake the event thread immediately instead of waiting out its timeout.
    libusb_interrupt_event_handler(g_ctx);
#endif
    if (g_event_thread.joinable()) {
        g_event_thread.join();
    }

    libusb_hotplug_deregister_callback(g_ctx, g_cb_handle);
    libusb_exit(g_ctx);
    g_ctx = nullptr;
    g_on_change = nullptr;
}

} // namespace rui

#else // _WIN32

// Native Windows detection. libusb has no hotplug here, so instead of libusb
// this uses the Win32 device-notification API: a message-only window receives
// WM_DEVICECHANGE for USB interface arrivals/removals, and a SetupAPI
// enumeration at startup covers devices already plugged in (the equivalent of
// libusb's HOTPLUG_ENUMERATE). Both paths feed the same UsbChangeCallback the
// libusb backend does, so the rest of the app is identical across platforms.

#ifndef WIN32_LEAN_AND_MEAN
#define WIN32_LEAN_AND_MEAN
#endif
#ifndef NOMINMAX
#define NOMINMAX
#endif
#include <windows.h>

#include <dbt.h>
#include <setupapi.h>

#include <atomic>
#include <cstddef>
#include <cwctype>
#include <future>
#include <string>
#include <thread>
#include <vector>

namespace rui {
namespace {

constexpr unsigned short kRockchipVid = 0x2207;

// A message we post to the monitor window to make its message loop exit.
constexpr UINT kStopMessage = WM_APP + 1;

// GUID_DEVINTERFACE_USB_DEVICE {A5DCBF10-6530-11D2-901F-00C04FB951ED}.
// Declared inline to avoid pulling in usbiodef.h.
constexpr GUID kUsbDeviceInterfaceGuid = {
    0xA5DCBF10, 0x6530, 0x11D2, {0x90, 0x1F, 0x00, 0xC0, 0x4F, 0xB9, 0x51, 0xED}};

UsbChangeCallback g_on_change;
std::thread g_thread;
std::atomic<HWND> g_hwnd{nullptr};
HDEVNOTIFY g_dev_notify = nullptr;

// Pull "VID_xxxx" and "PID_xxxx" (hex) out of a USB device interface path like
// \\?\USB#VID_2207&PID_350B#... . Case-insensitive; false if either is absent.
bool parse_vid_pid(const std::wstring& path, unsigned short& vid, unsigned short& pid) {
    std::wstring upper;
    upper.reserve(path.size());
    for (wchar_t c : path) {
        upper.push_back(static_cast<wchar_t>(std::towupper(c)));
    }
    const auto read_hex4 = [&](const std::wstring& key, unsigned short& out) -> bool {
        const auto pos = upper.find(key);
        if (pos == std::wstring::npos || pos + key.size() + 4 > upper.size()) {
            return false;
        }
        unsigned int value = 0;
        for (int i = 0; i < 4; ++i) {
            const wchar_t c = upper[pos + key.size() + i];
            int digit;
            if (c >= L'0' && c <= L'9') {
                digit = c - L'0';
            } else if (c >= L'A' && c <= L'F') {
                digit = 10 + (c - L'A');
            } else {
                return false;
            }
            value = (value << 4) | static_cast<unsigned int>(digit);
        }
        out = static_cast<unsigned short>(value);
        return true;
    };
    return read_hex4(L"VID_", vid) && read_hex4(L"PID_", pid);
}

void notify(bool present, const std::wstring& device_path) {
    unsigned short vid = 0;
    unsigned short pid = 0;
    if (!parse_vid_pid(device_path, vid, pid) || vid != kRockchipVid) {
        return;
    }
    if (g_on_change) {
        g_on_change(present, vid, pid);
    }
}

// Fire present=true for every Rockchip device already connected. WM_DEVICECHANGE
// only reports future changes, so this covers the "plugged in before launch"
// case, mirroring libusb's HOTPLUG_ENUMERATE.
void enumerate_existing() {
    HDEVINFO info = SetupDiGetClassDevsW(&kUsbDeviceInterfaceGuid, nullptr, nullptr,
                                         DIGCF_PRESENT | DIGCF_DEVICEINTERFACE);
    if (info == INVALID_HANDLE_VALUE) {
        return;
    }

    SP_DEVICE_INTERFACE_DATA iface{};
    iface.cbSize = sizeof(iface);
    for (DWORD idx = 0;
         SetupDiEnumDeviceInterfaces(info, nullptr, &kUsbDeviceInterfaceGuid, idx, &iface);
         ++idx) {
        DWORD needed = 0;
        SetupDiGetDeviceInterfaceDetailW(info, &iface, nullptr, 0, &needed, nullptr);
        if (needed == 0) {
            continue;
        }
        std::vector<std::byte> buffer(needed);
        auto* detail = reinterpret_cast<SP_DEVICE_INTERFACE_DETAIL_DATA_W*>(buffer.data());
        detail->cbSize = sizeof(SP_DEVICE_INTERFACE_DETAIL_DATA_W);
        if (SetupDiGetDeviceInterfaceDetailW(info, &iface, detail, needed, nullptr, nullptr)) {
            notify(true, detail->DevicePath);
        }
    }

    SetupDiDestroyDeviceInfoList(info);
}

LRESULT CALLBACK wnd_proc(HWND hwnd, UINT msg, WPARAM wparam, LPARAM lparam) {
    if (msg == kStopMessage) {
        PostQuitMessage(0);
        return 0;
    }
    if (msg == WM_DEVICECHANGE &&
        (wparam == DBT_DEVICEARRIVAL || wparam == DBT_DEVICEREMOVECOMPLETE)) {
        auto* header = reinterpret_cast<DEV_BROADCAST_HDR*>(lparam);
        if (header != nullptr && header->dbch_devicetype == DBT_DEVTYP_DEVICEINTERFACE) {
            auto* iface = reinterpret_cast<DEV_BROADCAST_DEVICEINTERFACE_W*>(header);
            notify(wparam == DBT_DEVICEARRIVAL, iface->dbcc_name);
        }
        return TRUE;
    }
    return DefWindowProcW(hwnd, msg, wparam, lparam);
}

constexpr wchar_t kWindowClass[] = L"RuiUsbMonitorWindow";

} // namespace

bool start_usb_monitor(UsbChangeCallback on_change) {
    if (g_hwnd.load() != nullptr) {
        return true; // already running
    }
    g_on_change = std::move(on_change);

    // A message-only window's messages are delivered on its creating thread, so
    // create it, register for notifications, and run the loop all on the worker
    // thread. Hand success/failure back through a promise so this function can
    // report it synchronously, just like the libusb path.
    std::promise<bool> ready;
    std::future<bool> ready_future = ready.get_future();

    g_thread = std::thread([promise = std::move(ready)]() mutable {
        WNDCLASSEXW wc{};
        wc.cbSize = sizeof(wc);
        wc.lpfnWndProc = wnd_proc;
        wc.hInstance = GetModuleHandleW(nullptr);
        wc.lpszClassName = kWindowClass;
        RegisterClassExW(&wc); // harmless if the class already exists

        HWND hwnd = CreateWindowExW(0, kWindowClass, L"", 0, 0, 0, 0, 0,
                                    HWND_MESSAGE, nullptr, wc.hInstance, nullptr);
        if (hwnd == nullptr) {
            promise.set_value(false);
            return;
        }

        DEV_BROADCAST_DEVICEINTERFACE_W filter{};
        filter.dbcc_size = sizeof(filter);
        filter.dbcc_devicetype = DBT_DEVTYP_DEVICEINTERFACE;
        filter.dbcc_classguid = kUsbDeviceInterfaceGuid;
        g_dev_notify = RegisterDeviceNotificationW(hwnd, &filter, DEVICE_NOTIFY_WINDOW_HANDLE);
        if (g_dev_notify == nullptr) {
            DestroyWindow(hwnd);
            promise.set_value(false);
            return;
        }

        g_hwnd.store(hwnd);
        enumerate_existing();     // report devices already connected
        promise.set_value(true);

        MSG message;
        while (GetMessageW(&message, nullptr, 0, 0) > 0) {
            TranslateMessage(&message);
            DispatchMessageW(&message);
        }

        UnregisterDeviceNotification(g_dev_notify);
        g_dev_notify = nullptr;
        DestroyWindow(hwnd);
        UnregisterClassW(kWindowClass, wc.hInstance);
        g_hwnd.store(nullptr);
    });

    if (!ready_future.get()) {
        if (g_thread.joinable()) {
            g_thread.join();
        }
        g_on_change = nullptr;
        logging::write("app", "Windows USB device monitoring failed to start");
        return false;
    }

    logging::write("app", "Windows USB device monitoring started");
    return true;
}

void stop_usb_monitor() {
    HWND hwnd = g_hwnd.load();
    if (hwnd == nullptr) {
        return;
    }
    // Wake the loop so GetMessage returns 0 and the thread tears everything down.
    PostMessageW(hwnd, kStopMessage, 0, 0);
    if (g_thread.joinable()) {
        g_thread.join();
    }
    g_on_change = nullptr;
}

} // namespace rui

#endif // _WIN32
