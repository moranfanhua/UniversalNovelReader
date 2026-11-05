#pragma once
#include <jni.h>
#include <string>

namespace nib_pipeline {
// Android/JVM String(byte[], UTF_8) supplies the original replacement policy.
// The archived byte-oriented decoder remains unchanged.
std::u16string decode_armor_text(JNIEnv* env, jstring encoded);
}
