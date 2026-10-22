#pragma once

#include <cstdint>
#include <optional>
#include <string>
#include <string_view>
#include <vector>

namespace string_armor {

using Bytes = std::vector<std::uint8_t>;

// 解码当前 APK 的 ASCII 混淆常量；失败时返回 nullopt。
// 返回原始字节，保留 native 对尾部填充的处理规则。
std::optional<Bytes> decode_bytes(std::string_view encoded);

// 面向有效 UTF-8 常量的便捷接口。空输入、null 或解码失败返回空串。
// std::string 保留 UTF-8 字节，不模拟 Java 对非法 UTF-8 的替换行为。
std::string decode(std::string_view encoded);
std::string decode(const char* encoded);

}  // namespace string_armor
