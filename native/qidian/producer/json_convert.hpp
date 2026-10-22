#pragma once
#include "report_state.hpp"
#include "jvm_crypto.hpp"
#include <stdexcept>
namespace cpp_json_detail {
using namespace jvm_crypto;
inline std::string modified(JNIEnv* env,jstring value){const char* raw=env->GetStringUTFChars(value,nullptr);check();std::string out(raw);env->ReleaseStringUTFChars(value,raw);return out;}
inline report_state::Json convert(JNIEnv* env,jobject object) {
  using V=report_state::Json;
  if(object==nullptr)return V();
  const auto obj=env->FindClass("org/json/JSONObject");check();
  const auto arr=env->FindClass("org/json/JSONArray");check();
  if(env->IsInstanceOf(object,obj)) {
    V::Object values;
    const auto keys=env->GetMethodID(obj,"keys","()Ljava/util/Iterator;"),get=env->GetMethodID(obj,"get","(Ljava/lang/String;)Ljava/lang/Object;");check();
    const auto it=env->CallObjectMethod(object,keys);check();
    const auto itcls=env->FindClass("java/util/Iterator");check();
    const auto more=env->GetMethodID(itcls,"hasNext","()Z"),next=env->GetMethodID(itcls,"next","()Ljava/lang/Object;");check();
    while(env->CallBooleanMethod(it,more)) {
      const auto key=static_cast<jstring>(env->CallObjectMethod(it,next));check();
      const auto value=env->CallObjectMethod(object,get,key);check();
      values.emplace(modified(env,key),convert(env,value));
      env->DeleteLocalRef(key);env->DeleteLocalRef(value);
    }
    check();env->DeleteLocalRef(it);env->DeleteLocalRef(itcls);env->DeleteLocalRef(obj);env->DeleteLocalRef(arr);return V(std::move(values));
  }
  if(env->IsInstanceOf(object,arr)) {
    const auto length=env->GetMethodID(arr,"length","()I"),get=env->GetMethodID(arr,"get","(I)Ljava/lang/Object;");check();
    const auto size=env->CallIntMethod(object,length);check();
    V::Array values;
    for(jint i=0;i<size;++i){const auto value=env->CallObjectMethod(object,get,i);check();values.push_back(convert(env,value));env->DeleteLocalRef(value);}
    env->DeleteLocalRef(obj);env->DeleteLocalRef(arr);return V(std::move(values));
  }
  env->DeleteLocalRef(obj);env->DeleteLocalRef(arr);
  const auto cls=env->GetObjectClass(object);
  const auto clsclass=env->FindClass("java/lang/Class");check();
  const auto getname=env->GetMethodID(clsclass,"getName","()Ljava/lang/String;");check();
  const auto name=static_cast<jstring>(env->CallObjectMethod(cls,getname));check();
  const auto kind=modified(env,name);
  env->DeleteLocalRef(clsclass);env->DeleteLocalRef(name);
  V value;
  if(kind=="java.lang.String")value=V(modified(env,static_cast<jstring>(object)));
  else if(kind=="java.lang.Boolean"){const auto method=env->GetMethodID(cls,"booleanValue","()Z");value=V(env->CallBooleanMethod(object,method)==JNI_TRUE);}
  else if(kind=="java.lang.Integer"){const auto method=env->GetMethodID(cls,"intValue","()I");value=V(static_cast<std::int32_t>(env->CallIntMethod(object,method)));}
  else if(kind=="java.lang.Long"){const auto method=env->GetMethodID(cls,"longValue","()J");value=V(static_cast<std::int64_t>(env->CallLongMethod(object,method)));}
  else if(kind=="java.lang.Double"){const auto method=env->GetMethodID(cls,"doubleValue","()D");value=V(env->CallDoubleMethod(object,method));}
  else {
    const auto json=env->FindClass("org/json/JSONObject");check();
    const auto sentinel=env->GetStaticFieldID(json,"NULL","Ljava/lang/Object;");check();
    const auto original=env->GetStaticObjectField(json,sentinel);check();
    if(!env->IsSameObject(object,original))throw std::invalid_argument("Unsupported JSON value class");
    env->DeleteLocalRef(original);env->DeleteLocalRef(json);
  }
  check();env->DeleteLocalRef(cls);return value;
}
}
