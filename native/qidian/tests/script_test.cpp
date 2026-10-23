#include "script_runtime.hpp"
#include "default_signature.hpp"
#include "cipher_vectors.hpp"
extern "C" {
#ifdef _MSC_VER
#pragma warning(push,0)
#endif
#include "quickjs.h"
#ifdef _MSC_VER
#pragma warning(pop)
#endif
}
#include <chrono>
#include <iostream>
#include <stdexcept>
#include <functional>

namespace {
using namespace qimei;
unsigned checks=0;
void check(bool value){if(!value)throw std::runtime_error("Native script regression failed");++checks;}
void rejects(const std::function<void()>& action){bool rejected=false;try{action();}catch(const std::exception&){rejected=true;}check(rejected);}
script::Bytes compile(const std::string& source){
  auto* rt=JS_NewRuntime();auto* ctx=JS_NewContext(rt);
  JS_NewCModule(ctx,"fockrt",[](JSContext*,JSModuleDef*){return 0;});
  JS_NewCModule(ctx,"os",[](JSContext*,JSModuleDef*){return 0;});
  auto value=JS_Eval(ctx,source.data(),source.size(),"unr-script-test.js",JS_EVAL_TYPE_MODULE|JS_EVAL_FLAG_COMPILE_ONLY);
  if(JS_IsException(value)){auto e=JS_GetException(ctx);auto* text=JS_ToCString(ctx,e);if(text){std::cerr<<text<<'\n';JS_FreeCString(ctx,text);}JS_FreeValue(ctx,e);}
  check(!JS_IsException(value));std::size_t size=0;auto* p=JS_WriteObject(ctx,&size,value,JS_WRITE_OBJ_BYTECODE);check(p&&size);
  script::Bytes out(p,p+size);js_free(ctx,p);JS_FreeValue(ctx,value);JS_FreeContext(ctx);JS_FreeRuntime(rt);return out;
}
void number(script::Bytes& value,unsigned n){value.push_back(std::uint8_t(n));value.push_back(std::uint8_t(n>>8));}
script::Bytes envelope(const script::Bytes& final,bool prefix){
  const script::Bytes key(32,71);
  const auto header_script=compile("import * as f from 'fockrt';globalThis._res_=f.i_0x8756("+std::string("\"")+script::base91_encode(key)+"\");");
  // JSON quote Base91's double quote and backslash characters.
  const auto quote=[](const std::string& text){std::string out="\"";for(char c:text){if(c=='"'||c=='\\')out+='\\';out+=c;}return out+'"';};
  const auto payload_script=compile("import * as f from 'fockrt';globalThis._res_=f.i_0x8756("+quote(script::base91_encode(final))+");");
  const auto encrypted=script::cipher(script::crc8(script::Bytes{'s','n'})%6,true,payload_script,key);
  script::Bytes header;number(header,unsigned(header_script.size()));header.insert(header.end(),header_script.begin(),header_script.end());
  const auto digest=http::digest(http::DigestKind::md5,final);header.insert(header.end(),digest.begin(),digest.end());
  if(prefix){check(encrypted.size()>64);header.insert(header.end(),encrypted.begin(),encrypted.begin()+64);}
  else header.insert(header.end(),64,0);
  const std::string material=std::string("sn")+script::app_key;const auto sha=http::sha256(script::Bytes(material.begin(),material.end()));script::Bytes header_key(sha.begin(),sha.end());
  const auto sealed=script::cipher(script::crc16(header_key)%6,true,header,header_key);
  script::Bytes out{0x46,0,0x63,0x4b};number(out,unsigned(sealed.size()));out.insert(out.end(),sealed.begin(),sealed.end());out.insert(out.end(),encrypted.begin()+(prefix?64:0),encrypted.end());return out;
}
unsigned run(){
  checks=0;check(script::api_signature(script::Bytes{'a','b','c'})=="d1e1b12f41d72c21df08a2562de3fa6e");
  check(script::crc16(script::Bytes{'a','b','c'})==0x9738);check(script::crc8(script::Bytes{'s','n'})==0xb2);
  for(const auto& vector:cipher_vectors){
    script::Bytes key(32),plain(17),encrypted;
    for(unsigned i=0;i<32;++i)key[i]=std::uint8_t(i+32);
    for(unsigned i=0;i<17;++i)plain[i]=std::uint8_t(i*7+1);
    for(const char* p=vector.encrypted;*p;p+=2){const auto digit=[](char c){return c<='9'?c-'0':c-'a'+10;};encrypted.push_back(std::uint8_t(digit(p[0])*16+digit(p[1])));}
    check(script::cipher(vector.kind,false,encrypted,key,vector.cbc)==plain);
    check(script::cipher(vector.kind,true,plain,key,vector.cbc)==encrypted);
  }
  for(unsigned n=0;n<1024;n+=17){script::Bytes v;for(unsigned i=0;i<n;++i)v.push_back(std::uint8_t(i));check(script::base91_decode(script::base91_encode(v))==v);}
  const auto code=compile("import * as f from 'fockrt';function sign(s){const b=f.i_0x8756(s);const a=new Uint8Array(b);if(a.length>2){a[0]=6;a[1]=66;}return f.i_0x5353(b);}globalThis._res_=sign('placeholder0');");
  for(auto size:{1,55,64,9994,10000,10010})for(auto seed:{0,1,32768,65535}){
    const script::Bytes value(std::size_t(size),'x');auto expected=http::cecelia_default(value,std::uint16_t(seed));expected.replace(0,1,"27");check(script::sign(code,27,value,std::uint16_t(seed))==expected);
  }
  for(bool prefix:{false,true}){
    auto wrapped=envelope(code,prefix);check(script::decode(wrapped)==code);
    for(std::size_t n=0;n<wrapped.size();n+=19)rejects([&]{script::decode(script::Bytes(wrapped.begin(),wrapped.begin()+n));});
    wrapped.back()^=1;rejects([&]{script::decode(wrapped);});
  }
  for(std::size_t n=1;n<code.size();++n)rejects([&]{script::evaluate(script::Bytes(code.begin(),code.begin()+n));});
  const auto loop=compile("while(true){}");const auto start=std::chrono::steady_clock::now();rejects([&]{script::evaluate(loop);});check(std::chrono::steady_clock::now()-start<std::chrono::seconds(3));
  const auto external=compile("import * as fs from 'os';globalThis._res_=fs;");rejects([&]{script::evaluate(external);});
  const auto blocking=compile("Atomics.wait(new Int32Array(new SharedArrayBuffer(4)),0,0);");rejects([&]{script::evaluate(blocking);});
  rejects([&]{script::authorization("invalid","1700000000");});
  const auto authorization=script::authorization("00000000-0000-4000-8000-000000000001","1700000000");check(authorization.size()==5&&authorization.count("Cookie")==0);
  return checks;
}
}
#ifdef __ANDROID__
#include <jni.h>
extern "C" JNIEXPORT jint JNICALL Java_org_unr_research_scripts_ScriptProbe_runNative(JNIEnv* env,jclass){try{return jint(run());}catch(...){env->ThrowNew(env->FindClass("java/lang/IllegalStateException"),"Native script regression failed");return 0;}}
#else
int main(){try{std::cout<<"checks="<<run()<<" passed\n";return 0;}catch(const std::exception& e){std::cerr<<e.what()<<" after "<<checks<<" checks\n";return 1;}}
#endif
