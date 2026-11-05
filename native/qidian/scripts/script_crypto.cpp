#include "script_crypto.hpp"
#include "mbedtls/aes.h"
#include "mbedtls/blowfish.h"
#include "mbedtls/camellia.h"
#include "mbedtls/des.h"
#include "mbedtls/xtea.h"
#include <algorithm>
#include <array>
#include <stdexcept>

namespace qimei::script {
namespace {
constexpr char alphabet[]="ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789!#$%&()*+,./:;<=>?@[]^_`{|}~\"";
void check(bool value){if(!value)throw std::runtime_error("FockRT cipher data invalid");}
}
Bytes cipher(unsigned kind,bool encrypt,const Bytes& input,const Bytes& material,bool cbc){
  check(kind<6&&material.size()>=32&&input.size()<=1024*1024);
  const std::size_t block=(kind==0||kind==2)?16:8;
  Bytes data=input;
  if(encrypt){const auto padding=std::uint8_t(block-data.size()%block);data.insert(data.end(),padding,padding);}
  else check(!data.empty()&&data.size()%block==0);
  Bytes out(data.size());std::array<unsigned char,16> iv{};const int mode=encrypt?1:0;int result=-1;
  const auto* key=material.data();
  const auto blocks=[&](const auto& transform){int status=0;for(std::size_t offset=0;offset<data.size()&&!status;offset+=block)status=transform(data.data()+offset,out.data()+offset);return status;};
  switch(kind){
    case 0:{
      for(unsigned i=0;i<16;++i)iv[i]=key[i*2];
      mbedtls_aes_context c;mbedtls_aes_init(&c);result=encrypt?mbedtls_aes_setkey_enc(&c,key,256):mbedtls_aes_setkey_dec(&c,key,256);
      if(!result)result=cbc?mbedtls_aes_crypt_cbc(&c,mode,data.size(),iv.data(),data.data(),out.data()):blocks([&](auto* a,auto* b){return mbedtls_aes_crypt_ecb(&c,mode,a,b);});
      mbedtls_aes_free(&c);break;
    }
    case 1:{
      std::copy_n(key+11,8,iv.begin());mbedtls_blowfish_context c;mbedtls_blowfish_init(&c);result=mbedtls_blowfish_setkey(&c,key+(cbc?11:5),64);
      if(!result)result=cbc?mbedtls_blowfish_crypt_cbc(&c,mode,data.size(),iv.data(),data.data(),out.data()):blocks([&](auto* a,auto* b){return mbedtls_blowfish_crypt_ecb(&c,mode,a,b);});
      mbedtls_blowfish_free(&c);break;
    }
    case 2:{
      std::array<unsigned char,32> reversed{};std::reverse_copy(material.begin(),material.begin()+32,reversed.begin());const auto* selected=cbc?key:reversed.data();
      std::copy_n(key+16,16,iv.begin());mbedtls_camellia_context c;mbedtls_camellia_init(&c);result=encrypt?mbedtls_camellia_setkey_enc(&c,selected,256):mbedtls_camellia_setkey_dec(&c,selected,256);
      if(!result)result=cbc?mbedtls_camellia_crypt_cbc(&c,mode,data.size(),iv.data(),data.data(),out.data()):blocks([&](auto* a,auto* b){return mbedtls_camellia_crypt_ecb(&c,mode,a,b);});
      mbedtls_camellia_free(&c);break;
    }
    case 3:{
      std::array<unsigned char,8> sampled{};for(unsigned i=0;i<8;++i)sampled[i]=key[i*4];const auto* selected=cbc?key:sampled.data();
      std::copy_n(key,4,iv.begin());std::copy_n(key+28,4,iv.begin()+4);mbedtls_des_context c;mbedtls_des_init(&c);result=encrypt?mbedtls_des_setkey_enc(&c,selected):mbedtls_des_setkey_dec(&c,selected);
      if(!result)result=cbc?mbedtls_des_crypt_cbc(&c,mode,data.size(),iv.data(),data.data(),out.data()):blocks([&](auto* a,auto* b){return mbedtls_des_crypt_ecb(&c,a,b);});
      mbedtls_des_free(&c);break;
    }
    case 4:{
      const auto* selected=key+(cbc?0:1);std::copy_n(key+16,8,iv.begin());mbedtls_des3_context c;mbedtls_des3_init(&c);result=encrypt?mbedtls_des3_set3key_enc(&c,selected):mbedtls_des3_set3key_dec(&c,selected);
      if(!result)result=cbc?mbedtls_des3_crypt_cbc(&c,mode,data.size(),iv.data(),data.data(),out.data()):blocks([&](auto* a,auto* b){return mbedtls_des3_crypt_ecb(&c,a,b);});
      mbedtls_des3_free(&c);break;
    }
    case 5:{
      std::array<unsigned char,16> odd{};for(unsigned i=0;i<16;++i)odd[i]=key[i*2+1];for(unsigned i=0;i<8;++i)iv[i]=odd[i*2];
      mbedtls_xtea_context c;mbedtls_xtea_init(&c);mbedtls_xtea_setup(&c,cbc?odd.data():key+16);
      result=cbc?mbedtls_xtea_crypt_cbc(&c,mode,data.size(),iv.data(),data.data(),out.data()):blocks([&](auto* a,auto* b){return mbedtls_xtea_crypt_ecb(&c,mode,a,b);});
      mbedtls_xtea_free(&c);break;
    }
  }
  check(result==0);
  if(!encrypt){const auto pad=out.back();check(pad>0&&pad<=block&&pad<=out.size());check(std::all_of(out.end()-pad,out.end(),[pad](auto byte){return byte==pad;}));out.resize(out.size()-pad);}
  return out;
}
std::string base91_encode(const Bytes& input){
  std::string out;unsigned queue=0,bits=0;
  for(auto byte:input){queue|=unsigned(byte)<<bits;bits+=8;if(bits>13){auto value=queue&8191;if(value>88){queue>>=13;bits-=13;}else{value=queue&16383;queue>>=14;bits-=14;}out+=alphabet[value%91];out+=alphabet[value/91];}}
  if(bits){out+=alphabet[queue%91];if(bits>7||queue>90)out+=alphabet[queue/91];}return out;
}
Bytes base91_decode(const std::string& input){
  check(input.size()<=2*1024*1024);Bytes out;unsigned queue=0,bits=0;int value=-1;
  for(unsigned char c:input){const auto* p=std::find(std::begin(alphabet),std::end(alphabet)-1,char(c));if(p==std::end(alphabet)-1)continue;const auto n=int(p-alphabet);if(value<0)value=n;else{value+=n*91;queue|=unsigned(value)<<bits;bits+=(value&8191)>88?13:14;while(bits>7){out.push_back(std::uint8_t(queue));queue>>=8;bits-=8;}value=-1;}}
  if(value>=0)out.push_back(std::uint8_t(queue|(unsigned(value)<<bits)));return out;
}
std::string api_signature(const Bytes& input){
  if(input.empty()||input.front()==0)return {};
  auto a=http::digest(http::DigestKind::md2,input);auto b=http::digest(http::DigestKind::md5,Bytes(a.begin(),a.end()));auto c=http::digest(http::DigestKind::md4,Bytes(b.begin(),b.end()));
  constexpr char symbols[]="0123456789abcdef";std::string out;for(auto v:c){out+=symbols[v>>4];out+=symbols[v&15];}return out;
}
std::uint16_t crc16(const Bytes& input){std::uint16_t c=0;for(auto b:input){c^=b;for(unsigned i=0;i<8;++i)c=std::uint16_t((c>>1)^((c&1)?0xa001:0));}return c;}
std::uint8_t crc8(const Bytes& input){std::uint8_t c=0;for(auto b:input){c^=b;for(unsigned i=0;i<8;++i)c=std::uint8_t((c<<1)^((c&128)?0x31:0));}return c;}
}
