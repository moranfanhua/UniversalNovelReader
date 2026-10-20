// Protocol port from ch6vip/fqapp (GPL-3.0), credited in README.md.
// Fixed-width implementation of the existing App signature profile. MD5,
// SM3 and AES below are private to that profile, not general crypto APIs.
#include "fanqie_signature.h"

#include <algorithm>
#include <array>
#include <cstdlib>
#include <cstring>
#include <iterator>
#include <string>
#include <utility>
#include <vector>

namespace {
using Bytes = std::vector<uint8_t>;

uint32_t rol32(uint32_t value, unsigned count) {
  count &= 31;
  return count == 0 ? value : (value << count) | (value >> (32 - count));
}

uint64_t rol64(uint64_t value, unsigned count) {
  return (value << count) | (value >> (64 - count));
}

uint64_t ror64(uint64_t value, unsigned count) {
  return (value >> count) | (value << (64 - count));
}

uint32_t read32(const uint8_t* bytes, bool big = false) {
  uint32_t value = 0;
  for (unsigned i = 0; i < 4; ++i) {
    value |= uint32_t(bytes[i]) << (8 * (big ? 3 - i : i));
  }
  return value;
}

uint64_t read64(const uint8_t* bytes) {
  uint64_t value = 0;
  for (unsigned i = 0; i < 8; ++i) value |= uint64_t(bytes[i]) << (8 * i);
  return value;
}

void write32(uint8_t* bytes, uint32_t value, bool big = false) {
  for (unsigned i = 0; i < 4; ++i) {
    bytes[i] = uint8_t(value >> (8 * (big ? 3 - i : i)));
  }
}

void write64(uint8_t* bytes, uint64_t value) {
  for (unsigned i = 0; i < 8; ++i) bytes[i] = uint8_t(value >> (8 * i));
}

Bytes paddedHashInput(const Bytes& data, bool big) {
  Bytes out(data);
  out.push_back(0x80);
  while (out.size() % 64 != 56) out.push_back(0);
  const uint64_t bits = uint64_t(data.size()) * 8;
  for (unsigned i = 0; i < 8; ++i) {
    out.push_back(uint8_t(bits >> (8 * (big ? 7 - i : i))));
  }
  return out;
}

Bytes md5(const Bytes& data) {
  static constexpr uint32_t constants[64] = {
      0xd76aa478, 0xe8c7b756, 0x242070db, 0xc1bdceee, 0xf57c0faf, 0x4787c62a,
      0xa8304613, 0xfd469501, 0x698098d8, 0x8b44f7af, 0xffff5bb1, 0x895cd7be,
      0x6b901122, 0xfd987193, 0xa679438e, 0x49b40821, 0xf61e2562, 0xc040b340,
      0x265e5a51, 0xe9b6c7aa, 0xd62f105d, 0x02441453, 0xd8a1e681, 0xe7d3fbc8,
      0x21e1cde6, 0xc33707d6, 0xf4d50d87, 0x455a14ed, 0xa9e3e905, 0xfcefa3f8,
      0x676f02d9, 0x8d2a4c8a, 0xfffa3942, 0x8771f681, 0x6d9d6122, 0xfde5380c,
      0xa4beea44, 0x4bdecfa9, 0xf6bb4b60, 0xbebfbc70, 0x289b7ec6, 0xeaa127fa,
      0xd4ef3085, 0x04881d05, 0xd9d4d039, 0xe6db99e5, 0x1fa27cf8, 0xc4ac5665,
      0xf4292244, 0x432aff97, 0xab9423a7, 0xfc93a039, 0x655b59c3, 0x8f0ccc92,
      0xffeff47d, 0x85845dd1, 0x6fa87e4f, 0xfe2ce6e0, 0xa3014314, 0x4e0811a1,
      0xf7537e82, 0xbd3af235, 0x2ad7d2bb, 0xeb86d391};
  static constexpr unsigned shifts[16] = {7, 12, 17, 22, 5, 9,  14, 20,
                                          4, 11, 16, 23, 6, 10, 15, 21};
  std::array<uint32_t, 4> state = {0x67452301, 0xefcdab89, 0x98badcfe,
                                   0x10325476};
  const auto input = paddedHashInput(data, false);
  for (size_t offset = 0; offset < input.size(); offset += 64) {
    uint32_t words[16];
    for (unsigned i = 0; i < 16; ++i)
      words[i] = read32(input.data() + offset + 4 * i);
    auto a = state[0], b = state[1], c = state[2], d = state[3];
    for (unsigned i = 0; i < 64; ++i) {
      uint32_t f;
      unsigned index;
      if (i < 16) {
        f = (b & c) | (~b & d);
        index = i;
      } else if (i < 32) {
        f = (d & b) | (~d & c);
        index = (5 * i + 1) % 16;
      } else if (i < 48) {
        f = b ^ c ^ d;
        index = (3 * i + 5) % 16;
      } else {
        f = c ^ (b | ~d);
        index = (7 * i) % 16;
      }
      const auto next = b + rol32(a + f + constants[i] + words[index],
                                  shifts[(i / 16) * 4 + i % 4]);
      a = d;
      d = c;
      c = b;
      b = next;
    }
    state[0] += a;
    state[1] += b;
    state[2] += c;
    state[3] += d;
  }
  Bytes out(16);
  for (unsigned i = 0; i < 4; ++i) write32(out.data() + 4 * i, state[i]);
  return out;
}

Bytes sm3Prefix(const Bytes& data) {
  std::array<uint32_t, 8> state = {0x7380166f, 0x4914b2b9, 0x172442d7,
                                   0xda8a0600, 0xa96f30bc, 0x163138aa,
                                   0xe38dee4d, 0xb0fb0e4e};
  const auto input = paddedHashInput(data, true);
  for (size_t offset = 0; offset < input.size(); offset += 64) {
    uint32_t words[68];
    for (unsigned i = 0; i < 16; ++i)
      words[i] = read32(input.data() + offset + 4 * i, true);
    for (unsigned i = 16; i < 68; ++i) {
      const auto x = words[i - 16] ^ words[i - 9] ^ rol32(words[i - 3], 15);
      words[i] = x ^ rol32(x, 15) ^ rol32(x, 23) ^ rol32(words[i - 13], 7) ^
                 words[i - 6];
    }
    auto a = state[0], b = state[1], c = state[2], d = state[3];
    auto e = state[4], f = state[5], g = state[6], h = state[7];
    for (unsigned i = 0; i < 64; ++i) {
      const auto a12 = rol32(a, 12);
      const auto ss1 =
          rol32(a12 + e + rol32(i < 16 ? 0x79cc4519 : 0x7a879d8a, i), 7);
      const auto ff = i < 16 ? a ^ b ^ c : (a & b) | (a & c) | (b & c);
      const auto gg = i < 16 ? e ^ f ^ g : (e & f) | (~e & g);
      const auto tt1 = ff + d + (ss1 ^ a12) + (words[i] ^ words[i + 4]);
      const auto tt2 = gg + h + ss1 + words[i];
      d = c;
      c = rol32(b, 9);
      b = a;
      a = tt1;
      h = g;
      g = rol32(f, 19);
      f = e;
      e = tt2 ^ rol32(tt2, 9) ^ rol32(tt2, 17);
    }
    const uint32_t next[8] = {a, b, c, d, e, f, g, h};
    for (unsigned i = 0; i < 8; ++i) state[i] ^= next[i];
  }
  Bytes out(8);
  write32(out.data(), state[0], true);
  write32(out.data() + 4, state[1], true);
  out.resize(6);
  return out;
}

std::string hex(const Bytes& bytes) {
  static constexpr char digits[] = "0123456789abcdef";
  std::string out;
  out.reserve(bytes.size() * 2);
  for (auto byte : bytes) {
    out.push_back(digits[byte >> 4]);
    out.push_back(digits[byte & 15]);
  }
  return out;
}

std::string base64(const Bytes& bytes) {
  static constexpr char digits[] =
      "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/";
  std::string out;
  out.reserve((bytes.size() + 2) / 3 * 4);
  for (size_t i = 0; i < bytes.size(); i += 3) {
    const uint32_t value =
        (uint32_t(bytes[i]) << 16) |
        (i + 1 < bytes.size() ? uint32_t(bytes[i + 1]) << 8 : 0) |
        (i + 2 < bytes.size() ? uint32_t(bytes[i + 2]) : 0);
    out.push_back(digits[value >> 18]);
    out.push_back(digits[(value >> 12) & 63]);
    out.push_back(i + 1 < bytes.size() ? digits[(value >> 6) & 63] : '=');
    out.push_back(i + 2 < bytes.size() ? digits[value & 63] : '=');
  }
  return out;
}

void pad(Bytes& bytes) {
  const auto count = uint8_t(16 - bytes.size() % 16);
  bytes.insert(bytes.end(), count, count);
}

// AES-128 CBC, encryption only, with PKCS#7 padding.
Bytes aes(Bytes input) {
  static constexpr uint8_t sbox[256] = {
      0x63, 0x7c, 0x77, 0x7b, 0xf2, 0x6b, 0x6f, 0xc5, 0x30, 0x01, 0x67, 0x2b,
      0xfe, 0xd7, 0xab, 0x76, 0xca, 0x82, 0xc9, 0x7d, 0xfa, 0x59, 0x47, 0xf0,
      0xad, 0xd4, 0xa2, 0xaf, 0x9c, 0xa4, 0x72, 0xc0, 0xb7, 0xfd, 0x93, 0x26,
      0x36, 0x3f, 0xf7, 0xcc, 0x34, 0xa5, 0xe5, 0xf1, 0x71, 0xd8, 0x31, 0x15,
      0x04, 0xc7, 0x23, 0xc3, 0x18, 0x96, 0x05, 0x9a, 0x07, 0x12, 0x80, 0xe2,
      0xeb, 0x27, 0xb2, 0x75, 0x09, 0x83, 0x2c, 0x1a, 0x1b, 0x6e, 0x5a, 0xa0,
      0x52, 0x3b, 0xd6, 0xb3, 0x29, 0xe3, 0x2f, 0x84, 0x53, 0xd1, 0x00, 0xed,
      0x20, 0xfc, 0xb1, 0x5b, 0x6a, 0xcb, 0xbe, 0x39, 0x4a, 0x4c, 0x58, 0xcf,
      0xd0, 0xef, 0xaa, 0xfb, 0x43, 0x4d, 0x33, 0x85, 0x45, 0xf9, 0x02, 0x7f,
      0x50, 0x3c, 0x9f, 0xa8, 0x51, 0xa3, 0x40, 0x8f, 0x92, 0x9d, 0x38, 0xf5,
      0xbc, 0xb6, 0xda, 0x21, 0x10, 0xff, 0xf3, 0xd2, 0xcd, 0x0c, 0x13, 0xec,
      0x5f, 0x97, 0x44, 0x17, 0xc4, 0xa7, 0x7e, 0x3d, 0x64, 0x5d, 0x19, 0x73,
      0x60, 0x81, 0x4f, 0xdc, 0x22, 0x2a, 0x90, 0x88, 0x46, 0xee, 0xb8, 0x14,
      0xde, 0x5e, 0x0b, 0xdb, 0xe0, 0x32, 0x3a, 0x0a, 0x49, 0x06, 0x24, 0x5c,
      0xc2, 0xd3, 0xac, 0x62, 0x91, 0x95, 0xe4, 0x79, 0xe7, 0xc8, 0x37, 0x6d,
      0x8d, 0xd5, 0x4e, 0xa9, 0x6c, 0x56, 0xf4, 0xea, 0x65, 0x7a, 0xae, 0x08,
      0xba, 0x78, 0x25, 0x2e, 0x1c, 0xa6, 0xb4, 0xc6, 0xe8, 0xdd, 0x74, 0x1f,
      0x4b, 0xbd, 0x8b, 0x8a, 0x70, 0x3e, 0xb5, 0x66, 0x48, 0x03, 0xf6, 0x0e,
      0x61, 0x35, 0x57, 0xb9, 0x86, 0xc1, 0x1d, 0x9e, 0xe1, 0xf8, 0x98, 0x11,
      0x69, 0xd9, 0x8e, 0x94, 0x9b, 0x1e, 0x87, 0xe9, 0xce, 0x55, 0x28, 0xdf,
      0x8c, 0xa1, 0x89, 0x0d, 0xbf, 0xe6, 0x42, 0x68, 0x41, 0x99, 0x2d, 0x0f,
      0xb0, 0x54, 0xbb, 0x16};
  static constexpr uint8_t key[16] = {0xd3, 0x1e, 0x37, 0x18, 0x28, 0x8a,
                                      0x10, 0x27, 0xba, 0xab, 0x59, 0xf1,
                                      0x46, 0xa0, 0x9a, 0x9c};
  uint8_t previous[16] = {0xea, 0x18, 0x0a, 0x03, 0x36, 0xed, 0x35, 0x2f,
                          0xcd, 0x24, 0xe4, 0xd5, 0x00, 0x18, 0xae, 0x54};
  uint8_t expanded[176];
  std::memcpy(expanded, key, 16);
  uint8_t rcon = 1;
  auto xtime = [](uint8_t value) {
    return uint8_t((uint32_t(value) << 1) ^ ((value & 0x80) ? 0x1b : 0));
  };
  for (unsigned i = 16; i < 176; i += 4) {
    uint8_t t[4];
    std::memcpy(t, expanded + i - 4, 4);
    if (i % 16 == 0) {
      const auto first = t[0];
      t[0] = sbox[t[1]] ^ rcon;
      t[1] = sbox[t[2]];
      t[2] = sbox[t[3]];
      t[3] = sbox[first];
      rcon = xtime(rcon);
    }
    for (unsigned j = 0; j < 4; ++j)
      expanded[i + j] = expanded[i - 16 + j] ^ t[j];
  }
  pad(input);
  for (size_t offset = 0; offset < input.size(); offset += 16) {
    auto* state = input.data() + offset;
    for (unsigned i = 0; i < 16; ++i) state[i] ^= previous[i] ^ expanded[i];
    for (unsigned round = 1; round <= 10; ++round) {
      uint8_t shifted[16];
      for (unsigned column = 0; column < 4; ++column) {
        for (unsigned row = 0; row < 4; ++row) {
          shifted[column * 4 + row] =
              sbox[state[((column + row) % 4) * 4 + row]];
        }
      }
      std::memcpy(state, shifted, 16);
      if (round != 10) {
        for (unsigned column = 0; column < 4; ++column) {
          auto* p = state + column * 4;
          const uint8_t sum = p[0] ^ p[1] ^ p[2] ^ p[3];
          const auto first = p[0];
          p[0] ^= sum ^ xtime(p[0] ^ p[1]);
          p[1] ^= sum ^ xtime(p[1] ^ p[2]);
          p[2] ^= sum ^ xtime(p[2] ^ p[3]);
          p[3] ^= sum ^ xtime(p[3] ^ first);
        }
      }
      for (unsigned i = 0; i < 16; ++i) state[i] ^= expanded[round * 16 + i];
    }
    std::memcpy(previous, state, 16);
  }
  return input;
}

using SimonKeys = std::array<uint64_t, 72>;
SimonKeys simonKeys(const uint8_t* key) {
  SimonKeys keys;
  for (unsigned i = 0; i < 4; ++i) keys[i] = read64(key + 8 * i);
  constexpr uint64_t z = 0x3dc94c3a046d678b;
  for (unsigned i = 4; i < 72; ++i) {
    auto t = ror64(keys[i - 1], 3) ^ keys[i - 3];
    t ^= ror64(t, 1);
    keys[i] = ~keys[i - 4] ^ t ^ ((z >> ((i - 4) % 62)) & 1) ^ 3;
  }
  return keys;
}

void simon(const uint8_t* block, const SimonKeys& keys, bool decrypt,
           uint8_t* out) {
  auto a = read64(block), b = read64(block + 8);
  for (unsigned i = 0; i < 72; ++i) {
    if (decrypt) {
      const auto previous = a;
      a = b ^ (rol64(a, 1) & rol64(a, 8)) ^ rol64(a, 2) ^ keys[71 - i];
      b = previous;
    } else {
      const auto previous = b;
      b = a ^ (rol64(b, 1) & rol64(b, 8)) ^ rol64(b, 2) ^ keys[i];
      a = previous;
    }
  }
  write64(out, a);
  write64(out + 8, b);
}

Bytes bytes(const std::string& text) { return Bytes(text.begin(), text.end()); }

Bytes bytes(UnrFanqieBytes input) {
  if (input.length == 0) return {};
  return Bytes(input.data, input.data + input.length);
}

class Proto {
 public:
  Bytes data;
  void varint(uint32_t value) {
    while (value >= 128) {
      data.push_back(uint8_t(value & 127) | 128);
      value >>= 7;
    }
    data.push_back(uint8_t(value));
  }
  void number(unsigned field, uint32_t value) {
    varint(field << 3);
    varint(value);
  }
  void blob(unsigned field, const Bytes& value) {
    varint((field << 3) | 2);
    varint(static_cast<uint32_t>(value.size()));
    data.insert(data.end(), value.begin(), value.end());
  }
  void text(unsigned field, const std::string& value) {
    blob(field, bytes(value));
  }
};

std::string argus(const UnrFanqieArgusInput& input) {
  Proto bean;
  bean.number(1, 1077940818);
  bean.number(2, 2);
  bean.number(3, input.nonce);
  bean.blob(4, bytes(input.aid));
  bean.blob(5, bytes(input.device));
  bean.text(6, "1611921764");
  bean.blob(7, bytes(input.version));
  bean.text(8, "v04.04.05-ov-android");
  bean.number(9, 134744640);
  bean.blob(10, Bytes(8, 0));
  bean.number(11, 0);
  bean.number(12, static_cast<uint32_t>(input.timestamp) << 1);
  bean.blob(13, sm3Prefix(input.body.length == 0 ? Bytes(16, 0)
                                                 : md5(bytes(input.body))));
  bean.blob(14, sm3Prefix(input.query.length == 0 ? Bytes(16, 0)
                                                  : bytes(input.query)));
  Proto nested;
  nested.number(1, 1);
  nested.number(2, 1);
  nested.number(3, 1);
  nested.number(7, 0xc792eccc);
  bean.blob(15, nested.data);
  bean.text(16, "");
  bean.text(20, "none");
  bean.number(21, 738);
  Proto device;
  device.text(1, "NX551J");
  device.number(2, 8196);
  device.number(4, 0x80e0d800);
  bean.blob(23, device.data);
  bean.number(25, 2);
  pad(bean.data);
  // Expand the fixed Argus key once, rather than once per encrypted block.
  static const auto keys = [] {
    constexpr uint8_t key[32] = {
        0xfc, 0x78, 0xe0, 0xa9, 0x65, 0x7a, 0x0c, 0x74, 0x8c, 0xe5, 0x15,
        0x59, 0x90, 0x3c, 0xcf, 0x03, 0x51, 0x0e, 0x51, 0xd3, 0xcf, 0xf2,
        0x32, 0xd7, 0x13, 0x43, 0xe8, 0x8a, 0x32, 0x1c, 0x53, 0x04};
    return simonKeys(key);
  }();
  constexpr uint8_t magic[8] = {0xf2, 0xf7, 0xfc, 0xff, 0xf2, 0xf7, 0xfc, 0xff};
  Bytes frame(std::begin(magic), std::end(magic));
  for (size_t offset = 0; offset < bean.data.size(); offset += 16) {
    uint8_t out[16];
    simon(bean.data.data() + offset, keys, false, out);
    frame.insert(frame.end(), std::begin(out), std::end(out));
  }
  constexpr uint8_t tail[] = {0xea, 0xfb, 0x2c, 0xfe, 0x85,
                              0x68, 0x51, 0x91, 0x54};
  frame.insert(frame.end(), std::begin(tail), std::end(tail));
  for (size_t i = 8; i < frame.size(); ++i) frame[i] ^= magic[i % 8];
  std::reverse(frame.begin(), frame.end());
  frame.push_back(97);
  frame.push_back(111);
  const auto encrypted = aes(std::move(frame));
  Bytes out = {0xf2, 0x81};
  out.insert(out.end(), encrypted.begin(), encrypted.end());
  return base64(out);
}

std::string ladon(int64_t timestamp, int64_t aid, const uint8_t* random) {
  Bytes seed(random, random + 4);
  const auto aidBytes = bytes(std::to_string(aid));
  seed.insert(seed.end(), aidBytes.begin(), aidBytes.end());
  const auto digest = bytes(hex(md5(seed)));
  std::array<uint64_t, 35> rounds;
  auto a = read64(digest.data()), b = read64(digest.data() + 8);
  std::array<uint64_t, 36> queue;
  queue[0] = read64(digest.data() + 16);
  queue[1] = read64(digest.data() + 24);
  rounds[0] = a;
  for (unsigned i = 0; i < 34; ++i) {
    const auto next = (ror64(b, 8) + a) ^ i;
    queue[i + 2] = next;
    a = next ^ rol64(a, 3);
    rounds[i + 1] = a;
    b = queue[i];
  }
  auto input =
      bytes(std::to_string(timestamp) + "-1611921764-" + std::to_string(aid));
  pad(input);
  Bytes out(random, random + 4);
  for (size_t offset = 0; offset < input.size(); offset += 16) {
    auto x = read64(input.data() + offset),
         y = read64(input.data() + offset + 8);
    for (unsigned i = 0; i < 34; ++i) {
      y = rounds[i] ^ (x + ror64(y, 8));
      x = y ^ rol64(x, 3);
    }
    uint8_t encrypted[16];
    write64(encrypted, x);
    write64(encrypted + 8, y);
    out.insert(out.end(), std::begin(encrypted), std::end(encrypted));
  }
  return base64(out);
}

char* copyResult(const std::string& value) {
  auto* result = static_cast<char*>(std::malloc(value.size() + 1));
  if (result != nullptr) std::memcpy(result, value.c_str(), value.size() + 1);
  return result;
}

bool valid(UnrFanqieBytes input) {
  return (input.length == 0 || input.data != nullptr) &&
         input.length <= UINT32_MAX;
}
}  // namespace

extern "C" {
char* unr_fanqie_ladon(int64_t timestamp, int64_t aid, const uint8_t* random) {
  if (random == nullptr) return nullptr;
  try {
    return copyResult(ladon(timestamp, aid, random));
  } catch (...) {
    return nullptr;
  }
}

char* unr_fanqie_argus(const UnrFanqieArgusInput* input) {
  if (input == nullptr || !valid(input->query) || !valid(input->body) ||
      !valid(input->aid) || !valid(input->device) || !valid(input->version)) {
    return nullptr;
  }
  try {
    return copyResult(argus(*input));
  } catch (...) {
    return nullptr;
  }
}

void unr_fanqie_signature_free(void* result) { std::free(result); }

int32_t unr_fanqie_simon(const uint8_t* block, const uint8_t* key,
                         int32_t decrypt, uint8_t* output) {
  if (block == nullptr || key == nullptr || output == nullptr) return -1;
  simon(block, simonKeys(key), decrypt != 0, output);
  return 0;
}
}
