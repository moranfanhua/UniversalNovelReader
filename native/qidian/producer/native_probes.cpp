// Independent selected-ARM64 implementations from inspected instruction/DEX evidence.
// Own-process observations only; does not hide instrumentation or replace detection results.
#include "jvm_crypto.hpp"
#include "md4.hpp"
#include "md2.hpp"
#include <array>
#include <cerrno>
#include <cstdio>
#include <cstring>
#include <cstdint>
#include <string>
#include <mutex>
#include <dirent.h>
#include <fcntl.h>
#include <sys/stat.h>
#include <sys/mman.h>
#include <sys/syscall.h>
#include <sys/system_properties.h>
#include <unistd.h>

namespace independent_knobs {
bool fd_marker(){
  DIR* folder=opendir("/proc/self/fd");if(!folder)return false;bool found=false;dirent* entry;
  static int sdk=0;
  while((entry=readdir(folder))){
    char path[256]{};snprintf(path,sizeof(path),"/proc/self/fd/%s",entry->d_name);struct stat status{};
    if(lstat(path,&status)!=0||!S_ISLNK(status.st_mode))continue;
    if(sdk<1){char value[96]{};__system_property_get("ro.build.version.sdk",value);sdk=atoi(value);}if(sdk<=20)continue;
    char target[512]{};syscall(__NR_readlinkat,AT_FDCWD,path,target,256);
    if(strstr(target,"linjector")){found=true;break;}
  }closedir(folder);return found;
}
bool task_marker(){
  DIR* folder=opendir("/proc/self/task");if(!folder)return false;bool found=false;dirent* entry;
  while((entry=readdir(folder))){
    if(!strcmp(entry->d_name,".")||!strcmp(entry->d_name,".."))continue;
    char path[256]{};snprintf(path,sizeof(path),"/proc/self/task/%s/status",entry->d_name);int fd=openat(AT_FDCWD,path,O_RDONLY|O_CLOEXEC,0);
    if(fd==0)continue;char line[256]{};std::size_t n=0;char byte;
    while(n<255&&read(fd,&byte,1)==1&&byte!='\n')line[n++]=byte;
    found=strstr(line,"gum-js-loop")||strstr(line,"gmain");close(fd);if(found)break;
  }closedir(folder);return found;
}
std::string prop_serial(){
  const prop_info* property=__system_property_find("ro.dalvik.vm.native.bridge");if(!property)return "0";
  const auto* data=reinterpret_cast<const unsigned char*>(property);char value[9]{};
  snprintf(value,sizeof(value),"%02x%02x%02x%02x",data[0],data[1],data[2],data[3]);return value;
}
bool jni_changed(JNIEnv* env){
  constexpr std::array<std::size_t,5> offsets{0x30,0x28,0x6d8,0xe0,0x6b8};
  static std::array<std::uint64_t,5> previous{};static std::mutex guard;std::lock_guard<std::mutex> lock(guard);
  const auto* table=reinterpret_cast<const std::uint8_t*>(env->functions);
  for(std::size_t i=0;i<offsets.size();++i){std::uint64_t current=0;
    for(std::size_t n=0;n<16;++n)current=current*10+table[offsets[i]+n];current-=0xbd7a6254055550ULL;
    if(previous[i]!=0&&previous[i]!=current)return true;previous[i]=current;
  }return false;
}
std::string api_sign(const jvm_crypto::Bytes& value){
  if(value.empty()||value[0]==0)return "";const auto first=native_md2::digest(value.data(),value.size());
  const auto second=jvm_crypto::md5(first.data(),first.size());const auto third=portable_md4::digest(second.data(),second.size());
  static constexpr char hex[]="0123456789abcdef";std::string out;out.reserve(32);
  for(auto byte:third){out.push_back(hex[byte>>4]);out.push_back(hex[byte&15]);}return out;
}
long raw_open(const char* path){
#if defined(__aarch64__)
  register long x0 asm("x0")=AT_FDCWD;register const char* x1 asm("x1")=path;
  register long x2 asm("x2")=O_RDONLY;register long x8 asm("x8")=__NR_openat;
  asm volatile("svc 0":"+r"(x0):"r"(x1),"r"(x2),"r"(x8):"memory","cc");return x0;
#else
  const long result=syscall(__NR_openat,AT_FDCWD,path,O_RDONLY);return result<0?-errno:result;
#endif
}
}

extern "C" JNIEXPORT jboolean JNICALL Java_org_unr_research_producer_NativeProducer_cfbf(JNIEnv*,jclass){return independent_knobs::fd_marker();}
extern "C" JNIEXPORT jboolean JNICALL Java_org_unr_research_producer_NativeProducer_cfbt(JNIEnv*,jclass){return independent_knobs::task_marker();}
extern "C" JNIEXPORT jboolean JNICALL Java_org_unr_research_producer_NativeProducer_iaa(JNIEnv*,jclass){const auto length=static_cast<std::size_t>(sysconf(39));unsigned char value{};return mincore(reinterpret_cast<void*>(0x7ffffff000ULL&(~(length-1))),length,&value)==0;}
extern "C" JNIEXPORT jboolean JNICALL Java_org_unr_research_producer_NativeProducer_cibfa(JNIEnv* env,jclass){return independent_knobs::jni_changed(env);}
extern "C" JNIEXPORT jstring JNICALL Java_org_unr_research_producer_NativeProducer_gps(JNIEnv* env,jclass){return env->NewStringUTF(independent_knobs::prop_serial().c_str());}
extern "C" JNIEXPORT jstring JNICALL Java_org_unr_research_producer_NativeProducer_apis(JNIEnv* env,jclass,jbyteArray input){
  try{jvm_crypto::bind(env);return env->NewStringUTF(independent_knobs::api_sign(jvm_crypto::bytes(input)).c_str());}catch(...){if(!env->ExceptionCheck())env->ThrowNew(env->FindClass("java/lang/IllegalArgumentException"),"Unsupported input");return nullptr;}
}
extern "C" JNIEXPORT jint JNICALL Java_org_unr_research_producer_NativeProducer_oa(JNIEnv* env,jclass,jstring path){
  if(!path){env->ThrowNew(env->FindClass("java/lang/NullPointerException"),"Null path");return -1;}const char* value=env->GetStringUTFChars(path,nullptr);if(!value)return -1;
  const auto fd=independent_knobs::raw_open(value);env->ReleaseStringUTFChars(path,value);return static_cast<jint>(fd);
}
