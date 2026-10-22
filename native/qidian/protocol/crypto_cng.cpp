#include "qimei_crypto.hpp"
#include "windows_cng.hpp"
namespace qimei::crypto {
Bytes digest(const Bytes& input,Hash method){return cng::digest(input,method==Hash::md5?cng::Hash::md5:cng::Hash::sha256);}
Bytes cbc(const Bytes& input,const Block& key,const Block& iv,bool encrypt){return cng::cbc(input,Bytes(key.begin(),key.end()),Bytes(iv.begin(),iv.end()),cng::Cipher::aes,encrypt);}
Bytes rsa(const Bytes& input,const Bytes& der){return cng::rsa(input,der);}
void random(std::uint8_t* output,std::size_t length){cng::random(output,length);}
}
