#include "crypto_cng.hpp"
#include "windows_cng.hpp"
namespace qimei::app {
Bytes cng_encrypt(Cipher kind,const Bytes& plain,const Bytes& key,const Bytes& iv){return cng::cbc(plain,key,iv,kind==Cipher::aes256_cbc?cng::Cipher::aes:kind==Cipher::des3_cbc?cng::Cipher::des3:cng::Cipher::des,true);}
}
