#pragma once
#include <array>
#include <algorithm>
#include <cstdint>
#include <cstddef>
#include "../lk/md2_table.hpp"
namespace native_md2 {
using Byte=std::uint8_t;using Digest=std::array<Byte,16>;
inline Digest digest(const Byte* data, std::size_t size) {
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
        value = static_cast<Byte>(value ^ nib::parameters::kMd2Substitution[last]);
        last = value;
      }
      last = static_cast<Byte>(last + round);
    }
    if (update_checksum) {
      last = checksum.back();
      for (std::size_t index = 0; index < checksum.size(); ++index) {
        checksum[index] = static_cast<Byte>(
            checksum[index] ^ nib::parameters::kMd2Substitution[block[index] ^ last]);
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

}
