#pragma once
#include "qimei_protocol.hpp"

namespace qimei::crypto {
enum class Hash { md5,sha256 };
Bytes digest(const Bytes& input,Hash method);
Bytes cbc(const Bytes& input,const Block& key,const Block& iv,bool encrypt);
Bytes rsa(const Bytes& input,const Bytes& public_der);
void random(std::uint8_t* output,std::size_t length);
}
