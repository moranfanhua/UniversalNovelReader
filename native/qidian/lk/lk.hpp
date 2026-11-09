#pragma once

#include <cstdint>
#include <optional>
#include <string_view>
#include <vector>

namespace nib {

using Bytes = std::vector<std::uint8_t>;

// 还原 lk 的原始字节变换，不包含 Java 包装层的 Base64 编码。
// 原 JNI 对空输入、首字节为 NUL 的输入没有可靠的输出长度；这里安全拒绝。
std::optional<Bytes> lk(std::string_view input);
std::optional<Bytes> lk(const Bytes& input);
std::optional<Bytes> lk(const char* input);

}  // namespace nib
