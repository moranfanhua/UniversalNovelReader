#pragma once
#include <cstdint>
#include <map>
#include <string>
#include <vector>

namespace qimei {
// Small JSON boundary for the App/SDK envelopes; values are never included in errors.
struct Json {
  enum class Kind { null_value,boolean,number,string,array,object };
  Kind kind=Kind::null_value;
  bool boolean=false;
  std::string text;
  std::vector<Json> items;
  std::map<std::string,Json> members;
  static Json parse(const std::string& text);
  static Json string(std::string text);
  static Json number(std::int64_t number);
  static Json object(std::map<std::string,Json> members);
  const Json* find(const std::string& name)const;
  std::int64_t integer(std::int64_t fallback=0)const;
  std::string string_or_empty()const;
  std::string encode()const;
};
}
