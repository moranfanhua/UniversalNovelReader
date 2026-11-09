#pragma once
#include <array>
#include <cstdint>
#include <map>
#include <string>
#include <variant>
#include <vector>

namespace qimei {
using Bytes=std::vector<std::uint8_t>;
using Block=std::array<std::uint8_t,16>;
using SessionKey=std::array<std::uint8_t,32>;
struct Profile {
  Block default_key{},default_iv{},payload_key{},payload_iv{},signature_salt{},device_key{},device_iv{};
  Bytes rsa_public_der;
};
// Bytes are the SDK's already encoded string bytes. This API does not invent device fields.
using Scalar=std::variant<std::monostate,Bytes,std::int64_t,bool,double>;
using Record=std::map<std::uint32_t,Scalar>;
struct CommonInfo {
  std::uint32_t command=1,flags=0;
  Bytes installation_uin,app_key,sdk_version,app_version,os_version,model;
  // Header field 8 is the privacy provider's model (UserInfo TYPE_MODEL).
  Bytes qimei36,qimei,process_name,network;
  std::int32_t sequence=1;
};
Bytes bytes(const std::string& value);
std::string hex(const Bytes& value);
Bytes unhex(const std::string& value);
std::string base64(const Bytes& value);
Bytes unbase64(const std::string& value);
Bytes encode_body(const Record& fields,std::uint32_t max_field=18);
Bytes encode_frame(const CommonInfo& common,const Bytes& body);
Bytes encrypt_cbc(const Bytes& plain,const Block& key,const Block& iv);
Bytes decrypt_cbc(const Bytes& encrypted,const Block& key,const Block& iv);
std::string seal_payload(const Bytes& frame,const SessionKey& request_key,const Profile& profile);
Bytes open_payload(const std::string& encoded,const SessionKey& request_key,const Profile& profile);
std::string signature(const Bytes& input,std::uint64_t timestamp_ms,const Block& salt);
Bytes signature_input(std::uint32_t crypt,const std::string& encrypted_key,const std::string& pms,const std::string& time,const std::string& nonce);
std::string encrypt_request_key(const SessionKey& key,const Profile& profile);
// Selected SDK oz/oo transformation. The caller supplies actual authorized
// Android ID / model bytes; empty input remains empty, rather than an AES pad block.
std::string encode_device_value(const Bytes& input,const Profile& profile);
SessionKey random_session_key();
std::string random_nonce();
// Configuration extraction only: no SDK code executes, on any host platform.
Profile selected_profile(const Bytes& original_arm64_elf);
}
