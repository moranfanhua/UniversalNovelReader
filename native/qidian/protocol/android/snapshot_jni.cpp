#include "crypto_jce.hpp"
#include "qimei_json.hpp"
#include "qimei_profile.hpp"
#include <jni.h>
#include <cstdio>
#include <stdexcept>
#include <sys/system_properties.h>
#include <sys/utsname.h>

namespace {
void failure(JNIEnv* env){if(env->ExceptionCheck())env->ExceptionClear();env->ThrowNew(env->FindClass("java/lang/IllegalStateException"),"QIMEI device snapshot operation failed");}
std::string text(JNIEnv* env,jstring value){if(!value)throw std::runtime_error("QIMEI snapshot input unavailable");const char* raw=env->GetStringUTFChars(value,nullptr);if(!raw)throw std::runtime_error("QIMEI snapshot allocation failed");std::string out(raw,std::size_t(env->GetStringUTFLength(value)));env->ReleaseStringUTFChars(value,raw);return out;}
}
extern "C" JNIEXPORT void JNICALL Java_org_unr_research_qimeiportable_AndroidSnapshot_initialize(JNIEnv* env,jclass,jclass crypto){try{qimei::crypto::bind(env,crypto);}catch(const std::exception&){failure(env);}}
extern "C" JNIEXPORT jstring JNICALL Java_org_unr_research_qimeiportable_AndroidSnapshot_encodeDeviceValue(JNIEnv* env,jclass,jstring profile,jstring input){
  try{const auto encoded=qimei::encode_device_value(qimei::bytes(text(env,input)),qimei::decode_profile(text(env,profile)));return env->NewStringUTF(encoded.c_str());}catch(const std::exception&){failure(env);return nullptr;}
}
extern "C" JNIEXPORT jstring JNICALL Java_org_unr_research_qimeiportable_AndroidSnapshot_nativePlatform(JNIEnv* env,jclass){
  try{
    std::map<std::string,qimei::Json> values;
    for(const auto& item:std::map<std::string,std::string>{{"bod","ro.product.board"},{"brd","ro.product.brand"},{"dv","ro.product.device"},{"firstLevel","ro.product.first_api_level"},{"manufact","ro.product.manufacturer"},{"name","ro.product.name"},{"host","ro.build.host"},{"model","ro.product.model"}}){char buffer[PROP_VALUE_MAX]{};const int length=__system_property_get(item.second.c_str(),buffer);values[item.first]=qimei::Json::string(length>0?std::string(buffer,std::size_t(length)):std::string());}
    utsname system{};char kernel[325]{};if(::uname(&system)==0)std::snprintf(kernel,sizeof(kernel),"%s %s %s %s %s",system.sysname,system.nodename,system.release,system.version,system.machine);
    values["kernel"]=qimei::Json::string(kernel);const auto encoded=qimei::Json::object(std::move(values)).encode();return env->NewStringUTF(encoded.c_str());
  }catch(const std::exception&){failure(env);return nullptr;}
}
