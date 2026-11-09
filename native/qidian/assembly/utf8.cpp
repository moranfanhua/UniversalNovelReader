#include "utf8.hpp"

namespace nib_pipeline {
std::vector<std::uint8_t> java_utf8(std::u16string_view input) {
  std::vector<std::uint8_t> output;
  output.reserve(input.size());
  for (std::size_t i = 0; i < input.size(); ++i) {
    std::uint32_t point = input[i];
    if (point >= 0xd800 && point <= 0xdbff) {
      if (i + 1 < input.size() && input[i + 1] >= 0xdc00 &&
          input[i + 1] <= 0xdfff) {
        point = 0x10000 + ((point - 0xd800) << 10) + (input[++i] - 0xdc00);
      } else {
        output.push_back('?');
        continue;
      }
    } else if (point >= 0xdc00 && point <= 0xdfff) {
      output.push_back('?');
      continue;
    }
    if (point < 0x80) {
      output.push_back(static_cast<std::uint8_t>(point));
    } else if (point < 0x800) {
      output.push_back(static_cast<std::uint8_t>(0xc0 | (point >> 6)));
      output.push_back(static_cast<std::uint8_t>(0x80 | (point & 0x3f)));
    } else if (point < 0x10000) {
      output.push_back(static_cast<std::uint8_t>(0xe0 | (point >> 12)));
      output.push_back(static_cast<std::uint8_t>(0x80 | ((point >> 6) & 0x3f)));
      output.push_back(static_cast<std::uint8_t>(0x80 | (point & 0x3f)));
    } else {
      output.push_back(static_cast<std::uint8_t>(0xf0 | (point >> 18)));
      output.push_back(static_cast<std::uint8_t>(0x80 | ((point >> 12) & 0x3f)));
      output.push_back(static_cast<std::uint8_t>(0x80 | ((point >> 6) & 0x3f)));
      output.push_back(static_cast<std::uint8_t>(0x80 | (point & 0x3f)));
    }
  }
  return output;
}
}
