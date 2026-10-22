#include "assembly.hpp"
#include "field_schema.hpp"
#include "hav.hpp"
#include "utf8.hpp"
#include "lk.hpp"
#include "string_armor.hpp"
#include <stdexcept>

namespace nib_pipeline {
namespace {
std::u16string ascii(const std::string& value) {
  std::u16string result;
  for(const unsigned char c:value){if(c>=128)throw std::invalid_argument("Non-ASCII profile constant");result.push_back(c);}
  return result;
}
std::string base64(const nib::Bytes& bytes) {
  constexpr char table[]="ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_";
  std::string result;result.reserve((bytes.size()+2)/3*4);
  for(std::size_t i=0;i<bytes.size();i+=3) {
    const auto a=bytes[i];
    const auto b=i+1<bytes.size()?bytes[i+1]:0;
    const auto c=i+2<bytes.size()?bytes[i+2]:0;
    result+=table[a>>2U];result+=table[((a&3U)<<4U)|(static_cast<unsigned>(b)>>4U)];
    result+=i+1<bytes.size()?table[((b&15U)<<2U)|(static_cast<unsigned>(c)>>6U)]:'=';
    result+=i+2<bytes.size()?table[c&63U]:'=';
  }
  return result;
}
}
Slots assemble(JsonAccess& json,std::int64_t timestamp) {
  Slots result{};
  const auto yes=string_armor::decode("LtXEm>VDw@O;uK;V9]V9g8:6;K*x0}=}UR6+RlTF");
  const auto no=string_armor::decode("l.,4{wrt[ie+R)Qh&I8.Iof_I/G72}rMMXWiB!HC");
  for(std::size_t i=0;i<kFields.size();++i) {
    const auto& field=kFields[i];
    switch(field.kind) {
      case Kind::version:result[i]=ascii(string_armor::decode("ew>K&:jM@rNXx{P[9XigRb7(>ZnXmn95a8r{gx9B"));break;
      case Kind::timestamp:result[i]=ascii(std::to_string(timestamp));break;
      case Kind::host:result[i]=ascii(hav_restore::hav());break;
      case Kind::boolean:result[i]=ascii(json.boolean_value(string_armor::decode(field.key))?yes:no);break;
      case Kind::string:result[i]=json.string_value(string_armor::decode(field.key),string_armor::decode(field.fallback));break;
    }
  }
  return result;
}
std::u16string join(const Slots& slots) {
  std::u16string result;
  for(std::size_t i=0;i<slots.size();++i){if(i)result+=u'|';result+=slots[i];}
  return result;
}
std::string encode(const std::u16string& input) {
  const auto plain=java_utf8(input);
  const auto transformed=nib::lk(plain);
  if(!transformed)return {};
  return base64(*transformed);
}
}
