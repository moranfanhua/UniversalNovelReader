// Derived from the archived lk core; only primitive backend replaced.
#include "lk.hpp"
#include "jvm_crypto.hpp"
#include "md4.hpp"

#include "../lk/md2_table.hpp"


#include <algorithm>
#include <array>
#include <cstddef>
#include <cstring>
#include <limits>
#include <stdexcept>

namespace nib {
namespace {

using Byte = std::uint8_t;
using Digest = std::array<Byte, 16>;
using Material = std::array<Byte, 32>;

std::uint32_t crc32(const Byte* data, std::size_t size) {
  std::uint32_t checksum = 0xffffffffU;
  for (std::size_t index = 0; index < size; ++index) {
    checksum ^= data[index];
    for (unsigned bit = 0; bit < 8; ++bit) {
      const std::uint32_t mask = 0U - (checksum & 1U);
      checksum = (checksum >> 1U) ^ (mask & 0xedb88320U);
    }
  }
  return ~checksum;
}

Digest md2(const Byte* data, std::size_t size) {
  std::array<Byte, 48> state{};
  Digest checksum{};
  const auto process = [&](const Digest& block, bool update_checksum) {
    for (std::size_t index = 0; index < block.size(); ++index) {
      state[16 + index] = block[index];
      state[32 + index] = static_cast<Byte>(block[index] ^ state[index]);
    }
    Byte last = 0;
    for (unsigned round = 0; round < 18; ++round) {
      for (auto& value : state) {
        value = static_cast<Byte>(value ^ parameters::kMd2Substitution[last]);
        last = value;
      }
      last = static_cast<Byte>(last + round);
    }
    if (update_checksum) {
      last = checksum.back();
      for (std::size_t index = 0; index < checksum.size(); ++index) {
        checksum[index] = static_cast<Byte>(
            checksum[index] ^ parameters::kMd2Substitution[block[index] ^ last]);
        last = checksum[index];
      }
    }
  };

  const std::size_t complete = size / 16;
  for (std::size_t block_index = 0; block_index < complete; ++block_index) {
    Digest block{};
    std::copy_n(data + block_index * 16, block.size(), block.begin());
    process(block, true);
  }
  Digest final_block{};
  const std::size_t remainder = size % 16;
  std::copy_n(data + complete * 16, remainder, final_block.begin());
  std::fill(final_block.begin() + static_cast<Digest::difference_type>(remainder),
            final_block.end(), static_cast<Byte>(16 - remainder));
  process(final_block, true);
  const Digest final_checksum = checksum;
  process(final_checksum, false);
  Digest result{};
  std::copy_n(state.begin(), result.size(), result.begin());
  return result;
}

Digest digest(unsigned choice, const Byte* data, std::size_t size) {
  if (choice == 0) {
    return md2(data, size);
  }
  if (choice == 1) return portable_md4::digest(data, size);
  return jvm_crypto::md5(data, size);
}

Material derive_material(const Byte* data, std::size_t size) {
  const std::uint32_t checksum = crc32(data, size);
  const unsigned first_choice = checksum % 3U;
  const unsigned repeated_choice = (checksum >> 8U) % 3U;
  const Digest first = digest(first_choice, data, size);
  const Digest second = digest(repeated_choice, first.data(), first.size());
  const Digest third = digest(repeated_choice, second.data(), second.size());
  constexpr char hex[] = "0123456789abcdef";
  Material material{};
  for (std::size_t index = 0; index < third.size(); ++index) {
    material[index * 2] = static_cast<Byte>(hex[third[index] >> 4U]);
    material[index * 2 + 1] = static_cast<Byte>(hex[third[index] & 15U]);
  }
  return material;
}

Bytes encrypt_layer(const Bytes& plain, const Material& material, unsigned choice) {
  const std::size_t block_size = choice == 0 ? 16 : 8;
  const std::size_t padding = block_size - plain.size() % block_size;
  Bytes padded = plain;
  padded.insert(padded.end(), padding, static_cast<Byte>(padding));
  return jvm_crypto::cbc(padded, material, choice == 0);
}

}  // namespace

std::optional<Bytes> lk(std::string_view input) {
  if (input.empty() || input.front() == '\0' ||
      input.size() > static_cast<std::size_t>(std::numeric_limits<int>::max())) {
    return std::nullopt;
  }
  const auto* data = reinterpret_cast<const Byte*>(input.data());
  const Material material = derive_material(data, input.size());
  const std::uint32_t selection = crc32(material.data(), material.size());
  const Bytes plain(data, data + input.size());
  const Bytes first = encrypt_layer(plain, material, selection & 1U);
  Bytes output = encrypt_layer(first, material, (selection >> 4U) & 1U);
  output.insert(output.end(), material.begin(), material.end());
  return output;
}

std::optional<Bytes> lk(const Bytes& input) {
  if (input.empty()) {
    return std::nullopt;
  }
  return lk(std::string_view(reinterpret_cast<const char*>(input.data()), input.size()));
}

std::optional<Bytes> lk(const char* input) {
  return input == nullptr ? std::nullopt : lk(std::string_view(input));
}

}  // namespace nib
