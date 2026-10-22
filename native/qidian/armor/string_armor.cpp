#include "string_armor.hpp"

#include "apk_parameters.hpp"

#include <algorithm>
#include <array>
#include <cstddef>

namespace string_armor {
namespace {

using Byte = std::uint8_t;
using Block = std::array<Byte, 16>;
using RoundKeys = std::array<Block, 11>;

Byte multiply(Byte left, Byte right) {
  Byte result = 0;
  while (right != 0) {
    if ((right & 1U) != 0) {
      result = static_cast<Byte>(result ^ left);
    }
    const bool carry = (left & 0x80U) != 0;
    left = static_cast<Byte>((static_cast<unsigned>(left) << 1U) ^
                             (carry ? 0x1BU : 0U));
    right = static_cast<Byte>(right >> 1U);
  }
  return result;
}

Byte inverse(Byte value) {
  if (value == 0) {
    return 0;
  }
  Byte result = 1;
  unsigned exponent = 254;
  while (exponent != 0) {
    if ((exponent & 1U) != 0) {
      result = multiply(result, value);
    }
    value = multiply(value, value);
    exponent >>= 1U;
  }
  return result;
}

Byte rotate_left(Byte value, unsigned count) {
  return static_cast<Byte>((static_cast<unsigned>(value) << count) |
                           (static_cast<unsigned>(value) >> (8U - count)));
}

struct SubstitutionTables {
  std::array<Byte, 256> forward{};
  std::array<Byte, 256> reverse{};

  SubstitutionTables() {
    for (unsigned index = 0; index < forward.size(); ++index) {
      const Byte value = inverse(static_cast<Byte>(index));
      forward[index] = static_cast<Byte>(
          value ^ rotate_left(value, 1) ^ rotate_left(value, 2) ^
          rotate_left(value, 3) ^ rotate_left(value, 4) ^ 0x63U);
      reverse[forward[index]] = static_cast<Byte>(index);
    }
  }
};

const SubstitutionTables& substitutions() {
  static const SubstitutionTables tables;
  return tables;
}

Bytes decode_base91(std::string_view input) {
  Bytes decoded;
  decoded.reserve(input.size());
  std::uint32_t accumulator = 0;
  unsigned bit_count = 0;
  int pending = -1;
  for (const char character : input) {
    const auto value = parameters::kDecodeTable[static_cast<unsigned char>(character)];
    if (value == 91) {
      continue;
    }
    if (pending < 0) {
      pending = value;
      continue;
    }
    const auto pair = static_cast<std::uint32_t>(pending) +
                      static_cast<std::uint32_t>(value) * 91U;
    accumulator |= pair << bit_count;
    bit_count += (pair & 8191U) > 88U ? 13U : 14U;
    while (bit_count >= 8) {
      decoded.push_back(static_cast<Byte>(accumulator & 255U));
      accumulator >>= 8U;
      bit_count -= 8;
    }
    pending = -1;
  }
  if (pending >= 0) {
    decoded.push_back(static_cast<Byte>(
        accumulator | (static_cast<std::uint32_t>(pending) << bit_count)));
  }
  return decoded;
}

RoundKeys expand_key(const Block& key) {
  std::array<std::uint32_t, 44> words{};
  for (std::size_t index = 0; index < 4; ++index) {
    for (unsigned byte = 0; byte < 4; ++byte) {
      words[index] |= static_cast<std::uint32_t>(key[index * 4 + byte]) << (byte * 8U);
    }
  }
  const auto& sbox = substitutions().forward;
  for (std::size_t index = 4; index < words.size(); ++index) {
    std::uint32_t word = words[index - 1];
    if (index % 4 == 0) {
      word = static_cast<std::uint32_t>(sbox[(word >> 8U) & 255U]) |
             (static_cast<std::uint32_t>(sbox[(word >> 16U) & 255U]) << 8U) |
             (static_cast<std::uint32_t>(sbox[word >> 24U]) << 16U) |
             (static_cast<std::uint32_t>(sbox[word & 255U]) << 24U);
      word ^= parameters::kRoundConstants[index / 4 - 1];
    }
    words[index] = words[index - 4] ^ word;
  }
  RoundKeys rounds{};
  for (std::size_t round = 0; round < rounds.size(); ++round) {
    for (std::size_t word = 0; word < 4; ++word) {
      for (unsigned byte = 0; byte < 4; ++byte) {
        rounds[round][word * 4 + byte] =
            static_cast<Byte>(words[round * 4 + word] >> (byte * 8U));
      }
    }
  }
  return rounds;
}

void add_round_key(Block& state, const Block& key) {
  for (std::size_t index = 0; index < state.size(); ++index) {
    state[index] = static_cast<Byte>(state[index] ^ key[index]);
  }
}

void inverse_rows_and_substitution(Block& state) {
  const Block previous = state;
  const auto& sbox = substitutions().reverse;
  for (std::size_t column = 0; column < 4; ++column) {
    for (std::size_t row = 0; row < 4; ++row) {
      state[column * 4 + row] = sbox[previous[((column + 4 - row) % 4) * 4 + row]];
    }
  }
}

void inverse_columns(Block& state) {
  constexpr std::array<Byte, 4> coefficients{14, 11, 13, 9};
  const Block previous = state;
  for (std::size_t column = 0; column < 4; ++column) {
    for (std::size_t row = 0; row < 4; ++row) {
      Byte value = 0;
      for (std::size_t offset = 0; offset < 4; ++offset) {
        value = static_cast<Byte>(value ^ multiply(
            previous[column * 4 + offset], coefficients[(offset + 4 - row) % 4]));
      }
      state[column * 4 + row] = value;
    }
  }
}

Block decrypt_block(Block block, const RoundKeys& rounds) {
  add_round_key(block, rounds[10]);
  for (std::size_t round = 9; round > 0; --round) {
    inverse_rows_and_substitution(block);
    add_round_key(block, rounds[round]);
    inverse_columns(block);
  }
  inverse_rows_and_substitution(block);
  add_round_key(block, rounds[0]);
  return block;
}

}  // namespace

std::optional<Bytes> decode_bytes(std::string_view encoded) {
  const Bytes packed = decode_base91(encoded);
  if (packed.size() < 32 || packed.size() % 16 != 0) {
    return std::nullopt;
  }
  Block prefix{};
  std::copy_n(packed.begin(), prefix.size(), prefix.begin());
  const RoundKeys rounds = expand_key(prefix);
  Block previous = prefix;
  Bytes plain;
  plain.reserve(packed.size() - prefix.size());
  for (std::size_t offset = prefix.size(); offset < packed.size(); offset += 16) {
    Block cipher{};
    std::copy_n(packed.begin() + static_cast<Bytes::difference_type>(offset), cipher.size(), cipher.begin());
    const Block block = decrypt_block(cipher, rounds);
    for (std::size_t index = 0; index < block.size(); ++index) {
      plain.push_back(static_cast<Byte>(block[index] ^ previous[index]));
    }
    previous = cipher;
  }
  const std::size_t padding = plain.back();
  // 原库仅在尾字节为 1..16 时检查填充；其他值保留原字节。
  if (padding >= 1 && padding <= 16) {
    if (plain.size() <= padding) {
      return std::nullopt;
    }
    const auto padding_start = plain.end() - static_cast<Bytes::difference_type>(padding);
    if (!std::all_of(padding_start, plain.end(), [padding](Byte value) {
          return value == padding;
        })) {
      return std::nullopt;
    }
    plain.resize(plain.size() - padding);
  }
  return plain;
}

std::string decode(std::string_view encoded) {
  if (encoded.empty()) {
    return {};
  }
  const auto result = decode_bytes(encoded);
  if (!result) {
    return {};
  }
  return std::string(result->begin(), result->end());
}

std::string decode(const char* encoded) {
  return encoded == nullptr ? std::string{} : decode(std::string_view(encoded));
}

}  // namespace string_armor
