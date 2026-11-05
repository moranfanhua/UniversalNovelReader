#pragma once
#include <array>
#include <cstdint>
#include <string>

namespace nib_pipeline {
class JsonAccess {
 public:
  virtual ~JsonAccess()=default;
  virtual std::u16string string_value(const std::string& key,const std::string& fallback)=0;
  virtual bool boolean_value(const std::string& key)=0;
};
using Slots=std::array<std::u16string,64>;
Slots assemble(JsonAccess& json,std::int64_t timestamp);
std::u16string join(const Slots& slots);
std::string encode(const std::u16string& input);
}  // namespace nib_pipeline
