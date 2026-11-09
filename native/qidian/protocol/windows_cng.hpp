#pragma once
#include <cstddef>
#include <cstdint>
#include <vector>

namespace qimei::cng {
using Bytes=std::vector<std::uint8_t>;
enum class Hash {md5,sha256};
enum class Cipher {aes,des,des3};
Bytes digest(const Bytes& input,Hash method);
Bytes cbc(const Bytes& input,const Bytes& key,const Bytes& iv,Cipher cipher,bool encrypt);
Bytes rsa(const Bytes& input,const Bytes& public_der);
void random(std::uint8_t* output,std::size_t length);
}
