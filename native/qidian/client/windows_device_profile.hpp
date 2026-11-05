#pragma once
#include <cstdint>

namespace qimei::client::windows_device_profile {
// Explicit Windows compatibility declarations, using the product's marketing
// name. This does not claim a captured Xiaomi Build.MODEL or build fingerprint.
// Product: https://www.mi.com/prod/xiaomi-17-pro-max
// Android 16 launch profile (API 36), rather than an auto-changing OTA version.
inline constexpr char brand[] = "Xiaomi";
inline constexpr char model[] = "Xiaomi 17 Pro Max";
inline constexpr char android_release[] = "16";
inline constexpr char android_api_level[] = "36";
inline constexpr char os_version[] = "Android 16,level 36";
// Snapdragon 8 Elite Gen 5: 64-bit Arm Android ABI. The secondary ABI is
// unspecified; no 32-bit runtime support is inferred from the CPU alone.
inline constexpr char cpu_abi[] = "arm64-v8a";
inline constexpr char cpu_abi2[] = "";
// Main display, native portrait pixels (not Windows desktop pixels).
// https://www.dxomark.com/cn/smartphones/Xiaomi/17-Pro-Max
inline constexpr std::uint32_t screen_width = 1200;
inline constexpr std::uint32_t screen_height = 2608;
inline constexpr double screen_diagonal_inches = 6.9;
inline constexpr char device_type[] = "Phone";
// A Wi-Fi connection state, rather than a radio capability of the handset.
inline constexpr char network[] = "wifi";
inline constexpr std::uint32_t network_type = 1;
// Requires a device-captured Linux uname value. A MIUI/HyperOS label is not
// a kernel string; keep it empty until a verified sample is provided.
inline constexpr char kernel[] = "";
// Explicit compatibility declarations, independent of host process settings.
inline constexpr bool debug = false;
inline constexpr bool root = false;
inline constexpr bool accessibility = false;
inline constexpr bool x86 = false;
inline constexpr char suspicious_modules[] = "";
// Package name belongs to the selected official Qidian APK, not the handset.
inline constexpr char package_name[] = "com.qidian.QDReader";
}
