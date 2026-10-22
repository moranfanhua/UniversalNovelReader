#include "default_signature.hpp"
#include <algorithm>
#include <stdexcept>

namespace qimei::http {
namespace {
constexpr std::array<std::uint32_t,64> constants={
  0x428a2f98,0x71374491,0xb5c0fbcf,0xe9b5dba5,0x3956c25b,0x59f111f1,0x923f82a4,0xab1c5ed5,
  0xd807aa98,0x12835b01,0x243185be,0x550c7dc3,0x72be5d74,0x80deb1fe,0x9bdc06a7,0xc19bf174,
  0xe49b69c1,0xefbe4786,0x0fc19dc6,0x240ca1cc,0x2de92c6f,0x4a7484aa,0x5cb0a9dc,0x76f988da,
  0x983e5152,0xa831c66d,0xb00327c8,0xbf597fc7,0xc6e00bf3,0xd5a79147,0x06ca6351,0x14292967,
  0x27b70a85,0x2e1b2138,0x4d2c6dfc,0x53380d13,0x650a7354,0x766a0abb,0x81c2c92e,0x92722c85,
  0xa2bfe8a1,0xa81a664b,0xc24b8b70,0xc76c51a3,0xd192e819,0xd6990624,0xf40e3585,0x106aa070,
  0x19a4c116,0x1e376c08,0x2748774c,0x34b0bcb5,0x391c0cb3,0x4ed8aa4a,0x5b9cca4f,0x682e6ff3,
  0x748f82ee,0x78a5636f,0x84c87814,0x8cc70208,0x90befffa,0xa4506ceb,0xbef9a3f7,0xc67178f2};
std::uint32_t rotate(std::uint32_t x,unsigned count){return (x>>count)|(x<<(32-count));}
std::string hex_byte(std::uint8_t value){constexpr char alphabet[]="0123456789abcdef";std::string out;out+=alphabet[value>>4];out+=alphabet[value&15];return out;}
}
Sha256Digest sha256(const Input& input){
  if(input.size()>16*1024*1024)throw std::invalid_argument("SHA256 input too large");
  Input padded=input;const auto bits=std::uint64_t(input.size())*8;padded.push_back(0x80);
  while(padded.size()%64!=56)padded.push_back(0);
  for(unsigned i=0;i<8;++i)padded.push_back(std::uint8_t(bits>>(56-i*8)));
  std::array<std::uint32_t,8> state={0x6a09e667,0xbb67ae85,0x3c6ef372,0xa54ff53a,0x510e527f,0x9b05688c,0x1f83d9ab,0x5be0cd19};
  for(std::size_t offset=0;offset<padded.size();offset+=64){
    std::array<std::uint32_t,64> words{};
    for(unsigned i=0;i<16;++i)for(unsigned j=0;j<4;++j)words[i]=(words[i]<<8)|padded[offset+i*4+j];
    for(unsigned i=16;i<64;++i){const auto x=words[i-15],y=words[i-2];words[i]=words[i-16]+(rotate(x,7)^rotate(x,18)^(x>>3))+words[i-7]+(rotate(y,17)^rotate(y,19)^(y>>10));}
    auto a=state[0],b=state[1],c=state[2],d=state[3],e=state[4],f=state[5],g=state[6],h=state[7];
    for(unsigned i=0;i<64;++i){const auto t1=h+(rotate(e,6)^rotate(e,11)^rotate(e,25))+((e&f)^(~e&g))+constants[i]+words[i];const auto t2=(rotate(a,2)^rotate(a,13)^rotate(a,22))+((a&b)^(a&c)^(b&c));h=g;g=f;f=e;e=d+t1;d=c;c=b;b=a;a=t1+t2;}
    state[0]+=a;state[1]+=b;state[2]+=c;state[3]+=d;state[4]+=e;state[5]+=f;state[6]+=g;state[7]+=h;
  }
  Sha256Digest out{};for(unsigned i=0;i<8;++i)for(unsigned j=0;j<4;++j)out[i*4+j]=std::uint8_t(state[i]>>(24-j*8));return out;
}
std::string cecelia_default(const Input& canonical,std::uint16_t seed){
  if(canonical.size()>16*1024*1024)throw std::invalid_argument("Default signature input too large");
  if(canonical.empty()||canonical.front()==0)return {};
  const auto prefix=std::to_string(seed);Input message(prefix.begin(),prefix.end());
  message.insert(message.end(),canonical.begin(),canonical.begin()+std::min(canonical.size(),10000-message.size()));
  // Bundled bytecode creates a Uint8Array view, then replaces the first two
  // bytes before invoking the native SHA256 function. Base91 encode/decode is
  // an identity here and need not be part of this selected-script evaluator.
  if(message.size()>2){message[0]=6;message[1]=66;}
  std::string out="0_"+hex_byte(std::uint8_t(seed))+hex_byte(std::uint8_t(seed>>8));
  for(const auto byte:sha256(message))out+=hex_byte(byte);
  return out;
}
}
