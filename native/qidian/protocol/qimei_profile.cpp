#include "qimei_profile.hpp"
#include "qimei_json.hpp"
#include <algorithm>
#include <stdexcept>
namespace qimei {
std::string encode_profile(const Profile& profile){
  const auto block=[](const Block& value){return Json::string(base64(Bytes(value.begin(),value.end())));};
  return Json::object({{"version",Json::number(2)},{"defaultKey",block(profile.default_key)},{"defaultIv",block(profile.default_iv)},{"payloadKey",block(profile.payload_key)},{"payloadIv",block(profile.payload_iv)},{"signatureSalt",block(profile.signature_salt)},{"deviceKey",block(profile.device_key)},{"deviceIv",block(profile.device_iv)},{"rsaPublicDer",Json::string(base64(profile.rsa_public_der))}}).encode();
}
Profile decode_profile(const std::string& encoded){
  const auto root=Json::parse(encoded);const auto* version=root.find("version");if(!version||version->integer()!=2)throw std::runtime_error("QIMEI profile version invalid");
  const auto value=[&](const char* name){const auto* item=root.find(name);if(!item||item->kind!=Json::Kind::string)throw std::runtime_error("QIMEI profile field unavailable");return unbase64(item->text);};
  const auto block=[&](const char* name){const auto raw=value(name);if(raw.size()!=16)throw std::runtime_error("QIMEI profile block length invalid");Block out{};std::copy(raw.begin(),raw.end(),out.begin());return out;};
  Profile out;out.default_key=block("defaultKey");out.default_iv=block("defaultIv");out.payload_key=block("payloadKey");out.payload_iv=block("payloadIv");out.signature_salt=block("signatureSalt");out.device_key=block("deviceKey");out.device_iv=block("deviceIv");out.rsa_public_der=value("rsaPublicDer");if(out.rsa_public_der.empty()||out.rsa_public_der.size()>4096)throw std::runtime_error("QIMEI public profile key length invalid");return out;
}
Bytes modified_utf8(const std::u16string& text){
  Bytes out;for(std::uint16_t ch:text){if(ch>0&&ch<=0x7f)out.push_back(std::uint8_t(ch));else if(ch<=0x7ff){out.push_back(std::uint8_t(0xc0|(ch>>6)));out.push_back(std::uint8_t(0x80|(ch&63)));}else{out.push_back(std::uint8_t(0xe0|(ch>>12)));out.push_back(std::uint8_t(0x80|((ch>>6)&63)));out.push_back(std::uint8_t(0x80|(ch&63)));}}
  return out;
}
Bytes android_jni_utf8(const std::u16string& text){
  Bytes out;for(std::size_t i=0;i<text.size();++i){const auto ch=std::uint16_t(text[i]);if(ch>=0xd800&&ch<=0xdbff&&i+1<text.size()&&text[i+1]>=0xdc00&&text[i+1]<=0xdfff){const auto code=0x10000u+((ch-0xd800u)<<10)+(std::uint16_t(text[++i])-0xdc00u);out.push_back(std::uint8_t(0xf0|(code>>18)));out.push_back(std::uint8_t(0x80|((code>>12)&63)));out.push_back(std::uint8_t(0x80|((code>>6)&63)));out.push_back(std::uint8_t(0x80|(code&63)));}else{const auto encoded=modified_utf8(std::u16string{char16_t(ch)});out.insert(out.end(),encoded.begin(),encoded.end());}}
  return out;
}
}
