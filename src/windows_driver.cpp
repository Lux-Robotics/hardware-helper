#include "windows_driver.h"

#ifdef _WIN32

#include "logging.h"
#include "usb_driver_windows.h"

#include <shellapi.h>
#include <windows.h>

#include <string>
#include <vector>

namespace win_driver {
namespace {

std::vector<std::wstring> get_command_line_args() {
    int argc = 0;
    LPWSTR* argv = CommandLineToArgvW(GetCommandLineW(), &argc);
    std::vector<std::wstring> args;
    if (!argv) {
        return args;
    }
    args.reserve(static_cast<size_t>(argc));
    for (int i = 0; i < argc; ++i) {
        args.emplace_back(argv[i]);
    }
    LocalFree(argv);
    return args;
}

bool has_flag(const std::vector<std::wstring>& args, const std::wstring& flag) {
    for (const auto& arg : args) {
        if (arg == flag) {
            return true;
        }
    }
    return false;
}

std::wstring get_flag_value(const std::vector<std::wstring>& args, const std::wstring& flag) {
    const std::wstring prefix = flag + L"=";
    for (size_t i = 0; i < args.size(); ++i) {
        const auto& arg = args[i];
        if (arg == flag && i + 1 < args.size()) {
            return args[i + 1];
        }
        if (arg.rfind(prefix, 0) == 0) {
            return arg.substr(prefix.size());
        }
    }
    return L"";
}

std::string wide_to_utf8(const std::wstring& input) {
    if (input.empty()) {
        return std::string();
    }
    int size = WideCharToMultiByte(CP_UTF8, 0, input.c_str(), -1, nullptr, 0, nullptr, nullptr);
    if (size <= 0) {
        return std::string(input.begin(), input.end());
    }
    std::string out(static_cast<size_t>(size), '\0');
    WideCharToMultiByte(CP_UTF8, 0, input.c_str(), -1, out.data(), size, nullptr, nullptr);
    out.resize(static_cast<size_t>(size - 1));
    return out;
}

} // namespace

bool try_handle_driver_install_cli(int& exit_code) {
    const auto args = get_command_line_args();
    if (!has_flag(args, L"--install-driver")) {
        return false;
    }

    usb_driver::InstallOptions options;
    options.allow_elevation = false;
    const auto device_name = get_flag_value(args, L"--device-name");
    if (!device_name.empty()) {
        options.device_name = wide_to_utf8(device_name);
    }

    const auto result = usb_driver::install_libusb_win32(options);
    if (!result.success) {
        logging::write("driver", "Elevated driver install failed: " + result.error_message);
        exit_code = 1;
    } else {
        exit_code = 0;
    }
    return true;
}

} // namespace win_driver

#endif