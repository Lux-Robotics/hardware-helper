#pragma once

#include <string>

namespace usb_driver {

struct DriverInfo {
    bool device_found = false;
    bool is_libusb_win32 = false;
    std::string driver_name;
    std::string error_message;
};

struct InstallResult {
    bool success = false;
    std::string error_message;
};

DriverInfo query_driver();
InstallResult install_libusb_win32();

} // namespace usb_driver
