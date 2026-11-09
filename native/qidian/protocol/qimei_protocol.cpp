#include "qimei_protocol.hpp"
#include "qimei_crypto.hpp"
#include <algorithm>
#include <cstring>
#include <limits>
#include <memory>
#include <stdexcept>

namespace qimei {
namespace {
void require(bool condition,const char* message){if(!condition)throw std::runtime_error(message);}
std::uint32_t le32(const std::uint8_t* p){return std::uint32_t(p[0])|(std::uint32_t(p[1])<<8)|(std::uint32_t(p[2])<<16)|(std::uint32_t(p[3])<<24);}
std::uint64_t le64(const std::uint8_t* p){return le32(p)|(std::uint64_t(le32(p+4))<<32);}
void put32(std::uint8_t* out,std::uint32_t value){for(unsigned i=0;i<4;++i)out[i]=std::uint8_t(value>>(i*8));}
void varint(Bytes& out,std::uint64_t value){do{auto next=std::uint8_t(value&127);value>>=7;out.push_back(next|(value?128:0));}while(value);}
void field(Bytes& out,std::uint32_t tag,const Bytes& value){varint(out,(std::uint64_t(tag)<<3)|2);varint(out,value.size());out.insert(out.end(),value.begin(),value.end());}
void field(Bytes& out,std::uint32_t tag,std::uint64_t value){varint(out,std::uint64_t(tag)<<3);varint(out,value);}
std::uint32_t rotate(std::uint32_t x,unsigned bits){return (x<<bits)|(x>>(32-bits));}
void quarter(std::uint32_t& a,std::uint32_t& b,std::uint32_t& c,std::uint32_t& d){a+=b;d=rotate(d^a,16);c+=d;b=rotate(b^c,12);a+=b;d=rotate(d^a,8);c+=d;b=rotate(b^c,7);}
std::array<std::uint8_t,64> chacha_time_block(std::uint32_t time){
  std::array<std::uint32_t,16> initial={0x61707865,0x3320646e,0x79622d32,0x6b206574,time,0,0,0,0,0,0,0,0,0,0xef44a2a3,0x65a4e57f};auto state=initial;
  for(int i=0;i<10;++i){quarter(state[0],state[4],state[8],state[12]);quarter(state[1],state[5],state[9],state[13]);quarter(state[2],state[6],state[10],state[14]);quarter(state[3],state[7],state[11],state[15]);quarter(state[0],state[5],state[10],state[15]);quarter(state[1],state[6],state[11],state[12]);quarter(state[2],state[7],state[8],state[13]);quarter(state[3],state[4],state[9],state[14]);}
  std::array<std::uint8_t,64> result{};for(std::size_t i=0;i<16;++i)put32(result.data()+4*i,state[i]+initial[i]);return result;
}
std::pair<Block,Block> split(const SessionKey& key){Block first{},second{};std::copy_n(key.begin(),16,first.begin());std::copy_n(key.begin()+16,16,second.begin());return {first,second};}
}
Bytes bytes(const std::string& value){return Bytes(value.begin(),value.end());}
std::string hex(const Bytes& value){constexpr char alphabet[]="0123456789abcdef";std::string out;out.reserve(value.size()*2);for(auto ch:value){out+=alphabet[ch>>4];out+=alphabet[ch&15];}return out;}
Bytes unhex(const std::string& value){
  require(value.size()%2==0,"QIMEI invalid hex length");auto digit=[](char c){if(c>='0'&&c<='9')return c-'0';if(c>='a'&&c<='f')return c-'a'+10;if(c>='A'&&c<='F')return c-'A'+10;throw std::runtime_error("QIMEI invalid hex character");};
  Bytes out;out.reserve(value.size()/2);for(std::size_t i=0;i<value.size();i+=2)out.push_back(std::uint8_t((digit(value[i])<<4)|digit(value[i+1])));return out;
}
std::string base64(const Bytes& value){
  constexpr char alphabet[]="ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/";
  require(value.size()<=std::size_t(std::numeric_limits<int>::max()/4*3),"QIMEI Base64 input too large");
  std::string out;out.reserve(4*((value.size()+2)/3));
  for(std::size_t i=0;i<value.size();i+=3){const auto left=value.size()-i;const std::uint32_t n=(std::uint32_t(value[i])<<16)|(left>1?std::uint32_t(value[i+1])<<8:0)|(left>2?value[i+2]:0);out+=alphabet[n>>18];out+=alphabet[(n>>12)&63];out+=left>1?alphabet[(n>>6)&63]:'=';out+=left>2?alphabet[n&63]:'=';}
  return out;
}
Bytes unbase64(const std::string& value){
  require(value.size()%4==0&&value.size()<=std::size_t(std::numeric_limits<int>::max()),"QIMEI Base64 length invalid");if(value.empty())return {};
  const auto first=value.find('=');const auto padding=first==std::string::npos?0:value.size()-first;
  require(padding<=2&&(first==std::string::npos||value.find_first_not_of('=',first)==std::string::npos),"QIMEI Base64 padding invalid");
  const auto digit=[](char c)->std::uint32_t {if(c>='A'&&c<='Z')return c-'A';if(c>='a'&&c<='z')return c-'a'+26;if(c>='0'&&c<='9')return c-'0'+52;if(c=='+')return 62;if(c=='/')return 63;throw std::runtime_error("QIMEI Base64 character invalid");};
  Bytes out;out.reserve(value.size()/4*3-padding);
  for(std::size_t i=0;i<value.size();i+=4){const auto n=(digit(value[i])<<18)|(digit(value[i+1])<<12)|(value[i+2]=='='?0:digit(value[i+2])<<6)|(value[i+3]=='='?0:digit(value[i+3]));out.push_back(std::uint8_t(n>>16));if(value[i+2]!='=')out.push_back(std::uint8_t(n>>8));if(value[i+3]!='=')out.push_back(std::uint8_t(n));}
  require(base64(out)==value,"QIMEI Base64 is noncanonical");return out;
}
Bytes encode_body(const Record& fields,std::uint32_t max_field){
  require(max_field<=18,"QIMEI unsupported register body range");Bytes out;
  for(const auto& [number,value]:fields){if(number==0||number>max_field)continue;if(auto text=std::get_if<Bytes>(&value))field(out,number,*text);else if(auto integer=std::get_if<std::int64_t>(&value))field(out,number,std::uint64_t(*integer));}
  return out;
}
Bytes encode_frame(const CommonInfo& common,const Bytes& body){
  Bytes header;field(header,1,common.command);field(header,2,common.installation_uin);field(header,3,common.flags);field(header,4,common.app_key);field(header,5,common.sdk_version);field(header,6,common.app_version);field(header,7,common.os_version);field(header,8,common.model);field(header,9,common.qimei36);field(header,10,common.qimei);field(header,11,common.process_name);field(header,12,common.network);field(header,13,std::uint64_t(std::int64_t(common.sequence)));
  Bytes frame;field(frame,1,header);field(frame,2,body);return frame;
}
Bytes encrypt_cbc(const Bytes& plain,const Block& key,const Block& iv){return crypto::cbc(plain,key,iv,true);}
Bytes decrypt_cbc(const Bytes& encrypted,const Block& key,const Block& iv){require(!encrypted.empty()&&encrypted.size()%16==0,"QIMEI ciphertext length invalid");return crypto::cbc(encrypted,key,iv,false);}
std::string seal_payload(const Bytes& frame,const SessionKey& request_key,const Profile& profile){
  auto inner=encrypt_cbc(frame,profile.payload_key,profile.payload_iv);Bytes prefixed={3,0,0,0,1};prefixed.insert(prefixed.end(),inner.begin(),inner.end());const auto [key,iv]=split(request_key);return base64(encrypt_cbc(prefixed,key,iv));
}
Bytes open_payload(const std::string& encoded,const SessionKey& request_key,const Profile& profile){
  const auto [key,iv]=split(request_key);auto prefixed=decrypt_cbc(unbase64(encoded),key,iv);require(prefixed.size()>=21&&std::equal(prefixed.begin(),prefixed.begin()+5,Bytes{3,0,0,0,1}.begin()),"QIMEI request frame prefix invalid");return decrypt_cbc(Bytes(prefixed.begin()+5,prefixed.end()),profile.payload_key,profile.payload_iv);
}
std::string signature(const Bytes& input,std::uint64_t timestamp_ms,const Block& salt){
  const auto time=std::uint32_t(timestamp_ms);const auto first=crypto::digest(input,crypto::Hash::md5);const auto stream=chacha_time_block(time);std::array<std::uint8_t,16> transformed{};for(std::size_t i=0;i<16;++i)transformed[i]=first[i]^stream[i];
  const std::array<std::uint8_t,8> mask={0x28,transformed[5],0x47,0x2b,first[4],0x2c,0x4c,0x4b};Bytes second_input(salt.begin(),salt.end());second_input.insert(second_input.end(),mask.begin(),mask.end());const auto second=crypto::digest(second_input,crypto::Hash::md5);
  const std::array<std::uint8_t,16> mix={first[0],first[1],first[2],first[3],std::uint8_t(time>>24),0,0,0,transformed[1],transformed[2],transformed[3],transformed[4],0x78,0x56,0x34,0x12};
  Bytes raw={0x4c,0x43,0x85,0x10,first[4],transformed[5],std::uint8_t(time>>24),std::uint8_t(time>>16),std::uint8_t(time>>8),std::uint8_t(time)};
  for(std::size_t i=0;i<16;++i){raw.push_back(second[i]^mask[i%8]^mix[i]);}
  raw.resize(34,0);return hex(raw);
}
Bytes signature_input(std::uint32_t crypt,const std::string& encrypted_key,const std::string& pms,const std::string& time,const std::string& nonce){require(crypt==1||crypt==2,"QIMEI crypt mode invalid");return bytes(std::to_string(crypt)+(crypt==1?encrypted_key:std::string())+pms+time+nonce);}
std::string encrypt_request_key(const SessionKey& key,const Profile& profile){return base64(crypto::rsa(Bytes(key.begin(),key.end()),profile.rsa_public_der));}
std::string encode_device_value(const Bytes& input,const Profile& profile){return input.empty()?std::string():base64(encrypt_cbc(input,profile.device_key,profile.device_iv));}
SessionKey random_session_key(){SessionKey out{};crypto::random(out.data(),out.size());return out;}
std::string random_nonce(){Bytes out(8);crypto::random(out.data(),out.size());return hex(out);}
Profile selected_profile(const Bytes& elf){
  require(hex(crypto::digest(elf,crypto::Hash::sha256))=="406db2b2d01bf34d62e849bccaf8809510ee4ad0e312d57e2f905171fa5ae68f","Unsupported QIMEI SDK profile");
  const auto at=[&](std::uint64_t va,std::size_t size){
    require(elf.size()>=64,"QIMEI ELF header truncated");const auto ph=le64(elf.data()+32);const auto entry=std::uint16_t(elf[54])|(std::uint16_t(elf[55])<<8);const auto count=std::uint16_t(elf[56])|(std::uint16_t(elf[57])<<8);
    for(unsigned i=0;i<unsigned(count);++i){const auto position=ph+std::uint64_t(i)*std::uint64_t(entry);require(position<=elf.size()&&elf.size()-position>=56,"QIMEI ELF segment truncated");const auto* p=elf.data()+position;if(le32(p)!=1)continue;const auto offset=le64(p+8),base=le64(p+16),length=le64(p+32);if(va>=base&&va-base<=length&&size<=length-(va-base)){const auto start=offset+va-base;require(start<=elf.size()&&size<=elf.size()-start,"QIMEI ELF constant truncated");return Bytes(elf.begin()+std::ptrdiff_t(start),elf.begin()+std::ptrdiff_t(start+size));}}
    throw std::runtime_error("QIMEI profile constant unavailable");
  };
  const auto text=[&](std::uint32_t offset){const auto header=at(0x81d4c+offset,3);const auto size=std::uint16_t(header[0])|(std::uint16_t(header[1])<<8);require(size>0&&size<1024&&std::uint32_t(size)+offset<0x24fe,"QIMEI SDK string length invalid");auto out=at(0x81d4c+offset+3,std::size_t(size));for(std::size_t i=0;i<out.size();++i)out[i]^=std::uint8_t(header[2]+0x53*i);require(out.back()==0,"QIMEI SDK string terminator invalid");out.pop_back();return std::string(out.begin(),out.end());};
  const auto block=[&](std::uint32_t offset){const auto value=unhex(text(offset));require(value.size()==16,"QIMEI profile block length invalid");Block out{};std::copy(value.begin(),value.end(),out.begin());return out;};
  const auto raw_block=[&](std::uint32_t offset){const auto value=bytes(text(offset));require(value.size()==16,"QIMEI device block length invalid");Block out{};std::copy(value.begin(),value.end(),out.begin());return out;};
  Profile out;out.default_key=block(0x1742);out.default_iv=block(0x1766);out.payload_key=block(0x178a);out.payload_iv=block(0x17ae);out.device_key=raw_block(0x1418);out.device_iv=raw_block(0x142c);const auto salt=at(0x84800,16);std::copy(salt.begin(),salt.end(),out.signature_salt.begin());out.rsa_public_der=unbase64(text(0x145a));return out;
}
}
