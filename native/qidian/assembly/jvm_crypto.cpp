#include "jvm_crypto.hpp"
#include <algorithm>
#include <stdexcept>

namespace jvm_crypto {
namespace { thread_local JNIEnv* vm=nullptr; }
void bind(JNIEnv* env){vm=env;}
void check(){if(vm->ExceptionCheck()){vm->ExceptionClear();throw std::runtime_error("Framework operation failed");}}
Bytes bytes(jbyteArray value) {
  if(value==nullptr)throw std::invalid_argument("Null byte array");
  Bytes result(static_cast<std::size_t>(vm->GetArrayLength(value)));
  vm->GetByteArrayRegion(value,0,static_cast<jsize>(result.size()),reinterpret_cast<jbyte*>(result.data()));check();return result;
}
jbyteArray byte_array(const Bytes& value) {
  const auto result=vm->NewByteArray(static_cast<jsize>(value.size()));check();
  vm->SetByteArrayRegion(result,0,static_cast<jsize>(value.size()),reinterpret_cast<const jbyte*>(value.data()));check();return result;
}
jstring java_string(const std::u16string& value){return vm->NewString(reinterpret_cast<const jchar*>(value.data()),static_cast<jsize>(value.size()));}
std::u16string utf16(jstring value) {
  if(value==nullptr)throw std::invalid_argument("Null text");
  const auto length=vm->GetStringLength(value);
  const auto raw=vm->GetStringChars(value,nullptr);check();
  std::u16string result(reinterpret_cast<const char16_t*>(raw),static_cast<std::size_t>(length));vm->ReleaseStringChars(value,raw);return result;
}
Bytes utf8(jstring value) {
  const auto cls=vm->FindClass("java/lang/String");check();
  const auto method=vm->GetMethodID(cls,"getBytes","(Ljava/lang/String;)[B");check();
  const auto charset=vm->NewStringUTF("UTF-8");
  const auto output=static_cast<jbyteArray>(vm->CallObjectMethod(value,method,charset));check();
  auto result=bytes(output);vm->DeleteLocalRef(cls);vm->DeleteLocalRef(charset);vm->DeleteLocalRef(output);return result;
}
jstring from_utf8(const Bytes& value) {
  const auto cls=vm->FindClass("java/lang/String");check();
  const auto constructor=vm->GetMethodID(cls,"<init>","([BLjava/lang/String;)V");check();
  const auto data=byte_array(value);
  const auto charset=vm->NewStringUTF("UTF-8");
  const auto result=static_cast<jstring>(vm->NewObject(cls,constructor,data,charset));check();
  vm->DeleteLocalRef(cls);vm->DeleteLocalRef(data);vm->DeleteLocalRef(charset);return result;
}
std::array<std::uint8_t,16> md5(const std::uint8_t* data,std::size_t size) {
  const auto cls=vm->FindClass("java/security/MessageDigest");check();
  const auto method=vm->GetStaticMethodID(cls,"getInstance","(Ljava/lang/String;)Ljava/security/MessageDigest;");check();
  const auto name=vm->NewStringUTF("MD5");
  const auto digest=vm->CallStaticObjectMethod(cls,method,name);check();
  const auto run=vm->GetMethodID(cls,"digest","([B)[B");check();
  const auto input=byte_array(Bytes(data,data+size));
  const auto output=static_cast<jbyteArray>(vm->CallObjectMethod(digest,run,input));check();
  const auto raw=bytes(output);
  if(raw.size()!=16)throw std::runtime_error("Unexpected digest length");
  std::array<std::uint8_t,16> result{};std::copy(raw.begin(),raw.end(),result.begin());
  for(const auto value:{static_cast<jobject>(cls),static_cast<jobject>(name),digest,static_cast<jobject>(input),static_cast<jobject>(output)})vm->DeleteLocalRef(value);
  return result;
}
Bytes cbc(const Bytes& padded,const std::array<std::uint8_t,32>& material,bool aes) {
  const auto cls=vm->FindClass("javax/crypto/Cipher");check();
  const auto get=vm->GetStaticMethodID(cls,"getInstance","(Ljava/lang/String;)Ljavax/crypto/Cipher;");check();
  const auto transform=vm->NewStringUTF(aes?"AES/CBC/NoPadding":"DES/CBC/NoPadding");
  const auto cipher=vm->CallStaticObjectMethod(cls,get,transform);check();
  const auto key_cls=vm->FindClass("javax/crypto/spec/SecretKeySpec");check();
  const auto key_ctor=vm->GetMethodID(key_cls,"<init>","([BLjava/lang/String;)V");check();
  const auto key_data=byte_array(Bytes(material.begin(),aes?material.end():material.begin()+8));
  const auto algorithm=vm->NewStringUTF(aes?"AES":"DES");
  const auto key=vm->NewObject(key_cls,key_ctor,key_data,algorithm);check();
  const auto iv_cls=vm->FindClass("javax/crypto/spec/IvParameterSpec");check();
  const auto iv_ctor=vm->GetMethodID(iv_cls,"<init>","([B)V");check();
  const auto iv_data=byte_array(Bytes(material.begin(),material.begin()+(aes?16:8)));
  const auto iv=vm->NewObject(iv_cls,iv_ctor,iv_data);check();
  const auto init=vm->GetMethodID(cls,"init","(ILjava/security/Key;Ljava/security/spec/AlgorithmParameterSpec;)V");check();
  vm->CallVoidMethod(cipher,init,1,key,iv);check();
  const auto finish=vm->GetMethodID(cls,"doFinal","([B)[B");check();
  const auto input=byte_array(padded);
  const auto output=static_cast<jbyteArray>(vm->CallObjectMethod(cipher,finish,input));check();
  auto result=bytes(output);
  for(const auto value:{static_cast<jobject>(cls),static_cast<jobject>(transform),cipher,static_cast<jobject>(key_cls),static_cast<jobject>(key_data),static_cast<jobject>(algorithm),key,static_cast<jobject>(iv_cls),static_cast<jobject>(iv_data),iv,static_cast<jobject>(input),static_cast<jobject>(output)})vm->DeleteLocalRef(value);
  return result;
}
}
