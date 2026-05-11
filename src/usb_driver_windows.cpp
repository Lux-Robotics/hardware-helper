#include "usb_driver_windows.h"

#include <filesystem>
#include <string>

#if defined(_WIN32) && defined(HAVE_LIBWDI)
#include <algorithm>
#include <cctype>
#include <libwdi.h>

namespace usb_driver {
namespace {

constexpr unsigned short kVid = 0x2207;
constexpr unsigned short kPid = 0x350b;

bool is_libusb_win32_driver(const char* driver) {
    if (!driver) {
        return false;
    }
    std::string name(driver);
    std::transform(name.begin(), name.end(), name.begin(), [](unsigned char c) {
        return static_cast<char>(std::tolower(c));
    });
    return name.find("libusb-win32") != std::string::npos || name.find("libusb0") != std::string::npos;
}

wdi_device_info* find_device(wdi_device_info* list) {
    for (auto* device = list; device != nullptr; device = device->next) {
        if (device->vid == kVid && device->pid == kPid) {
            return device;
        }
    }
    return nullptr;
}

DriverInfo build_info(wdi_device_info* device) {
    DriverInfo info;
    info.device_found = device != nullptr;
    if (!device) {
        info.error_message = "device not found";
        return info;
    }

    if (device->driver) {
        info.driver_name = device->driver;
    } else {
        info.driver_name = "(none)";
    }

    info.is_libusb_win32 = is_libusb_win32_driver(device->driver);
    if (!info.is_libusb_win32) {
        info.error_message = "driver is " + info.driver_name + " (expected libusb-win32)";
    }

    return info;
}

} // namespace

DriverInfo query_driver() {
    wdi_device_info* list = nullptr;
    wdi_options_create_list options{};
    options.list_all = TRUE;

    const int err = wdi_create_list(&list, &options);
    if (err != WDI_SUCCESS) {
        DriverInfo info;
        info.error_message = wdi_strerror(err);
        return info;
    }

    wdi_device_info* device = find_device(list);
    DriverInfo info = build_info(device);
    wdi_destroy_list(list);
    return info;
}

InstallResult install_libusb_win32() {
    InstallResult result;

    wdi_device_info* list = nullptr;
    wdi_options_create_list options{};
    options.list_all = TRUE;

    int err = wdi_create_list(&list, &options);
    if (err != WDI_SUCCESS) {
        result.error_message = wdi_strerror(err);
        return result;
    }

    wdi_device_info* device = find_device(list);
    if (!device) {
        wdi_destroy_list(list);
        result.error_message = "device not found";
        return result;
    }

    const auto driver_dir = std::filesystem::current_path() / "driver";
    std::filesystem::create_directories(driver_dir);
    const std::string driver_path = driver_dir.string();
    const std::string inf_name = "libusb-win32.inf";

    wdi_options_prepare_driver prepare{};
    prepare.driver_type = WDI_LIBUSB0;
    prepare.vendor_name = const_cast<char*>("hardware-helper");

    err = wdi_prepare_driver(device, driver_path.c_str(), inf_name.c_str(), &prepare);
    if (err != WDI_SUCCESS) {
        wdi_destroy_list(list);
        result.error_message = wdi_strerror(err);
        return result;
    }

    wdi_options_install_driver install{};
    err = wdi_install_driver(device, driver_path.c_str(), inf_name.c_str(), &install);
    if (err != WDI_SUCCESS) {
        wdi_destroy_list(list);
        result.error_message = wdi_strerror(err);
        return result;
    }

    wdi_destroy_list(list);
    result.success = true;
    return result;
}

} // namespace usb_driver

#else

namespace usb_driver {

DriverInfo query_driver() {
    DriverInfo info;
    info.error_message = "libwdi not available on this platform";
    return info;
}

InstallResult install_libusb_win32() {
    InstallResult result;
    result.error_message = "libwdi not available on this platform";
    return result;
}

} // namespace usb_driver

#endif
