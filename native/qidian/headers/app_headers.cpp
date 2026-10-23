#include "app_headers.hpp"
#include "selected_profile.hpp"
#include "registration_signature.hpp"
#include "default_signature.hpp"
#include <algorithm>
#include <stdexcept>
#include <string_view>

namespace qimei::app {
namespace {
Bytes bytes(std::string_view text){return {text.begin(),text.end()};}
std::string join(const std::vector<std::string>& values){std::string out;for(std::size_t i=0;i<values.size();++i){if(i)out+='|';out+=values[i];}return out;}
std::string hex(const qimei::http::Digest& digest){constexpr char chars[]="0123456789abcdef";std::string out;for(auto value:digest){out+=chars[value>>4];out+=chars[value&15];}return out;}
void valid_utf8(const std::string& text){
  for(std::size_t i=0;i<text.size();){
    const auto lead=static_cast<unsigned char>(text[i]);unsigned count=0;std::uint32_t point=0;
    if(lead<0x80){count=1;point=lead;}
    else if(lead>=0xc2&&lead<=0xdf){count=2;point=lead&31;}
    else if(lead>=0xe0&&lead<=0xef){count=3;point=lead&15;}
    else if(lead>=0xf0&&lead<=0xf4){count=4;point=lead&7;}
    else throw std::invalid_argument("App header text is not UTF-8");
    if(i+count>text.size())throw std::invalid_argument("App header UTF-8 truncated");
    for(unsigned n=1;n<count;++n){const auto value=static_cast<unsigned char>(text[i+n]);if((value&0xc0)!=0x80)throw std::invalid_argument("App header UTF-8 continuation invalid");point=(point<<6)|(value&63);}
    if((count==3&&point<0x800)||(count==4&&point<0x10000)||point>0x10ffff||(point>=0xd800&&point<=0xdfff))throw std::invalid_argument("App header UTF-8 scalar invalid");
    i+=count;
  }
}
Bytes encrypt_checked(const Encrypt& encrypt,Cipher cipher,const Bytes& plain,const Bytes& key,const Bytes& iv){
  if(!encrypt)throw std::invalid_argument("App header crypto backend missing");
  auto out=encrypt(cipher,plain,key,iv);const std::size_t block=cipher==Cipher::aes256_cbc?16:8;
  if(out.size()!=plain.size()+block-plain.size()%block)throw std::runtime_error("App header cipher result invalid");
  return out;
}
}
Bytes android_jni_utf8(const std::string& text){
  if(text.size()>16*1024*1024)throw std::length_error("App header text too large");
  valid_utf8(text);Bytes out;out.reserve(text.size());for(const auto value:bytes(text)){if(value==0){out.push_back(0xc0);out.push_back(0x80);}else out.push_back(value);}return out;
}
std::string base64(const Bytes& input,bool url_safe,bool app_spaces){
  const std::string_view alphabet=url_safe?"ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_":"ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/";
  std::string out;for(std::size_t i=0;i<input.size();i+=3){const auto n=input.size()-i;const std::uint32_t value=(std::uint32_t(input[i])<<16)|(n>1?std::uint32_t(input[i+1])<<8:0)|(n>2?input[i+2]:0);out+=alphabet[(value>>18)&63];out+=alphabet[(value>>12)&63];out+=n>1?alphabet[(value>>6)&63]:'=';out+=n>2?alphabet[value&63]:'=';}
  if(app_spaces){for(std::size_t i=60;i<out.size();i+=61)out.insert(i,1,' ');}return out;
}
std::string qdsign(const LegacySign& input,const Encrypt& encrypt){
  if(input.mode>=sign_keys.size())throw std::invalid_argument("Unsupported legacy signature mode");
  const auto digest=hex(qimei::http::digest(qimei::http::DigestKind::md5,android_jni_utf8(input.canonical)));
  const auto plain=android_jni_utf8(join({std::string(sign_prefixes[input.mode]),std::to_string(input.timestamp_ms),input.user_id,input.device,"1",input.version,input.emulator,digest,input.certificate_md5}));
  // The original native concatenation uses a 1024-byte allocation. Reject an
  // oversized identity/profile instead of reproducing its unsafe overwrite.
  if(plain.size()>=1024)throw std::length_error("Legacy signature context too large");
  return base64(encrypt_checked(encrypt,Cipher::des3_cbc,plain,bytes(sign_keys[input.mode]),bytes("01234567")),false,true);
}
std::string info_plain(const Context& c,std::uint64_t timestamp,bool allow_android_id){
  const auto out=join({c.device,c.version,std::to_string(c.width),std::to_string(c.height),c.stored_channel,c.os_release,std::to_string(c.client_type),c.model,std::to_string(c.version_code),c.package_channel,std::to_string(c.network_type),c.user_id,std::to_string(timestamp),std::to_string(c.emulator),c.qimei16,allow_android_id?c.android_id:"",c.huawei_referrer,c.oaid,c.qimei36,std::to_string(c.app_flag)});
  valid_utf8(out);return out;
}
std::string qdinfo(const Context& c,std::uint64_t timestamp,bool allow_android_id,const Encrypt& encrypt){
  return encrypt_info_text(info_plain(c,timestamp,allow_android_id),encrypt);
}
std::string encrypt_info_text(const std::string& plain,const Encrypt& encrypt){
  valid_utf8(plain);
  auto key=bytes(info_key);key.insert(key.end(),info_key.begin(),info_key.begin()+8);
  // FockUtil.getEncrypt follows String.getBytes(UTF-8), not JNI's NUL encoding.
  return base64(encrypt_checked(encrypt,Cipher::des3_cbc,bytes(plain),key,Bytes(8,0)));
}
std::string user_agent(const Context& c,const std::string& brand,std::uint32_t status_bar_dp,const std::string& base){
  const auto encode=[](const std::string& value){
    valid_utf8(value);constexpr char hex[]="0123456789ABCDEF";std::string out;
    for(auto ch:bytes(value)){if((ch>='a'&&ch<='z')||(ch>='A'&&ch<='Z')||(ch>='0'&&ch<='9')||ch=='.'||ch=='-'||ch=='*'||ch=='_')out+=char(ch);else if(ch==' ')out+='+';else{out+='%';out+=hex[ch>>4];out+=hex[ch&15];}}return out;
  };
  if(status_bar_dp>10000)throw std::invalid_argument("App status bar size invalid");
  std::string filtered;for(auto ch:bytes(base))if(ch>=0x20&&ch<=0x7e)filtered+=char(ch);
  return filtered+" QDReaderAndroid/"+c.version+"/"+std::to_string(c.version_code)+"/"+encode(c.stored_channel)+"/"+encode(brand)+"/getTabHeight_"+std::to_string(status_bar_dp+44);
}
std::string cookie(const CookieContext& c,const std::string& info,const std::string& q16,const std::string& q36){
  std::vector<std::pair<std::string,std::string>> fields;
  if(!c.token.empty())fields.emplace_back("cmfuToken",c.token);
  fields.insert(fields.end(),{{"QDInfo",info},{"ywkey",c.yw_key},{"ywguid",c.yw_guid},{"appId",c.app_id},{"areaId",c.area_id},{"lang",c.language},{"mode",c.mode},{"bar",c.bar},{"qid",q16},{"qidth",q36}});
  std::string out;
  const auto add=[&out](const std::string& name,const std::string& value){
    if(name.empty()||name.find_first_of("=;\r\n\0",0,5)!=std::string::npos||value.find_first_of(";\r\n\0",0,4)!=std::string::npos)throw std::invalid_argument("App cookie field invalid");
    out+=name+'='+value+"; ";
  };
  for(const auto& [name,value]:fields)add(name,value);
  for(const auto& [name,value]:c.extras)if(out.find(name+'=')==std::string::npos)add(name,value);
  return out;
}
std::string environment_json(const EnvironmentReport& r){
  const std::array<std::pair<std::string_view,std::string_view>,9> fields={{{"env",r.env},{"root",r.root},{"xposed",r.xposed},{"emulator",r.emulator},{"accessibility",r.accessibility},{"debug",r.debug},{"autojs",r.autojs},{"virtualXposed",r.virtual_xposed},{"x86",r.x86}}};
  std::string out="{";for(std::size_t i=0;i<fields.size();++i){const auto& [name,value]=fields[i];if(value.empty()||value.size()>20||!std::all_of(value.begin(),value.end(),[](char x){return x>='0'&&x<='9';}))throw std::invalid_argument("App environment measurement missing or invalid");if(i&&value!="0"&&value!="1")throw std::invalid_argument("App environment flag invalid");if(i)out+=',';out+='"';out+=name;out+="\":\"";out+=value;out+='"';}return out+'}';
}
Bytes fock_lock(const Bytes& plain,const Encrypt& encrypt){
  if(plain.empty()||plain.front()==0)throw std::invalid_argument("Fock lock input unavailable");
  const auto material=bytes(qimei::http::sn(plain));const auto selection=qimei::http::crc32(material);
  const auto layer=[&](const Bytes& data,unsigned which){return encrypt_checked(encrypt,which?Cipher::des_cbc:Cipher::aes256_cbc,data,Bytes(material.begin(),material.begin()+(which?8:32)),Bytes(material.begin(),material.begin()+(which?8:16)));};
  auto out=layer(layer(plain,selection&1),(selection>>4)&1);out.insert(out.end(),material.begin(),material.end());return out;
}
std::string gorgon(const EnvironmentReport& report,const Encrypt& encrypt){return base64(fock_lock(bytes(environment_json(report)),encrypt),true);}
Headers request_headers(const std::map<std::string,std::string>& input,const HeaderContext& h,const Encrypt& encrypt,const std::string& ibex){
  if(h.cecelia_script_id!=0&&(!h.signing_script||h.signing_script->id!=h.cecelia_script_id))throw std::invalid_argument("Remote App signing script missing");
  std::map<std::string,std::string> logical;
  for(const auto& [name,value]:input){std::string lowered;for(const auto ch:name){if(static_cast<unsigned char>(ch)>127)throw std::invalid_argument("App parameter name unsupported");lowered+=ch>='A'&&ch<='Z'?char(ch+32):ch;}if(!logical.emplace(lowered,value).second)throw std::invalid_argument("App parameter names collide");}
  const auto canonicalize=[](const auto& fields){std::string out;for(const auto& [name,value]:fields){if(!out.empty())out+='&';out+=name+'='+value;}return out;};
  const auto& c=h.device;LegacySign sign;sign.canonical=canonicalize(logical);sign.timestamp_ms=h.timestamp_ms;sign.user_id=c.user_id;sign.device=c.device;sign.version=c.version;sign.emulator=std::to_string(c.emulator);
  logical["qimei"]=c.qimei16;logical["clienttype"]="1";logical["versioncode"]=std::to_string(c.version_code);logical["tstamp"]=std::to_string(h.timestamp_ms);const auto canonical=canonicalize(logical);
  auto cookie_value=cookie(h.session,qdinfo(c,h.cookie_timestamp_ms.value_or(h.timestamp_ms),h.include_android_id,encrypt),c.qimei16,c.qimei36);while(!cookie_value.empty()&&cookie_value.back()==' ')cookie_value.pop_back();
  const auto cecelia=h.signing_script?script::sign(h.signing_script->bytecode,h.signing_script->id,bytes(canonical),h.cecelia_seed):qimei::http::cecelia_default(bytes(canonical),h.cecelia_seed);
  Headers out={{"QDSign",qdsign(sign,encrypt)},{"borgus",qimei::http::sn(bytes(canonical))},{"cecelia",cecelia},{"tstamp",std::to_string(h.timestamp_ms)},{"QDInfo",qdinfo(c,h.timestamp_ms,h.include_android_id,encrypt)},{"User-Agent",user_agent(c,h.brand,h.status_bar_dp)},{"Cookie",cookie_value},{"gorgon",gorgon(h.environment,encrypt)}};
  if(!ibex.empty())out.emplace_back("ibex",ibex);
  return out;
}
Headers registration_headers(const std::string& data,const HeaderContext& h,const Encrypt& encrypt,const std::string& ibex){return request_headers({{"data",data}},h,encrypt,ibex);}
}
