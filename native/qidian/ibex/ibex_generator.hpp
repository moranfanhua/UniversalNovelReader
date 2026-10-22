#pragma once
#include "assembly.hpp"
#include <map>
#include <string>
#include <variant>

namespace ibex {
// Typed values returned by a caller's authorized device/account providers.
// No device identities or supposedly clean detector results are synthesized.
class Report final : public nib_pipeline::JsonAccess {
 public:
  using Value = std::variant<std::nullptr_t, bool, std::int64_t, std::u16string>;
  void set(const std::string& key, Value value);
  void set_text(const std::string& key, std::u16string value);
  void set_boolean(const std::string& key, bool value);
  void set_integer(const std::string& key, std::int64_t value);
  void set_null(const std::string& key);
  void erase(const std::string& key);
  std::u16string string_value(const std::string& key,
                            const std::string& fallback) override;
  bool boolean_value(const std::string& key) override;
 private:
  std::map<std::string, Value> values_;
};

// Selected protocol: QDReader Android 7.9.480. Timestamp is Unix milliseconds.
// A custom JsonAccess can preserve additional JSONObject coercions if needed.
std::string generate(nib_pipeline::JsonAccess& report, std::int64_t timestamp_ms);
}
