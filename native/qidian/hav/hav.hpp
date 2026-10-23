#pragma once

#include <string>

namespace hav_restore {

// 对应当前 APK 的 nib_host_app_version()。
// 返回库内版本字符串，不查询运行此代码的应用包版本。
const char* host_app_version() noexcept;

// 对应 NativeWrapper.hav()；保留原 JNI 包装层的 null/空串回退。
std::string hav();

}  // namespace hav_restore
