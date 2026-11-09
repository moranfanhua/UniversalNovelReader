#include "collector.hpp"
#include "detector_names.hpp"
#include <cerrno>
#include "assembly.hpp"
#include "jvm_crypto.hpp"
#include <algorithm>
#include <array>
#include <cstdio>
#include <cstring>
#include <fstream>
#include <iterator>
#include <mutex>
#include <optional>
#include <stdexcept>
#include <string>
#include <vector>
#include <dirent.h>
#include <fcntl.h>
#include <unistd.h>
#include <sys/socket.h>
#include <sys/select.h>
#include <netinet/in.h>

namespace independent_knobs {
bool fd_marker();bool task_marker();std::string prop_serial();long raw_open(const char*);
}
namespace ibex_producer {
namespace {
using namespace jvm_crypto;
struct Vm {
  JNIEnv* e;
  jclass cls(const char* name){auto c=e->FindClass(name);check();return c;}
  jmethodID method(jobject o,const char* name,const char* signature){auto c=e->GetObjectClass(o);auto m=e->GetMethodID(c,name,signature);check();e->DeleteLocalRef(c);return m;}
  std::string text(jstring value){if(!value)return {};auto raw=utf8(value);return {raw.begin(),raw.end()};}
  jstring str(const std::string& value){return from_utf8(Bytes(value.begin(),value.end()));}
  std::string string(jobject o,const char* name){auto value=static_cast<jstring>(e->CallObjectMethod(o,method(o,name,"()Ljava/lang/String;")));check();return text(value);}
  jobject object(jobject o,const char* name,const char* signature){auto result=e->CallObjectMethod(o,method(o,name,signature));check();return result;}
  jobject json(){auto c=cls("org/json/JSONObject");auto result=e->NewObject(c,e->GetMethodID(c,"<init>","()V"));check();return result;}
  jobject get(jobject o,const char* key){auto k=e->NewStringUTF(key);auto result=e->CallObjectMethod(o,method(o,"opt","(Ljava/lang/String;)Ljava/lang/Object;"),k);check();e->DeleteLocalRef(k);return result;}
  bool isnull(jobject o){if(!o)return true;auto c=cls("org/json/JSONObject");auto value=e->GetStaticObjectField(c,e->GetStaticFieldID(c,"NULL","Ljava/lang/Object;"));check();return e->IsSameObject(o,value);}
  std::optional<std::string> nullable(jobject o,const char* key){auto value=get(o,key);if(isnull(value))return {};if(!e->IsInstanceOf(value,cls("java/lang/String")))throw std::invalid_argument("Authorized value must be text or null");return text(static_cast<jstring>(value));}
  std::string string(jobject o,const char* key,const std::string& fallback){auto k=e->NewStringUTF(key),f=str(fallback);auto value=static_cast<jstring>(e->CallObjectMethod(o,method(o,"optString","(Ljava/lang/String;Ljava/lang/String;)Ljava/lang/String;"),k,f));check();auto out=text(value);e->DeleteLocalRef(k);e->DeleteLocalRef(f);e->DeleteLocalRef(value);return out;}
  bool flag(jobject o,const char* key){auto k=e->NewStringUTF(key);auto value=e->CallBooleanMethod(o,method(o,"optBoolean","(Ljava/lang/String;Z)Z"),k,JNI_FALSE);check();e->DeleteLocalRef(k);return value;}
  void put(jobject o,const char* key,jobject value){auto k=e->NewStringUTF(key);e->CallObjectMethod(o,method(o,"put","(Ljava/lang/String;Ljava/lang/Object;)Lorg/json/JSONObject;"),k,value);check();e->DeleteLocalRef(k);}
  void put(jobject o,const char* key,const std::string& value){auto s=str(value);put(o,key,s);e->DeleteLocalRef(s);}
  void boolean(jobject o,const char* key,bool value){auto k=e->NewStringUTF(key);e->CallObjectMethod(o,method(o,"put","(Ljava/lang/String;Z)Lorg/json/JSONObject;"),k,static_cast<jboolean>(value));check();e->DeleteLocalRef(k);}
  void integer(jobject o,const char* key,int value){auto k=e->NewStringUTF(key);e->CallObjectMethod(o,method(o,"put","(Ljava/lang/String;I)Lorg/json/JSONObject;"),k,value);check();e->DeleteLocalRef(k);}
  std::string lower(const std::string& value){auto s=str(value);auto out=static_cast<jstring>(e->CallObjectMethod(s,method(s,"toLowerCase","()Ljava/lang/String;")));check();return text(out);}
  std::string build(const char* key){auto c=cls("android/os/Build");auto field=e->GetStaticFieldID(c,key,"Ljava/lang/String;");check();auto s=static_cast<jstring>(e->GetStaticObjectField(c,field));check();return s?text(s):"null";}
  std::vector<std::string> array(jobject value){std::vector<std::string> out;if(isnull(value))return out;auto n=e->CallIntMethod(value,method(value,"length","()I"));check();for(int i=0;i<n;++i){auto item=static_cast<jstring>(e->CallObjectMethod(value,method(value,"getString","(I)Ljava/lang/String;"),i));check();out.push_back(text(item));e->DeleteLocalRef(item);}return out;}
};
std::string md5_text(const std::string& value){auto digest=md5(reinterpret_cast<const std::uint8_t*>(value.data()),value.size());constexpr char hex[]="0123456789abcdef";std::string out;for(auto byte:digest){out+=hex[byte>>4];out+=hex[byte&15];}return out;}
std::string command(const std::string& value){std::string out;FILE* pipe=popen(value.c_str(),"r");if(!pipe)return out;std::array<char,4096> b{};std::size_t n;while((n=fread(b.data(),1,b.size(),pipe)))out.append(b.data(),n);pclose(pipe);return out;}
std::string property(const std::string& name){auto value=command("getprop "+name);value.erase(std::remove(value.begin(),value.end(),'\n'),value.end());return value;}
bool includes(const std::string& value,const std::string& needle){return value.find(needle)!=std::string::npos;}
bool contains(const std::vector<std::string>& values,const char* key){return std::find(values.begin(),values.end(),key)!=values.end();}
template<std::size_t N>bool packages(const std::vector<std::string>& values,const std::array<const char*,N>& wanted){for(auto name:wanted)if(contains(values,name))return true;return false;}
std::string join(const std::vector<std::string>& values,const std::string& separator){std::string out;for(std::size_t i=0;i<values.size();++i){if(i)out+=separator;out+=values[i];}return out;}
struct Matches {
  Vm& v;jobject pattern=nullptr,set=nullptr;
  Matches(Vm& vm,const std::string& expression):v(vm){
    auto c=v.cls("java/util/HashSet");set=v.e->NewObject(c,v.e->GetMethodID(c,"<init>","()V"));check();
    if(expression.empty())return;c=v.cls("java/util/regex/Pattern");auto text=v.str(expression);
    pattern=v.e->CallStaticObjectMethod(c,v.e->GetStaticMethodID(c,"compile","(Ljava/lang/String;I)Ljava/util/regex/Pattern;"),text,2);
    if(v.e->ExceptionCheck()){v.e->ExceptionClear();pattern=nullptr;}
  }
  void add(const std::string& line){if(!pattern)return;auto text=v.str(line);auto matcher=v.e->CallObjectMethod(pattern,v.method(pattern,"matcher","(Ljava/lang/CharSequence;)Ljava/util/regex/Matcher;"),text);check();
    if(v.e->CallBooleanMethod(matcher,v.method(matcher,"find","()Z"))){auto part=v.e->CallObjectMethod(matcher,v.method(matcher,"group","()Ljava/lang/String;"));check();v.e->CallBooleanMethod(set,v.method(set,"add","(Ljava/lang/Object;)Z"),part);check();v.e->DeleteLocalRef(part);}v.e->DeleteLocalRef(matcher);v.e->DeleteLocalRef(text);
  }
  std::string joined(){std::vector<std::string> values;auto it=v.object(set,"iterator","()Ljava/util/Iterator;");while(v.e->CallBooleanMethod(it,v.method(it,"hasNext","()Z"))){auto item=static_cast<jstring>(v.object(it,"next","()Ljava/lang/Object;"));values.push_back(v.text(item));v.e->DeleteLocalRef(item);}check();return join(values,",");}
};
std::string configured(Vm& v,jobject settings,const char* key,const char* fallback){if(v.isnull(settings))return fallback;auto value=v.string(settings,key,"");return value.empty()?fallback:value;}
struct MapFacts {int anonymous=0;bool xposed=false;};
MapFacts maps(Vm& v){
  MapFacts facts;std::ifstream input("/proc/self/maps");std::string line;
  while(std::getline(input,line)){auto lower=v.lower(line);const auto suffix=[&](const char* end){const std::string tail(end);return lower.size()>=tail.size()&&lower.compare(lower.size()-tail.size(),tail.size(),tail)==0;};
    if((suffix(".so")||suffix(".jar"))&&(includes(lower,"xposed")||includes(lower,"lsposed")))facts.xposed=true;
    lower.erase(std::remove(lower.begin(),lower.end(),' '),lower.end());constexpr char tail[]="xp0000000000:000";
    if(lower.size()>=sizeof(tail)-1&&lower.compare(lower.size()-(sizeof(tail)-1),sizeof(tail)-1,tail)==0)++facts.anonymous;
  }return facts;
}
std::string files(Vm& v,jobject context,jobject settings,const std::string& data){
  Matches matches(v,configured(v,settings,"suspiciousFiles","QDReadHook"));std::vector<std::string> dirs{data+"/files"};
  auto external=v.e->CallObjectMethod(context,v.method(context,"getExternalFilesDir","(Ljava/lang/String;)Ljava/io/File;"),nullptr);check();if(external)dirs.push_back(v.string(external,"getAbsolutePath"));
  for(auto& path:dirs){DIR* dir=opendir(path.c_str());if(!dir)continue;while(auto entry=readdir(dir)){if(strcmp(entry->d_name,".")&&strcmp(entry->d_name,".."))matches.add(entry->d_name);}closedir(dir);}return matches.joined();
}
bool local_port(){
  int fd=socket(AF_INET,SOCK_STREAM,0);if(fd<0)return false;int flags=fcntl(fd,F_GETFL,0);fcntl(fd,F_SETFL,flags|O_NONBLOCK);sockaddr_in addr{};addr.sin_family=AF_INET;addr.sin_port=htons(27042);addr.sin_addr.s_addr=htonl(INADDR_LOOPBACK);
  bool success=connect(fd,reinterpret_cast<sockaddr*>(&addr),sizeof(addr))==0;
  if(!success&&errno==EINPROGRESS){fd_set write;FD_ZERO(&write);FD_SET(fd,&write);timeval timeout{3,0};if(select(fd+1,nullptr,&write,nullptr,&timeout)>0){int error=0;socklen_t len=sizeof(error);success=getsockopt(fd,SOL_SOCKET,SO_ERROR,&error,&len)==0&&error==0;}}
  close(fd);return success;
}
bool vmos_properties(){
  constexpr std::array<const char*,14> names{"vmos.browser.home","vmos.camera.enable","vmpro.gps","vmprop.imei","vmpro.gsm","vmpro.hw-control","vmpro.sensors","vmprop.ip","vmpro.wifi","vm.camera.status","vmprop.androidid","vmprop.wifissid","vmprop.simserialnumber","vmprop.simoperatorname"};int count=0;
  for(auto name:names)if(!property(name).empty())++count;for(auto name:{"persist.package.name","ro.product.modle"})if(includes(property(name),"vmos"))++count;return count>=3;
}
// Framework reflection/certificate/ATX implementations are defined separately.
bool class_probe(Vm&,jobject);bool stack_probe(Vm&,const std::vector<std::string>&,bool);bool descriptor_parent(Vm&,const std::string&);std::string certificate(Vm&,const std::string&);bool atx(Vm&,bool);
class Access final:public nib_pipeline::JsonAccess {
 public:Access(Vm& v,jobject json):v_(v),json_(json){}
  std::u16string string_value(const std::string& key,const std::string& fallback) override{auto k=v_.str(key),f=v_.str(fallback);auto value=static_cast<jstring>(v_.e->CallObjectMethod(json_,v_.method(json_,"optString","(Ljava/lang/String;Ljava/lang/String;)Ljava/lang/String;"),k,f));check();auto out=utf16(value);v_.e->DeleteLocalRef(k);v_.e->DeleteLocalRef(f);v_.e->DeleteLocalRef(value);return out;}
  bool boolean_value(const std::string& key) override{return v_.flag(json_,key.c_str());}
 private:Vm& v_;jobject json_;
};
struct JavaFailure {jthrowable error;};
void java_check(Vm& v){if(v.e->ExceptionCheck()){auto error=v.e->ExceptionOccurred();v.e->ExceptionClear();throw JavaFailure{error};}}
bool stack_contains(Vm& v,jthrowable error,const std::vector<std::string>& names){
  if(!error)return false;auto frames=static_cast<jobjectArray>(v.object(error,"getStackTrace","()[Ljava/lang/StackTraceElement;"));
  for(jsize i=0;i<v.e->GetArrayLength(frames);++i){auto frame=v.e->GetObjectArrayElement(frames,i);auto text=v.string(frame,"getClassName");for(auto& name:names)if(includes(text,name))return true;v.e->DeleteLocalRef(frame);}return false;
}
bool class_probe(Vm& v,jobject loader){
  auto exception=v.cls("java/lang/ClassNotFoundException"),illegal=v.cls("java/lang/IllegalAccessException"),instantiate=v.cls("java/lang/InstantiationException");
  while(loader){
    for(const char* name:{"de.robv.android.xposed.XposedHelpers","de.robv.android.xposed.XposedBridge"}){
      auto text=v.e->NewStringUTF(name);auto type=v.e->CallObjectMethod(loader,v.method(loader,"loadClass","(Ljava/lang/String;)Ljava/lang/Class;"),text);
      if(!v.e->ExceptionCheck())v.e->CallObjectMethod(type,v.method(type,"newInstance","()Ljava/lang/Object;"));
      if(v.e->ExceptionCheck()){auto error=v.e->ExceptionOccurred();v.e->ExceptionClear();if(v.e->IsInstanceOf(error,illegal)||v.e->IsInstanceOf(error,instantiate))return true;if(!v.e->IsInstanceOf(error,exception))return false;}
    }loader=v.object(loader,"getParent","()Ljava/lang/ClassLoader;");
  }return false;
}
bool stack_probe(Vm& v,const std::vector<std::string>& names,bool reflected){
  if(!reflected){auto c=v.cls("java/lang/Exception");auto error=static_cast<jthrowable>(v.e->NewObject(c,v.e->GetMethodID(c,"<init>","(Ljava/lang/String;)V"),v.e->NewStringUTF("oaa")));check();return stack_contains(v,error,names);}
  try{
    auto unsafe=v.cls("sun/misc/Unsafe");auto singleton=v.e->CallObjectMethod(unsafe,v.method(unsafe,"getDeclaredField","(Ljava/lang/String;)Ljava/lang/reflect/Field;"),v.e->NewStringUTF("theUnsafe"));java_check(v);
    v.e->CallVoidMethod(singleton,v.method(singleton,"setAccessible","(Z)V"),JNI_TRUE);java_check(v);auto instance=v.e->CallObjectMethod(singleton,v.method(singleton,"get","(Ljava/lang/Object;)Ljava/lang/Object;"),nullptr);java_check(v);
    auto apk=v.cls("android/app/LoadedApk");auto types=v.e->NewObjectArray(1,v.cls("java/lang/Class"),v.cls("java/lang/Class"));check();
    auto alloc=v.e->CallObjectMethod(unsafe,v.method(unsafe,"getMethod","(Ljava/lang/String;[Ljava/lang/Class;)Ljava/lang/reflect/Method;"),v.e->NewStringUTF("allocateInstance"),types);java_check(v);
    auto args=v.e->NewObjectArray(1,v.cls("java/lang/Object"),apk);check();auto allocated=v.e->CallObjectMethod(alloc,v.method(alloc,"invoke","(Ljava/lang/Object;[Ljava/lang/Object;)Ljava/lang/Object;"),instance,args);java_check(v);
    v.e->SetObjectArrayElement(types,0,v.cls("java/util/List"));check();auto method=v.e->CallObjectMethod(apk,v.method(apk,"getDeclaredMethod","(Ljava/lang/String;[Ljava/lang/Class;)Ljava/lang/reflect/Method;"),v.e->NewStringUTF("createOrUpdateClassLoaderLocked"),types);java_check(v);
    v.e->CallVoidMethod(method,v.method(method,"setAccessible","(Z)V"),JNI_TRUE);java_check(v);v.e->CallObjectMethod(method,v.method(method,"invoke","(Ljava/lang/Object;[Ljava/lang/Object;)Ljava/lang/Object;"),allocated,nullptr);java_check(v);return false;
  }catch(const JavaFailure& failure){
    if(!v.e->IsInstanceOf(failure.error,v.cls("java/lang/reflect/InvocationTargetException")))return false;
    auto cause=static_cast<jthrowable>(v.object(failure.error,"getCause","()Ljava/lang/Throwable;"));return stack_contains(v,cause,names);
  }
}
bool descriptor_parent(Vm& v,const std::string& data){
  jobject stream=nullptr;bool result=false;
  try{
    auto cls=v.cls("java/io/FileOutputStream");stream=v.e->NewObject(cls,v.e->GetMethodID(cls,"<init>","(Ljava/lang/String;)V"),v.str(data+"/knobs_file"));java_check(v);
    auto fd=v.object(stream,"getFD","()Ljava/io/FileDescriptor;");auto descriptor=v.e->CallObjectMethod(v.e->GetObjectClass(fd),v.method(v.e->GetObjectClass(fd),"getDeclaredField","(Ljava/lang/String;)Ljava/lang/reflect/Field;"),v.e->NewStringUTF("descriptor"));java_check(v);
    v.e->CallVoidMethod(descriptor,v.method(descriptor,"setAccessible","(Z)V"),JNI_TRUE);java_check(v);auto number=v.e->CallIntMethod(descriptor,v.method(descriptor,"getInt","(Ljava/lang/Object;)I"),fd);java_check(v);
    char link[64]{};snprintf(link,sizeof(link),"/proc/self/fd/%d",number);char target[4096]{};auto n=readlink(link,target,sizeof(target)-1);
    if(n>=0){std::string path(target,static_cast<std::size_t>(n));auto last=path.find_last_of('/');if(path.substr(last)=="/knobs_file"){std::size_t p=0;while((p=path.find("knobs_file",p))!=std::string::npos){path.replace(p,10,"..");p+=2;}result=access(path.c_str(),R_OK)==0;}else result=true;}
  }catch(const JavaFailure&){result=false;}
  if(stream){v.e->CallVoidMethod(stream,v.method(stream,"close","()V"));if(v.e->ExceptionCheck())v.e->ExceptionClear();}return result;
}
std::string certificate(Vm& v,const std::string& path){
  jobject owner=nullptr,zip=nullptr;std::string result;
  try{
    // Use the same JNI modified-UTF-8 pathname representation as the selected original oa wrapper.
    auto name=v.str(path);auto raw=v.e->GetStringUTFChars(name,nullptr);java_check(v);int fd=static_cast<int>(independent_knobs::raw_open(raw));v.e->ReleaseStringUTFChars(name,raw);
    auto pfd=v.cls("android/os/ParcelFileDescriptor");owner=v.e->CallStaticObjectMethod(pfd,v.e->GetStaticMethodID(pfd,"adoptFd","(I)Landroid/os/ParcelFileDescriptor;"),fd);java_check(v);
    auto descriptor=v.object(owner,"getFileDescriptor","()Ljava/io/FileDescriptor;");auto streamClass=v.cls("java/io/FileInputStream");auto stream=v.e->NewObject(streamClass,v.e->GetMethodID(streamClass,"<init>","(Ljava/io/FileDescriptor;)V"),descriptor);java_check(v);
    auto zipClass=v.cls("java/util/zip/ZipInputStream");zip=v.e->NewObject(zipClass,v.e->GetMethodID(zipClass,"<init>","(Ljava/io/InputStream;)V"),stream);java_check(v);
    while(auto entry=v.e->CallObjectMethod(zip,v.method(zip,"getNextEntry","()Ljava/util/zip/ZipEntry;"))){java_check(v);auto entryName=static_cast<jstring>(v.object(entry,"getName","()Ljava/lang/String;"));auto expression=v.e->NewStringUTF("(META-INF/.*)\\.(RSA|DSA|EC)");bool matches=v.e->CallBooleanMethod(entryName,v.method(entryName,"matches","(Ljava/lang/String;)Z"),expression);java_check(v);v.e->DeleteLocalRef(expression);v.e->DeleteLocalRef(entryName);v.e->DeleteLocalRef(entry);if(!matches)continue;
      auto factoryClass=v.cls("java/security/cert/CertificateFactory");auto factory=v.e->CallStaticObjectMethod(factoryClass,v.e->GetStaticMethodID(factoryClass,"getInstance","(Ljava/lang/String;)Ljava/security/cert/CertificateFactory;"),v.e->NewStringUTF("X509"));java_check(v);
      auto cert=v.e->CallObjectMethod(factory,v.method(factory,"generateCertificate","(Ljava/io/InputStream;)Ljava/security/cert/Certificate;"),zip);java_check(v);auto encoded=static_cast<jbyteArray>(v.object(cert,"getEncoded","()[B"));auto rawData=bytes(encoded);result=md5_text(std::string(rawData.begin(),rawData.end()));break;
    }java_check(v);
  }catch(const JavaFailure&){result.clear();}
  for(auto stream:{zip,owner})if(stream){v.e->CallVoidMethod(stream,v.method(stream,"close","()V"));if(v.e->ExceptionCheck()){v.e->ExceptionClear();result.clear();}}return result;
}
bool atx(Vm& v,bool proxy){
  jobject connection=nullptr,reader=nullptr;bool enabled=false;std::string address="http://127.0.0.1:7912/info";
  try{
    for(int attempt=0;attempt<2;++attempt){
      auto urlClass=v.cls("java/net/URL");auto url=v.e->NewObject(urlClass,v.e->GetMethodID(urlClass,"<init>","(Ljava/lang/String;)V"),v.str(address));java_check(v);
      if(proxy)connection=v.e->CallObjectMethod(url,v.method(url,"openConnection","()Ljava/net/URLConnection;"));
      else{auto cls=v.cls("java/net/Proxy");auto no=v.e->GetStaticObjectField(cls,v.e->GetStaticFieldID(cls,"NO_PROXY","Ljava/net/Proxy;"));connection=v.e->CallObjectMethod(url,v.method(url,"openConnection","(Ljava/net/Proxy;)Ljava/net/URLConnection;"),no);}java_check(v);
      v.e->CallVoidMethod(connection,v.method(connection,"setRequestMethod","(Ljava/lang/String;)V"),v.e->NewStringUTF("GET"));java_check(v);v.e->CallVoidMethod(connection,v.method(connection,"setUseCaches","(Z)V"),JNI_FALSE);java_check(v);
      for(auto method:{"setConnectTimeout","setReadTimeout"}){v.e->CallVoidMethod(connection,v.method(connection,method,"(I)V"),30000);java_check(v);}v.e->CallVoidMethod(connection,v.method(connection,"connect","()V"));java_check(v);
      int status=v.e->CallIntMethod(connection,v.method(connection,"getResponseCode","()I"));java_check(v);
      if(attempt==0&&(status==301||status==302||status==307)){
        auto location=static_cast<jstring>(v.e->CallObjectMethod(connection,v.method(connection,"getHeaderField","(Ljava/lang/String;)Ljava/lang/String;"),v.e->NewStringUTF("Location")));java_check(v);if(!location)location=static_cast<jstring>(v.e->CallObjectMethod(connection,v.method(connection,"getHeaderField","(Ljava/lang/String;)Ljava/lang/String;"),v.e->NewStringUTF("location")));java_check(v);if(!location)break;
        address=v.text(location);if(!includes(address,"://"))address=v.string(url,"getProtocol")+"://"+v.string(url,"getHost")+address;v.e->CallVoidMethod(connection,v.method(connection,"disconnect","()V"));java_check(v);connection=nullptr;continue;
      }
      if(status==200||status==204){
        auto input=v.e->CallObjectMethod(connection,v.method(connection,"getInputStream","()Ljava/io/InputStream;"));java_check(v);if(!input)break;
        auto irClass=v.cls("java/io/InputStreamReader");auto inputReader=v.e->NewObject(irClass,v.e->GetMethodID(irClass,"<init>","(Ljava/io/InputStream;)V"),input);java_check(v);auto brClass=v.cls("java/io/BufferedReader");reader=v.e->NewObject(brClass,v.e->GetMethodID(brClass,"<init>","(Ljava/io/Reader;)V"),inputReader);java_check(v);
        std::string body;while(auto line=static_cast<jstring>(v.e->CallObjectMethod(reader,v.method(reader,"readLine","()Ljava/lang/String;")))){java_check(v);body+=v.text(line)+"\n";v.e->DeleteLocalRef(line);}java_check(v);
        auto jsonClass=v.cls("org/json/JSONObject");auto object=v.e->NewObject(jsonClass,v.e->GetMethodID(jsonClass,"<init>","(Ljava/lang/String;)V"),v.str(body));java_check(v);enabled=object!=nullptr;
      }break;
    }
  }catch(const JavaFailure&){enabled=false;}
  if(reader){v.e->CallVoidMethod(reader,v.method(reader,"close","()V"));if(v.e->ExceptionCheck())v.e->ExceptionClear();}if(connection){v.e->CallVoidMethod(connection,v.method(connection,"disconnect","()V"));if(v.e->ExceptionCheck())v.e->ExceptionClear();}return enabled;
}
}
struct Producer::State {std::mutex lock;bool first=false,failed=false;std::optional<bool> lsp;std::string signature;};
Producer::Producer():state_(std::make_unique<State>()){}
Producer::~Producer()=default;
void Producer::mark_failed(){std::lock_guard<std::mutex> lock(state_->lock);state_->failed=true;}
jobject Producer::collect_required(JNIEnv* env,jobject context,jobject input,jobject options){
  bind(env);Vm v{env};for(const char* name:{"guid","qimei","qimei36","model","ssid","interfaces","packages"}){auto key=env->NewStringUTF(name);bool present=env->CallBooleanMethod(input,v.method(input,"has","(Ljava/lang/String;)Z"),key);check();env->DeleteLocalRef(key);if(!present)throw std::invalid_argument("Missing authorized input field");}std::lock_guard<std::mutex> guard(state_->lock);if(state_->failed)throw std::runtime_error("Collection gate retained after failure");state_->failed=true;auto output=v.json();auto settings=v.get(options,"settings");auto info=v.object(context,"getApplicationInfo","()Landroid/content/pm/ApplicationInfo;");if(!info)throw std::invalid_argument("Application info absent");auto infoClass=env->GetObjectClass(info);
  const auto data=v.text(static_cast<jstring>(env->GetObjectField(info,env->GetFieldID(infoClass,"dataDir","Ljava/lang/String;"))));check();
  auto package=v.string(context,"getPackageName");auto path=v.string(context,"getPackageResourcePath");auto packageValues=v.array(v.get(input,"packages"));
  for(const char* key:{"guid","qimei","qimei36"})v.put(output,key,v.nullable(input,key).value_or(""));v.put(output,"platform",std::string("android"));v.put(output,"obs_packageName",package);
  v.put(output,"obs_pluginCharacter",files(v,context,settings,data));
  for(const char* key:{"androidboot.hardware","ro.setupwizard.mode","ro.secureboot.lockstate","ro.boot.flash.locked","vendor.boot.vbmeta.device_state","vendor.boot.verifiedbootstate","ro.boot.vbmeta.device_state","sys.oem_unlock_allowed","sys.locksettings.remoteauth.enable"})v.put(output,(std::string("obs_")+key).c_str(),property(key));
  v.put(output,"obs_androidboot.verifiedstate",property("ro.boot.verifiedbootstate"));
  const auto map=maps(v);v.integer(output,"obs_countCAS",map.anonymous);v.boolean(output,"obs_isXposedByMaps",map.xposed);v.put(output,"obs_propSerial",independent_knobs::prop_serial());
  // Fixed request declarations: no root/accessibility or module-name probes.
  for(const char* key:{"obs_isDebug","obs_isCheckZygiskByMap","obs_isRootByPath","obs_isRootByPackageName","obs_isRootByMagisk","obs_isRootByAttr","obs_isAccessibilityEnable","obs_isAutoJsByAccessibility"})v.boolean(output,key,false);
  v.put(output,"obs_hasSuspiciousDylib",std::string());v.put(output,"obs_loadLib",std::string());
  auto classLoader=v.get(input,"classLoader");if(v.isnull(classLoader))classLoader=v.object(context,"getClassLoader","()Ljava/lang/ClassLoader;");
  v.boolean(output,"obs_isXposedByClass",class_probe(v,classLoader));v.boolean(output,"obs_isXposedByStack",stack_probe(v,{"de.robv.android.xposed"},false));v.boolean(output,"obs_isPatchByResourcePath",includes(path,"patch"));
  v.boolean(output,"obs_isFridaByPort",local_port());v.boolean(output,"obs_isFridaByFd",independent_knobs::fd_marker());v.boolean(output,"obs_isFridaByTask",independent_knobs::task_marker());v.boolean(output,"obs_isInlineByFuncsArm",false);
  bool cpu=false;std::ifstream cpuinfo("/proc/cpuinfo");std::string line;while(std::getline(cpuinfo,line))if(includes(line,"Goldfish")){cpu=true;break;}v.boolean(output,"obs_isEmulatorByCpuInfo",cpu);v.boolean(output,"obs_isEmulatorByFile",access("/init.goldfish.rc",F_OK)==0||access("/sys/qemu_trace",F_OK)==0||access("/system/bin/qemud",F_OK)==0);v.boolean(output,"obs_isEmulatorByEth0",contains(v.array(v.get(input,"interfaces")),"eth0"));
  v.boolean(output,"obs_isMultiBoxByPkg",std::count(packageValues.begin(),packageValues.end(),package)>1);v.boolean(output,"obs_isMultiBoxByFileStr",access((data+"/..").c_str(),R_OK)==0);v.boolean(output,"obs_isMultiBoxByParentDir",descriptor_parent(v,data));v.boolean(output,"obs_isMultiBoxByUid",getuid()/100000!=0);
  v.boolean(output,"obs_isUiautomatorByPkg",contains(packageValues,"com.github.uiautomator")||contains(packageValues,"com.github.uiautomator.test"));v.boolean(output,"obs_isAppToolByPkg",packages(packageValues,kAutomationPackages));v.boolean(output,"obs_isScrcpyByNetStat",includes(command("netstat -apn"),"scrcpy"));v.boolean(output,"obs_isAdbBySystemProperties",includes(property("persist.sys.usb.config"),"adb"));
  if(!v.flag(options,"m"))v.boolean(output,"obs_isVMOSByWifi",includes(v.nullable(input,"ssid").value_or(""),"VMOSWIFI"));v.boolean(output,"obs_isVMOSByPackageName",packages(packageValues,kVmosPackages));v.boolean(output,"obs_isVMOSByProperty",vmos_properties());v.boolean(output,"obs_isAtx",atx(v,v.flag(options,"s")));
  auto model=v.nullable(input,"model").value_or("null"),product=v.build("PRODUCT"),brand=v.build("BRAND");v.put(output,"obs_deviceModel",model+" ("+product+")");v.put(output,"obs_deviceBrand",brand);
  for(auto pair:std::array<std::pair<const char*,const char*>,5>{{{"obs_deviceBoard","BOARD"},{"obs_deviceManufacturer","MANUFACTURER"},{"obs_deviceHost","HOST"},{"obs_deviceCPU_ABI","CPU_ABI"},{"obs_deviceCPU_ABI2","CPU_ABI2"}}})v.put(output,pair.first,v.build(pair.second));
  std::vector<std::string> parts{v.build("DEVICE"),v.nullable(input,"model").value_or("null"),product,brand,v.build("BOARD"),v.build("DISPLAY"),v.build("CPU_ABI"),v.build("CPU_ABI2"),v.build("HARDWARE"),v.build("ID"),v.build("MANUFACTURER"),v.build("USER"),v.build("HOST")};v.put(output,"obs_devicePartsHash",md5_text(v.lower(join(parts,","))));
  if(!v.flag(options,"h")){if(state_->signature.empty())state_->signature=certificate(v,path);v.put(output,"obs_signatureMd5FromSvc",state_->signature);}
  if(!v.flag(options,"k")){
    if(!state_->first){state_->first=true;if(!v.flag(options,"e"))state_->lsp=stack_probe(v,{"org.lsposed","de.robv.android.xposed","LSPHooker","com.elder.xposed","HookBridge","SandHook"},true);}
    if(!v.flag(options,"e")&&state_->lsp)v.boolean(output,"obs_isLspByStack",*state_->lsp);
  }state_->failed=false;return output;
}
std::string Producer::generate(JNIEnv* env,jobject context,jobject input,jobject options,std::int64_t now){auto report=collect_required(env,context,input,options);Vm v{env};Access access(v,report);return nib_pipeline::encode(nib_pipeline::join(nib_pipeline::assemble(access,now)));}
std::string encode_report(JNIEnv* env,jobject report,std::int64_t now){bind(env);Vm v{env};Access access(v,report);return nib_pipeline::encode(nib_pipeline::join(nib_pipeline::assemble(access,now)));}
}
