#pragma once
#include <array>
#include <cstddef>
#include <cstdint>
namespace portable_md4 {
std::array<std::uint8_t,16> digest(const std::uint8_t* data,std::size_t size);
}
