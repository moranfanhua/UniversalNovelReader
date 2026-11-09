#include "hav.hpp"

namespace hav_restore {
namespace {
// 当前核验 APK 的 native 数据常量。其他 APK 版本需要重新核对。
constexpr char kHostAppVersion[] = "7.9.480";
}

const char* host_app_version() noexcept {
  return kHostAppVersion;
}

std::string hav() {
  const char* value = host_app_version();
  return value != nullptr && value[0] != '\0' ? std::string(value) : std::string{};
}

}  // namespace hav_restore
