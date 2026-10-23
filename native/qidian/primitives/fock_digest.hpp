#pragma once
#include <array>
#include <cstdint>
#include <string>
#include <vector>

namespace qimei::http {
using Input=std::vector<std::uint8_t>;
using Digest=std::array<std::uint8_t,16>;
enum class DigestKind {md2,md4,md5};
// Legacy protocol compatibility only. These primitives do not read identity,
// implement App header canonicalization or override environment detectors.
Digest digest(DigestKind kind,const Input& input);
std::uint32_t crc32(const Input& input);
// Empty/leading-NUL input follows the selected JNI wrappers' empty result.
// Interior NUL bytes remain part of the length-delimited digest and CRC.
std::string sn(const Input& input);
std::string wnid(const Input& input);
}
