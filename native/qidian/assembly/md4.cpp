// Independent implementation of RFC 1320's word operations (not its appendix code).
// Algorithm reference: https://www.rfc-editor.org/rfc/rfc1320
#include "md4.hpp"
#include <vector>

namespace portable_md4 {
std::array<std::uint8_t,16> digest(const std::uint8_t* data,std::size_t size) {
  std::vector<std::uint8_t> padded(data,data+size);
  padded.push_back(0x80);
  while(padded.size()%64!=56)padded.push_back(0);
  const auto bits=static_cast<std::uint64_t>(size)*8U;
  for(unsigned i=0;i<8;++i)padded.push_back(static_cast<std::uint8_t>(bits>>(i*8U)));
  std::array<std::uint32_t,4> state{0x67452301U,0xefcdab89U,0x98badcfeU,0x10325476U};
  constexpr std::array<unsigned,16> third{0,8,4,12,2,10,6,14,1,9,5,13,3,11,7,15};
  constexpr unsigned shifts[3][4]{{3,7,11,19},{3,5,9,13},{3,9,11,15}};
  constexpr unsigned index[4]{0,3,2,1};
  for(std::size_t offset=0;offset<padded.size();offset+=64) {
    std::array<std::uint32_t,16> words{};
    for(unsigned i=0;i<16;++i)for(unsigned j=0;j<4;++j)
      words[i]|=static_cast<std::uint32_t>(padded[offset+i*4+j])<<(j*8U);
    auto v=state;
    for(unsigned round=0;round<3;++round)for(unsigned step=0;step<16;++step) {
      const auto a=index[step%4],b=(a+1)%4,c=(a+2)%4,d=(a+3)%4;
      const auto f=round==0?((v[b]&v[c])|(~v[b]&v[d])):
                   round==1?((v[b]&v[c])|(v[b]&v[d])|(v[c]&v[d])):(v[b]^v[c]^v[d]);
      const auto word=round==0?step:round==1?(step%4)*4+step/4:third[step];
      const auto constant=round==0?0U:round==1?0x5a827999U:0x6ed9eba1U;
      const auto value=v[a]+f+words[word]+constant;
      const auto shift=shifts[round][step%4];
      v[a]=(value<<shift)|(value>>(32U-shift));
    }
    for(unsigned i=0;i<4;++i)state[i]+=v[i];
  }
  std::array<std::uint8_t,16> result{};
  for(unsigned i=0;i<4;++i)for(unsigned j=0;j<4;++j)result[i*4+j]=static_cast<std::uint8_t>(state[i]>>(j*8U));
  return result;
}
}
