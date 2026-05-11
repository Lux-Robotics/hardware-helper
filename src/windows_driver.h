#pragma once

#ifdef _WIN32
namespace win_driver {

bool try_handle_driver_install_cli(int& exit_code);

} // namespace win_driver
#endif