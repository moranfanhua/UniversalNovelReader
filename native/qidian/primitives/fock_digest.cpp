#include "fock_digest.hpp"
#include "md2_table.hpp"
#include <algorithm>
#include <cmath>
#include <limits>
#include <stdexcept>

namespace qimei::http {
namespace {
Digest md2(const Input& input){
  Input padded=input;const auto padding=std::uint8_t(16-input.size()%16);padded.insert(padded.end(),padding,padding);
  std::array<std::uint8_t,48> state{};Digest checksum{};
  const auto block=[&](const std::uint8_t* bytes){
    for(std::size_t i=0;i<16;++i){state[16+i]=bytes[i];state[32+i]=std::uint8_t(state[i]^bytes[i]);}
    std::uint8_t previous=0;
    for(unsigned round=0;round<18;++round){for(auto& value:state){value^=md2_substitution[previous];previous=value;}previous=std::uint8_t(previous+round);}
    previous=checksum[15];for(std::size_t i=0;i<16;++i){checksum[i]^=md2_substitution[bytes[i]^previous];previous=checksum[i];}
  };
  for(std::size_t offset=0;offset<padded.size();offset+=16)block(padded.data()+offset);
  const auto last=checksum;block(last.data());Digest out{};std::copy_n(state.begin(),16,out.begin());return out;
}
std::uint32_t rotate(std::uint32_t value,unsigned count){return (value<<count)|(value>>(32-count));}
std::uint32_t word(const std::uint8_t* data){return std::uint32_t(data[0])|(std::uint32_t(data[1])<<8)|(std::uint32_t(data[2])<<16)|(std::uint32_t(data[3])<<24);}
Digest md4_or_md5(const Input& input,bool is_md5){
  Input padded=input;const auto bits=std::uint64_t(input.size())*8;padded.push_back(0x80);
  while(padded.size()%64!=56)padded.push_back(0);
  for(unsigned i=0;i<8;++i)padded.push_back(std::uint8_t(bits>>(i*8)));
  std::array<std::uint32_t,4> state={0x67452301,0xefcdab89,0x98badcfe,0x10325476};
  constexpr std::array<unsigned,16> md5_rot={7,12,17,22,5,9,14,20,4,11,16,23,6,10,15,21};
  constexpr std::array<unsigned,12> md4_rot={3,7,11,19,3,5,9,13,3,9,11,15};
  static const auto constants=[](){std::array<std::uint32_t,64> values{};for(unsigned i=0;i<64;++i)values[i]=std::uint32_t(std::floor(std::abs(std::sin(double(i+1)))*4294967296.0));return values;}();
  for(std::size_t offset=0;offset<padded.size();offset+=64){
    std::array<std::uint32_t,16> message{};for(unsigned i=0;i<16;++i)message[i]=word(padded.data()+offset+i*4);
    auto a=state[0],b=state[1],c=state[2],d=state[3];
    for(unsigned i=0;i<(is_md5?64u:48u);++i){
      const auto round=i/16,j=i%16;std::uint32_t f=0,k=0;unsigned g=j,shift=0;
      if(is_md5){
        if(round==0)f=(b&c)|(~b&d);
        else if(round==1){f=(d&b)|(~d&c);g=(5*i+1)%16;}
        else if(round==2){f=b^c^d;g=(3*i+5)%16;}
        else{f=c^(b|~d);g=(7*i)%16;}
        k=constants[i];shift=md5_rot[round*4+j%4];
      }else{
        if(round==0)f=(b&c)|(~b&d);
        else if(round==1){f=(b&c)|(b&d)|(c&d);g=(j%4)*4+j/4;k=0x5a827999;}
        else{f=b^c^d;g=((j&1)<<3)|((j&2)<<1)|((j&4)>>1)|((j&8)>>3);k=0x6ed9eba1;}
        shift=md4_rot[round*4+j%4];
      }
      const auto next=rotate(a+f+message[g]+k,shift)+(is_md5?b:0);a=d;d=c;c=b;b=next;
    }
    state[0]+=a;state[1]+=b;state[2]+=c;state[3]+=d;
  }
  Digest out{};for(unsigned i=0;i<4;++i)for(unsigned j=0;j<4;++j)out[i*4+j]=std::uint8_t(state[i]>>(j*8));return out;
}
std::string hex(const Digest& value){constexpr char symbols[]="0123456789abcdef";std::string out;out.reserve(32);for(const auto byte:value){out+=symbols[byte>>4];out+=symbols[byte&15];}return out;}
Input input(const Digest& value){return Input(value.begin(),value.end());}
}
Digest digest(DigestKind kind,const Input& value){
  if(value.size()>16*1024*1024)throw std::length_error("HTTP digest input exceeds supported boundary");
  switch(kind){case DigestKind::md2:return md2(value);case DigestKind::md4:return md4_or_md5(value,false);case DigestKind::md5:return md4_or_md5(value,true);}
  throw std::invalid_argument("HTTP digest kind unsupported");
}
std::uint32_t crc32(const Input& value){std::uint32_t out=0xffffffff;for(auto byte:value){out^=byte;for(unsigned bit=0;bit<8;++bit)out=(out>>1)^(0xedb88320u&std::uint32_t(0-(out&1)));}return ~out;}
std::string sn(const Input& value){
  if(value.empty()||value.front()==0)return {};
  constexpr std::array<DigestKind,3> order={DigestKind::md2,DigestKind::md4,DigestKind::md5};const auto crc=crc32(value);
  const auto first=digest(order[crc%3],value),second=digest(order[(crc>>8)%3],input(first));return hex(digest(order[(crc>>8)%3],input(second)));
}
std::string wnid(const Input& value){
  if(value.empty()||value.front()==0)return {};
  constexpr std::array<DigestKind,3> order={DigestKind::md5,DigestKind::md2,DigestKind::md4};const auto crc=crc32(value);
  return hex(digest(order[(crc%31)%3],input(digest(order[crc%3],value))));
}
}
