#include "qimei_response.hpp"
#include "qimei_json.hpp"
#include <algorithm>
#include <limits>
#include <stdexcept>

namespace qimei {
namespace {
std::string sdk_string(const Json* value){
  if(!value)return {};
  if(value->kind==Json::Kind::string)return value->text;
  if(value->kind==Json::Kind::null_value)return "null";
  return {};
}
std::uint64_t varint(const Bytes& data,std::size_t& offset){
  std::uint64_t value=0;
  for(unsigned shift=0;shift<70;shift+=7){
    if(offset==data.size())throw std::runtime_error("QIMEI response Protobuf is truncated");
    const auto ch=data[offset++];
    if(shift==63&&ch>1)throw std::runtime_error("QIMEI response integer overflow");
    value|=std::uint64_t(ch&127)<<shift;if((ch&128)==0)return value;
  }
  throw std::runtime_error("QIMEI response varint overflow");
}
}
DecodedResponse decode_transport_response(const std::string& transport,const SessionKey& request_key){
  DecodedResponse result;Json outer;
  try{outer=Json::parse(transport);}catch(const std::exception&){result.native_error=-10041;return result;}
  const auto* succeeded=outer.find("is");
  if(!succeeded||succeeded->integer()==0){result.native_error=-10042;return result;}
  Json reply;
  try{reply=Json::parse(sdk_string(outer.find("bd")));}catch(const std::exception&){result.native_error=-10043;return result;}
  const auto* code=reply.find("code");const auto data=sdk_string(reply.find("data"));
  if(data.empty()){result.native_error=-10044;result.service_code=code?std::int32_t(code->integer()):0;return result;}
  try{
    auto encrypted=unbase64(data);
    if(encrypted.empty()){result.native_error=-10046;return result;}
    Block key{},iv{};std::copy_n(request_key.begin(),16,key.begin());std::copy_n(request_key.begin()+16,16,iv.begin());
    result.body=decrypt_cbc(encrypted,key,iv);
    if(result.body.empty())result.native_error=-10047;
  }catch(const std::exception&){result.native_error=-10047;}
  return result;
}
Record decode_body(const Bytes& protobuf){
  if(protobuf.size()>2*1024*1024)throw std::runtime_error("QIMEI response body too large");
  Record result;std::size_t offset=0;
  while(offset<protobuf.size()){
    const auto tag=varint(protobuf,offset),number=tag>>3,wire=tag&7;
    if(number==0||number>0x1fffffff)throw std::runtime_error("QIMEI response field number invalid");
    if(wire==0){const auto value=std::uint32_t(varint(protobuf,offset));const auto signed_value=value<=0x7fffffff?std::int64_t(value):std::int64_t(value)-0x100000000LL;result[std::uint32_t(number)]=signed_value;}
    else if(wire==2){
      const auto size=varint(protobuf,offset);if(size>protobuf.size()-offset)throw std::runtime_error("QIMEI response string is truncated");
      result[std::uint32_t(number)]=Bytes(protobuf.begin()+std::ptrdiff_t(offset),protobuf.begin()+std::ptrdiff_t(offset+size));offset+=std::size_t(size);
    }else throw std::runtime_error("QIMEI response wire type unsupported");
  }
  return result;
}
Identifiers identifiers_from_body(const Bytes& protobuf){
  const auto fields=decode_body(protobuf);Identifiers result;
  const auto first=fields.find(1);if(first!=fields.end()){if(const auto* value=std::get_if<Bytes>(&first->second))result.qimei=*value;else if(const auto* integer=std::get_if<std::int64_t>(&first->second))result.qimei=bytes(std::to_string(*integer));}
  const auto second=fields.find(2);if(second!=fields.end()){if(const auto* value=std::get_if<Bytes>(&second->second))result.qimei36=*value;else if(const auto* integer=std::get_if<std::int64_t>(&second->second))result.qimei36=bytes(std::to_string(*integer));}
  return result;
}
std::string sdk_transport_response(const std::string& app_data){
  Json response;
  try{response=Json::parse(app_data);}catch(const std::exception&){return Json::object({{"is",Json::number(0)},{"ic",Json::string("1001")},{"rc",Json::number(200)},{"em",Json::string(app_data)}}).encode();}
  const auto* code=response.find("code");const auto* data=response.find("data");
  if(!code||!data)return Json::object({{"is",Json::number(0)},{"ic",Json::string("1001")},{"rc",Json::number(200)},{"em",Json::string(app_data)}}).encode();
  const auto text=data->kind==Json::Kind::object||data->kind==Json::Kind::array?data->encode():data->kind==Json::Kind::number?data->text:data->kind==Json::Kind::boolean?(data->boolean?"true":"false"):sdk_string(data);
  if(text.empty())return Json::object({{"is",Json::number(0)},{"ic",Json::string("1002")},{"rc",Json::number(200)},{"em",Json::string(app_data)}}).encode();
  std::string body=app_data;
  try{if(Json::parse(text).find("code"))body=text;}catch(const std::exception&){}
  return Json::object({{"is",Json::number(1)},{"bd",Json::string(body)},{"rc",Json::number(0)}}).encode();
}
}
