#include "client.hpp"
#include "snapshot_json.hpp"
#include "selected_protocol.hpp"
#include "qimei_profile.hpp"
#include "qimei_json.hpp"
#include "qimei_file_store.hpp"
#include "crypto_jce.hpp"
#include "collector.hpp"
#include "jvm_crypto.hpp"
#include <jni.h>
#include <chrono>
#include <filesystem>
#include <limits>
#include <map>
#include <mutex>
#include <stdexcept>
#include <sys/system_properties.h>

namespace {
using namespace qimei;
using namespace qimei::client;
void verify(JNIEnv* env){if(env->ExceptionCheck()){env->ExceptionClear();throw std::runtime_error("Client platform operation failed");}}
std::string string(JNIEnv* env,jstring value){if(!value)throw std::invalid_argument("Client text missing");jvm_crypto::bind(env);const auto raw=jvm_crypto::utf8(value);return {raw.begin(),raw.end()};}
jstring java(JNIEnv* env,const std::string& value){jvm_crypto::bind(env);return jvm_crypto::from_utf8(bytes(value));}
std::uint64_t now(){return std::uint64_t(std::chrono::duration_cast<std::chrono::milliseconds>(std::chrono::system_clock::now().time_since_epoch()).count());}
struct Frame {JNIEnv* env;bool active=true;explicit Frame(JNIEnv* value):env(value){jvm_crypto::bind(env);if(env->PushLocalFrame(8192)<0){env->ExceptionClear();throw std::runtime_error("Client local frame unavailable");}}~Frame(){if(active)env->PopLocalFrame(nullptr);}jobject pop(jobject value){active=false;return env->PopLocalFrame(value);}};
struct Thread {
  JavaVM* vm;JNIEnv* env=nullptr;bool attached=false;
  explicit Thread(JavaVM* value):vm(value){const auto status=vm->GetEnv(reinterpret_cast<void**>(&env),JNI_VERSION_1_6);if(status==JNI_EDETACHED){if(vm->AttachCurrentThread(&env,nullptr)!=JNI_OK)throw std::runtime_error("Client Java thread unavailable");attached=true;}else if(status!=JNI_OK)throw std::runtime_error("Client Java runtime unavailable");jvm_crypto::bind(env);}
  ~Thread(){if(attached)vm->DetachCurrentThread();}
};
struct Callbacks {
  JavaVM* vm=nullptr;jobject owner=nullptr;jclass helper=nullptr;jmethodID collect=nullptr,exchange=nullptr,cancel=nullptr,encrypt=nullptr;
  Callbacks(JNIEnv* env,jobject value){
    try{
    env->GetJavaVM(&vm);owner=env->NewGlobalRef(value);auto cls=env->GetObjectClass(value);verify(env);
    collect=env->GetMethodID(cls,"collectSnapshot","(Ljava/lang/String;Ljava/lang/String;)Ljava/lang/String;");exchange=env->GetMethodID(cls,"exchange","(Ljava/lang/String;[Ljava/lang/String;[Ljava/lang/String;)Ljava/lang/String;");cancel=env->GetMethodID(cls,"cancelTransport","()V");verify(env);env->DeleteLocalRef(cls);
    auto crypto=env->FindClass("org/unr/research/qimeiclient/SystemCrypto");verify(env);helper=static_cast<jclass>(env->NewGlobalRef(crypto));env->DeleteLocalRef(crypto);verify(env);encrypt=env->GetStaticMethodID(helper,"encrypt","(I[B[B[B)[B");verify(env);qimei::crypto::bind(env,helper);
    }catch(...){if(owner)env->DeleteGlobalRef(owner);if(helper)env->DeleteGlobalRef(helper);owner=nullptr;helper=nullptr;throw;}
  }
  ~Callbacks(){try{Thread thread(vm);if(owner)thread.env->DeleteGlobalRef(owner);if(helper)thread.env->DeleteGlobalRef(helper);}catch(...){} }
  Snapshot snapshot(const Identifiers& ids){Thread thread(vm);Frame frame(thread.env);auto* env=thread.env;auto value=static_cast<jstring>(env->CallObjectMethod(owner,collect,java(env,std::string(ids.qimei.begin(),ids.qimei.end())),java(env,std::string(ids.qimei36.begin(),ids.qimei36.end()))));verify(env);return snapshot_from_json(string(env,value));}
  app::Bytes cipher(app::Cipher kind,const app::Bytes& plain,const app::Bytes& key,const app::Bytes& iv){Thread thread(vm);Frame frame(thread.env);auto* env=thread.env;auto result=static_cast<jbyteArray>(env->CallStaticObjectMethod(helper,encrypt,jint(kind==app::Cipher::aes256_cbc?2:kind==app::Cipher::des3_cbc?1:0),jvm_crypto::byte_array(plain),jvm_crypto::byte_array(key),jvm_crypto::byte_array(iv)));verify(env);return jvm_crypto::bytes(result);}
  AppReply send(const SignedRequest& request){
    Thread thread(vm);Frame frame(thread.env);auto* env=thread.env;auto cls=env->FindClass("java/lang/String");verify(env);auto names=env->NewObjectArray(jsize(request.headers.size()),cls,nullptr),values=env->NewObjectArray(jsize(request.headers.size()),cls,nullptr);verify(env);
    for(std::size_t i=0;i<request.headers.size();++i){env->SetObjectArrayElement(names,jsize(i),java(env,request.headers[i].first));env->SetObjectArrayElement(values,jsize(i),java(env,request.headers[i].second));verify(env);}
    auto raw=static_cast<jstring>(env->CallObjectMethod(owner,exchange,java(env,request.form_body),names,values));verify(env);const auto reply=Json::parse(string(env,raw));const auto* status=reply.find("httpStatus");const auto* body=reply.find("body");if(!status||status->kind!=Json::Kind::number||!body||body->kind!=Json::Kind::string||body->text.size()>1024*1024)throw std::runtime_error("Client HTTP response invalid");return {int(status->integer()),body->text};
  }
  void stop(){Thread thread(vm);Frame frame(thread.env);thread.env->CallVoidMethod(owner,cancel);verify(thread.env);}
};
struct State {std::shared_ptr<Callbacks> callbacks;std::unique_ptr<Client> client;ibex_producer::Producer producer;};
std::mutex registry_mutex;std::map<jlong,std::shared_ptr<State>> registry;std::uint64_t next_handle=1;
std::shared_ptr<State> get(jlong handle){std::lock_guard<std::mutex> guard(registry_mutex);const auto found=registry.find(handle);if(found==registry.end())throw std::runtime_error("Client closed");return found->second;}
void failure(JNIEnv* env){if(env->ExceptionCheck())env->ExceptionClear();env->ThrowNew(env->FindClass("java/lang/IllegalStateException"),"Independent QIMEI client operation failed");}
}
extern "C" JNIEXPORT jstring JNICALL Java_org_unr_research_qimeiclient_NativeClient_profile(JNIEnv* env,jclass){return env->NewStringUTF(qimei::client::selected_protocol_json);}
extern "C" JNIEXPORT jlong JNICALL Java_org_unr_research_qimeiclient_NativeClient_create(JNIEnv* env,jclass,jobject owner,jstring path,jstring profile,jboolean consent){
  try{if(!consent||!owner)throw std::invalid_argument("Client requires privacy consent");Frame frame(env);auto state=std::make_shared<State>();state->callbacks=std::make_shared<Callbacks>(env,owner);auto callbacks=state->callbacks;auto store=std::make_shared<FileStateStore>(std::filesystem::u8path(string(env,path)));
    state->client=std::make_unique<Client>(decode_profile(string(env,profile)),bytes("0I000JZU8B16UN21"),store,[callbacks](const auto& ids){return callbacks->snapshot(ids);},[callbacks](auto kind,const auto& plain,const auto& key,const auto& iv){return callbacks->cipher(kind,plain,key,iv);},[](ibex::Report& report,std::int64_t stamp){return ibex::generate(report,stamp);},[callbacks](const auto& request){return callbacks->send(request);},[callbacks]{callbacks->stop();},now);
    std::lock_guard<std::mutex> guard(registry_mutex);if(next_handle>std::uint64_t(std::numeric_limits<jlong>::max()))throw std::overflow_error("Client handle limit");const auto handle=jlong(next_handle++);registry.emplace(handle,std::move(state));return handle;
  }catch(...){failure(env);return 0;}
}
extern "C" JNIEXPORT jstring JNICALL Java_org_unr_research_qimeiclient_NativeClient_ensure(JNIEnv* env,jclass,jlong handle,jboolean consent,jboolean force){
  try{Frame frame(env);const auto state=get(handle);const auto result=state->client->ensure(consent,force);const auto encoded=Json::object({{"status",Json::number(int(result.provider.status))},{"ready",Json::parse(result.ready()?"true":"false")},{"pairComplete",Json::parse(result.pair_complete()?"true":"false")},{"fromCache",Json::parse(result.from_cache?"true":"false")},{"serviceCode",Json::number(result.provider.service_code)},{"nativeError",Json::number(result.provider.native_error)},{"qimei",Json::string(std::string(result.provider.identifiers.qimei.begin(),result.provider.identifiers.qimei.end()))},{"qimei36",Json::string(std::string(result.provider.identifiers.qimei36.begin(),result.provider.identifiers.qimei36.end()))},{"ibex",Json::string(result.ibex)}}).encode();return static_cast<jstring>(frame.pop(java(env,encoded)));}catch(...){failure(env);return nullptr;}
}
extern "C" JNIEXPORT jstring JNICALL Java_org_unr_research_qimeiclient_NativeClient_headers(JNIEnv* env,jclass,jlong handle,jstring parameters,jstring account){
  try{Frame frame(env);jvm_crypto::bind(env);const auto input=Json::parse(string(env,parameters)),session=Json::parse(string(env,account));if(input.kind!=Json::Kind::object||session.kind!=Json::Kind::object)throw std::invalid_argument("Client parameters invalid");std::map<std::string,std::string> fields;
    for(const auto& [name,value]:input.members){if(value.kind!=Json::Kind::string)throw std::invalid_argument("Client parameter type invalid");fields.emplace(name,value.text);}
    const auto field=[&](const char* name,const char* fallback=""){const auto* value=session.find(name);if(!value)return std::string(fallback);if(value->kind!=Json::Kind::string)throw std::invalid_argument("Client session invalid");return value->text;};
    app::CookieContext cookies;cookies.token=field("token");cookies.yw_key=field("ywKey");cookies.yw_guid=field("ywGuid");std::map<std::string,Json> headers;for(const auto& [name,value]:get(handle)->client->prepare(fields,cookies,field("userId","0")))headers.emplace(name,Json::string(value));return static_cast<jstring>(frame.pop(java(env,Json::object(std::move(headers)).encode())));
  }catch(...){failure(env);return nullptr;}
}
extern "C" JNIEXPORT jboolean JNICALL Java_org_unr_research_qimeiclient_NativeClient_pause(JNIEnv* env,jclass,jlong handle){try{return get(handle)->client->note_risk().status==ProviderStatus::cooldown;}catch(...){failure(env);return JNI_FALSE;}}
extern "C" JNIEXPORT void JNICALL Java_org_unr_research_qimeiclient_NativeClient_close(JNIEnv* env,jclass,jlong handle){
  try{std::shared_ptr<State> state;{std::lock_guard<std::mutex> guard(registry_mutex);const auto found=registry.find(handle);if(found==registry.end())return;state=found->second;registry.erase(found);}state->client->close();}catch(...){failure(env);}
}
extern "C" JNIEXPORT jobject JNICALL Java_org_unr_research_qimeiclient_NativeClient_collectReport(JNIEnv* env,jclass,jlong handle,jobject context,jobject inputs,jobject options){
  try{if(!context||!inputs||!options)throw std::invalid_argument("Client collection arguments missing");Frame frame(env);return frame.pop(get(handle)->producer.collect_required(env,context,inputs,options));}catch(...){failure(env);return nullptr;}
}
extern "C" JNIEXPORT jstring JNICALL Java_org_unr_research_qimeiclient_NativeClient_property(JNIEnv* env,jclass,jstring name){try{const auto value=string(env,name);if(value!="sys.tencent.init")throw std::invalid_argument("Client property outside scope");char buffer[PROP_VALUE_MAX]{};const auto length=__system_property_get(value.c_str(),buffer);return java(env,length>0?std::string(buffer,std::size_t(length)):std::string());}catch(...){failure(env);return nullptr;}}
extern "C" JNIEXPORT void JNICALL Java_org_unr_research_qimeiportable_AndroidSnapshot_initialize(JNIEnv*,jclass,jclass);
extern "C" JNIEXPORT jstring JNICALL Java_org_unr_research_qimeiportable_AndroidSnapshot_nativePlatform(JNIEnv*,jclass);
extern "C" JNIEXPORT jstring JNICALL Java_org_unr_research_qimeiportable_AndroidSnapshot_encodeDeviceValue(JNIEnv*,jclass,jstring,jstring);
extern "C" JNIEXPORT void JNICALL Java_org_unr_research_qimeiclient_AndroidSnapshot_initialize(JNIEnv* e,jclass c,jclass h){Java_org_unr_research_qimeiportable_AndroidSnapshot_initialize(e,c,h);}
extern "C" JNIEXPORT jstring JNICALL Java_org_unr_research_qimeiclient_AndroidSnapshot_nativePlatform(JNIEnv* e,jclass c){return Java_org_unr_research_qimeiportable_AndroidSnapshot_nativePlatform(e,c);}
extern "C" JNIEXPORT jstring JNICALL Java_org_unr_research_qimeiclient_AndroidSnapshot_encodeDeviceValue(JNIEnv* e,jclass c,jstring p,jstring i){return Java_org_unr_research_qimeiportable_AndroidSnapshot_encodeDeviceValue(e,c,p,i);}
