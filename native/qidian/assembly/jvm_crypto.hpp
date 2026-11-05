#pragma once
#include <jni.h>
#include <array>
#include <cstddef>
#include <cstdint>
#include <string>
#include <vector>
namespace jvm_crypto {
using Bytes=std::vector<std::uint8_t>;
void bind(JNIEnv* env);
void check();
Bytes bytes(jbyteArray value);
jbyteArray byte_array(const Bytes& value);
jstring java_string(const std::u16string& value);
std::u16string utf16(jstring value);
Bytes utf8(jstring value);
jstring from_utf8(const Bytes& value);
std::array<std::uint8_t,16> md5(const std::uint8_t* data,std::size_t size);
Bytes cbc(const Bytes& padded,const std::array<std::uint8_t,32>& material,bool aes);
}
