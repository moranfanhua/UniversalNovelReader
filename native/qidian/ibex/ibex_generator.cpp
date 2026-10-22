#include "ibex_generator.hpp"
#include <utility>

namespace ibex {
namespace {
std::u16string ascii(const std::string& text) {
  return std::u16string(text.begin(), text.end());
}
}
void Report::set(const std::string& key, Value value) {
  values_.insert_or_assign(key, std::move(value));
}
void Report::set_text(const std::string& key, std::u16string value) {
  set(key, std::move(value));
}
void Report::set_boolean(const std::string& key, bool value) { set(key, value); }
void Report::set_integer(const std::string& key, std::int64_t value) { set(key, value); }
void Report::set_null(const std::string& key) { set(key, nullptr); }
void Report::erase(const std::string& key) { values_.erase(key); }
std::u16string Report::string_value(const std::string& key,
                                   const std::string& fallback) {
  const auto found = values_.find(key);
  if (found == values_.end()) return ascii(fallback);
  const auto& value = found->second;
  if (const auto* text = std::get_if<std::u16string>(&value)) return *text;
  if (const auto* flag = std::get_if<bool>(&value)) return *flag ? u"true" : u"false";
  if (const auto* number = std::get_if<std::int64_t>(&value)) {
    return ascii(std::to_string(*number));
  }
  // JSONObject.NULL is present and stringifies to "null"; absence uses fallback.
  return u"null";
}
bool Report::boolean_value(const std::string& key) {
  const auto found = values_.find(key);
  if (found == values_.end()) return false;
  const auto& value = found->second;
  if (const auto* flag = std::get_if<bool>(&value)) return *flag;
  const auto* text = std::get_if<std::u16string>(&value);
  if (!text || text->size() != 4) return false;
  const char16_t expected[] = u"true";
  for (std::size_t i = 0; i < 4; ++i) {
    auto letter = (*text)[i];
    if (letter >= u'A' && letter <= u'Z') letter += u'a' - u'A';
    if (letter != expected[i]) return false;
  }
  return true;
}
std::string generate(nib_pipeline::JsonAccess& report, std::int64_t timestamp_ms) {
  return nib_pipeline::encode(nib_pipeline::join(
      nib_pipeline::assemble(report, timestamp_ms)));
}
}
