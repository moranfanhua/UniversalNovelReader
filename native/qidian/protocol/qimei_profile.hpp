#pragma once
#include "qimei_protocol.hpp"
namespace qimei {
// Selected static protocol configuration only; no native machine code or AppKey.
std::string encode_profile(const Profile& profile);
Profile decode_profile(const std::string& json);
Bytes modified_utf8(const std::u16string& text);
// ART behavior measured on the Android 15 target: valid surrogate pairs become
// four bytes; NUL and unpaired surrogates retain JNI's special encoding.
Bytes android_jni_utf8(const std::u16string& text);
}
