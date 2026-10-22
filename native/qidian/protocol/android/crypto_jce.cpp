#include "crypto_jce.hpp"
#include "qimei_crypto.hpp"
#include <algorithm>
#include <limits>
#include <mutex>
#include <stdexcept>

namespace qimei::crypto {
namespace {
JavaVM* vm=nullptr;jclass helper=nullptr;std::mutex initialization;
jmethodID digest_method=nullptr,cbc_method=nullptr,rsa_method=nullptr,random_method=nullptr;
void verify(JNIEnv* env){if(env->ExceptionCheck()){env->ExceptionClear();throw std::runtime_error("QIMEI system cryptography failed");}}
struct Frame {
  JNIEnv* env=nullptr;bool attached=false,framed=false;
  Frame(){
    {std::lock_guard<std::mutex> lock(initialization);if(!vm||!helper)throw std::runtime_error("QIMEI Android crypto is not initialized");}
    const auto status=vm->GetEnv(reinterpret_cast<void**>(&env),JNI_VERSION_1_6);
    if(status==JNI_EDETACHED){if(vm->AttachCurrentThread(&env,nullptr)!=JNI_OK)throw std::runtime_error("QIMEI Android crypto thread unavailable");attached=true;}
    else if(status!=JNI_OK)throw std::runtime_error("QIMEI Android crypto environment unavailable");
    if(env->PushLocalFrame(32)<0){env->ExceptionClear();if(attached)vm->DetachCurrentThread();throw std::runtime_error("QIMEI Android crypto allocation failed");}framed=true;
  }
  ~Frame(){if(framed)env->PopLocalFrame(nullptr);if(attached)vm->DetachCurrentThread();}
  jbyteArray array(const std::uint8_t* input,std::size_t size){if(size>std::size_t(std::numeric_limits<jsize>::max()))throw std::runtime_error("QIMEI crypto input too large");auto out=env->NewByteArray(jsize(size));verify(env);if(size)env->SetByteArrayRegion(out,0,jsize(size),reinterpret_cast<const jbyte*>(input));verify(env);return out;}
  jbyteArray array(const Bytes& input){return array(input.data(),input.size());}
  Bytes result(jobject object){verify(env);if(!object)throw std::runtime_error("QIMEI system cryptography returned no result");auto value=static_cast<jbyteArray>(object);const auto size=env->GetArrayLength(value);verify(env);Bytes out(std::size_t(size),0);if(size)env->GetByteArrayRegion(value,0,size,reinterpret_cast<jbyte*>(out.data()));verify(env);return out;}
};
}
void bind(JNIEnv* env,jclass value){
  std::lock_guard<std::mutex> lock(initialization);if(helper)return;
  JavaVM* local_vm=nullptr;if(env->GetJavaVM(&local_vm)!=JNI_OK)throw std::runtime_error("QIMEI Android VM unavailable");
  const auto digest_id=env->GetStaticMethodID(value,"digest","(I[B)[B");verify(env);
  const auto cbc_id=env->GetStaticMethodID(value,"cbc","(Z[B[B[B)[B");verify(env);
  const auto rsa_id=env->GetStaticMethodID(value,"rsa","([B[B)[B");verify(env);
  const auto random_id=env->GetStaticMethodID(value,"random","(I)[B");verify(env);
  auto reference=static_cast<jclass>(env->NewGlobalRef(value));verify(env);if(!reference)throw std::runtime_error("QIMEI Android crypto class unavailable");
  digest_method=digest_id;cbc_method=cbc_id;rsa_method=rsa_id;random_method=random_id;vm=local_vm;helper=reference;
}
Bytes digest(const Bytes& input,Hash method){Frame frame;return frame.result(frame.env->CallStaticObjectMethod(helper,digest_method,jint(method==Hash::md5?0:1),frame.array(input)));}
Bytes cbc(const Bytes& input,const Block& key,const Block& iv,bool encrypt){Frame frame;return frame.result(frame.env->CallStaticObjectMethod(helper,cbc_method,jboolean(encrypt),frame.array(input),frame.array(key.data(),key.size()),frame.array(iv.data(),iv.size())));}
Bytes rsa(const Bytes& input,const Bytes& der){Frame frame;return frame.result(frame.env->CallStaticObjectMethod(helper,rsa_method,frame.array(input),frame.array(der)));}
void random(std::uint8_t* output,std::size_t length){if(length>std::size_t(std::numeric_limits<jint>::max()))throw std::runtime_error("QIMEI random length too large");Frame frame;const auto generated=frame.result(frame.env->CallStaticObjectMethod(helper,random_method,jint(length)));if(generated.size()!=length)throw std::runtime_error("QIMEI system entropy failed");std::copy(generated.begin(),generated.end(),output);}
}
