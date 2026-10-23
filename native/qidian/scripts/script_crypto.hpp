#pragma once
#include "fock_digest.hpp"
namespace qimei::script {
using Bytes=http::Input;
Bytes cipher(unsigned kind,bool encrypt,const Bytes& input,const Bytes& material,bool cbc=true);
std::string base91_encode(const Bytes& input);
Bytes base91_decode(const std::string& input);
std::string api_signature(const Bytes& input);
std::uint16_t crc16(const Bytes& input);
std::uint8_t crc8(const Bytes& input);
}
