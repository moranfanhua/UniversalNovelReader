#pragma once
#include <cstdint>
#include <string_view>
#include <vector>

namespace nib_pipeline {
// String.getBytes("UTF-8") semantics, including '?' for an unpaired surrogate.
// This is ordinary UTF-8, not JNI modified UTF-8; embedded NUL remains a byte.
std::vector<std::uint8_t> java_utf8(std::u16string_view input);
}
