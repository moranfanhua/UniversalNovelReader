#include "script_runtime.hpp"
#include "default_signature.hpp"
extern "C" {
#ifdef _MSC_VER
#pragma warning(push, 0)
#endif
#include "quickjs.h"
#ifdef _MSC_VER
#pragma warning(pop)
#endif
}
#include <algorithm>
#include <chrono>
#include <cstring>
#include <stdexcept>

namespace qimei::script {
namespace {
void require(bool value){if(!value)throw std::runtime_error("FockRT script unavailable or invalid");}
Bytes buffer(JSContext* c,JSValueConst value){size_t n=0;auto* p=JS_GetArrayBuffer(c,&n,value);if(!p||n>1024*1024)throw std::runtime_error("FockRT output is not a byte buffer");return {p,p+n};}
std::string string(JSContext* c,JSValueConst value){size_t n=0;const char* p=JS_ToCStringLen(c,&n,value);require(p&&n<=2*1024*1024);std::string out(p,n);JS_FreeCString(c,p);return out;}
JSValue intrinsic(JSContext* c,JSValueConst,int argc,JSValueConst* args,int which){
  try{
    require(argc>0);Bytes out;
    if(which==12){const auto value=base91_encode(buffer(c,args[0]));return JS_NewStringLen(c,value.data(),value.size());}
    if(which==13)out=base91_decode(string(c,args[0]));
    else if(which<12){require(argc>1);const auto material=string(c,args[1]);out=cipher(unsigned(which/2),false,buffer(c,args[0]),Bytes(material.begin(),material.end()),which%2!=0);}
    else if(which==17){const auto digest=http::sha256(buffer(c,args[0]));out.assign(digest.begin(),digest.end());}
    else{const auto digest=http::digest(which==14?http::DigestKind::md2:which==15?http::DigestKind::md4:http::DigestKind::md5,buffer(c,args[0]));out.assign(digest.begin(),digest.end());}
    return JS_NewArrayBufferCopy(c,out.data(),out.size());
  }catch(...){return JS_ThrowTypeError(c,"Unsupported FockRT input");}
}
constexpr const char* names[]={"i_0x0845","i_0x9764","i_0x6945","i_0x5645","i_0x6547","i_0x6545","i_0x7574","i_0x2437","i_0x2537","i_0x9794","i_0x8544","i_0x8865","i_0x4636","i_0x8756","i_0x3145","i_0x5464","i_0x9565","i_0x5353"};
int module_init(JSContext* c,JSModuleDef* m){for(int i=0;i<18;++i)if(JS_SetModuleExport(c,m,names[i],JS_NewCFunctionMagic(c,intrinsic,names[i],i<12?2:1,JS_CFUNC_generic_magic,i))<0)return -1;return 0;}
struct Engine {
  JSRuntime* runtime=JS_NewRuntime();JSContext* context=nullptr;
  std::chrono::steady_clock::time_point deadline=std::chrono::steady_clock::now()+std::chrono::milliseconds(250);
  Engine(){require(runtime);JS_SetMemoryLimit(runtime,16*1024*1024);JS_SetMaxStackSize(runtime,256*1024);JS_SetInterruptHandler(runtime,[](JSRuntime*,void* opaque){return std::chrono::steady_clock::now()>static_cast<Engine*>(opaque)->deadline?1:0;},this);context=JS_NewContext(runtime);if(!context){JS_FreeRuntime(runtime);runtime=nullptr;throw std::runtime_error("FockRT runtime unavailable");}}
  ~Engine(){if(context)JS_FreeContext(context);if(runtime)JS_FreeRuntime(runtime);}
};
struct Value {JSContext* context;JSValue value;~Value(){JS_FreeValue(context,value);}};
unsigned short_value(const Bytes& bytes,std::size_t offset){require(offset+2<=bytes.size());return unsigned(bytes[offset])|(unsigned(bytes[offset+1])<<8);}
Bytes substitute(const Bytes& input,const std::string& text){
  if(text.empty())return input;
  std::size_t offset=1;
  const auto number=[&](){unsigned value=0;for(unsigned shift=0;shift<35;shift+=7){require(offset<input.size());const auto ch=input[offset++];value|=unsigned(ch&127)<<shift;if(ch<128)return value;}throw std::runtime_error("FockRT atom table invalid");};
  const auto count=number();require(count<=16384);Bytes out(input.begin(),input.begin()+offset);
  const auto append=[&](unsigned value){do{auto byte=std::uint8_t(value&127);value>>=7;out.push_back(std::uint8_t(byte|(value?128:0)));}while(value);};
  for(unsigned i=0;i<count;++i){const auto length=number();const auto n=std::size_t(length>>1)*(length&1?2:1);require(n<=input.size()-offset);
    if(!(length&1)&&std::string(input.begin()+offset,input.begin()+offset+n)=="placeholder0"){append(unsigned(text.size()*2));out.insert(out.end(),text.begin(),text.end());}
    else{append(length);out.insert(out.end(),input.begin()+offset,input.begin()+offset+n);}offset+=n;
  }
  out.insert(out.end(),input.begin()+offset,input.end());return out;
}
}
Bytes evaluate(const Bytes& bytecode,const std::string& placeholder){
  require(!bytecode.empty()&&bytecode.size()<=1024*1024&&bytecode.front()==1);
  Engine engine;auto* c=engine.context;auto* m=JS_NewCModule(c,"fockrt",module_init);require(m);for(const auto* name:names)require(JS_AddModuleExport(c,m,name)==0);
  Value global{c,JS_GetGlobalObject(c)};require(JS_SetPropertyStr(c,global.value,"placeholder0",JS_NewStringLen(c,placeholder.data(),placeholder.size()))==1);
  // Keep SDK atom numbering, while exposing no blocking host primitives.
  require(JS_SetPropertyStr(c,global.value,"Atomics",JS_UNDEFINED)==1);
  require(JS_SetPropertyStr(c,global.value,"SharedArrayBuffer",JS_UNDEFINED)==1);
  const auto replaced=substitute(bytecode,placeholder);
  auto code=JS_ReadObject(c,replaced.data(),replaced.size(),JS_READ_OBJ_BYTECODE);
  if(JS_IsException(code))throw std::runtime_error("FockRT bytecode incompatible");
  if(JS_ResolveModule(c,code)<0){JS_FreeValue(c,code);throw std::runtime_error("FockRT module unsupported");}
  Value result{c,JS_EvalFunction(c,code)};
  if(JS_IsException(result.value))throw std::runtime_error("FockRT script evaluation failed");
  Value output{c,JS_GetPropertyStr(c,global.value,"_res_")};return buffer(c,output.value);
}
Bytes decode(const Bytes& envelope){
  require(envelope.size()>6&&envelope.size()<=1024*1024&&envelope[0]==0x46&&envelope[1]==0&&envelope[2]==0x63&&envelope[3]==0x4b);
  const auto length=short_value(envelope,4);require(length>0&&length<envelope.size()-6);
  const std::string key_text=std::string("sn")+app_key;const auto sha=http::sha256(Bytes(key_text.begin(),key_text.end()));const Bytes header_key(sha.begin(),sha.end());
  const auto header=cipher(crc16(header_key)%6,false,Bytes(envelope.begin()+6,envelope.begin()+6+length),header_key);
  const auto code_size=short_value(header,0);require(code_size>0&&std::size_t(code_size)+82==header.size());
  const auto key=evaluate(Bytes(header.begin()+2,header.begin()+2+code_size));require(key.size()==32);
  const Bytes expected(header.begin()+2+code_size,header.begin()+18+code_size);
  Bytes payload(header.begin()+18+code_size,header.end());
  if(std::all_of(payload.begin(),payload.end(),[](auto byte){return byte==0;}))payload.clear();
  payload.insert(payload.end(),envelope.begin()+6+length,envelope.end());
  const auto plain=cipher(crc8(Bytes{'s','n'})%6,false,payload,key);
  auto decoded=evaluate(plain);const auto digest=http::digest(http::DigestKind::md5,decoded);if(!std::equal(digest.begin(),digest.end(),expected.begin()))throw std::runtime_error("FockRT script integrity check failed");
  require(!decoded.empty()&&decoded.front()==1);return decoded;
}
std::string sign(const Bytes& bytecode,std::uint64_t id,const Bytes& canonical,std::uint16_t seed){
  require(id>0);if(canonical.empty()||canonical.front()==0)return {};
  const auto prefix=std::to_string(seed);Bytes value(prefix.begin(),prefix.end());value.insert(value.end(),canonical.begin(),canonical.begin()+std::min(canonical.size(),10000-value.size()));
  const auto digest=evaluate(bytecode,base91_encode(value));require(!digest.empty()&&digest.size()<=120);
  constexpr char symbols[]="0123456789abcdef";std::string out=std::to_string(id)+'_';
  for(auto byte:{std::uint8_t(seed),std::uint8_t(seed>>8)}){out+=symbols[byte>>4];out+=symbols[byte&15];}
  for(auto byte:digest){out+=symbols[byte>>4];out+=symbols[byte&15];}require(out.size()<256);return out;
}
std::map<std::string,std::string> authorization(const std::string& uid,const std::string& timestamp){
  require(uid.size()==36&&std::all_of(uid.begin(),uid.end(),[](char c){return (c>='0'&&c<='9')||(c>='a'&&c<='f')||c=='-';}));
  require(timestamp.size()>=10&&timestamp.size()<=11&&std::all_of(timestamp.begin(),timestamp.end(),[](char c){return c>='0'&&c<='9';}));
  const auto text=uid+app_key+timestamp;
  return {{"App-Key",app_key},{"Uid",uid},{"Timestamp",timestamp},{"Sign",api_signature(Bytes(text.begin(),text.end()))},{"Bundle-ID","com.qidian.QDReader"}};
}
}
