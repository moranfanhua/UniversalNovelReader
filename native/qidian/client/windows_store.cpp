#include "windows_store.hpp"
#include "qimei_crypto.hpp"
#include "qimei_json.hpp"
#ifndef NOMINMAX
#define NOMINMAX
#endif
#include <windows.h>
#include <limits>
#include <stdexcept>
namespace qimei::client {
namespace {
constexpr DWORD max_record=131072;
void require(bool value,const char* site="value"){if(!value)throw std::runtime_error(std::string("Windows private state failed: ")+site);}
struct Handle {HANDLE value=INVALID_HANDLE_VALUE;~Handle(){if(value!=INVALID_HANDLE_VALUE)CloseHandle(value);}};
struct Key {HKEY value=nullptr;~Key(){if(value)RegCloseKey(value);}};
bool open(Key& key,const std::wstring& path){const auto result=RegOpenKeyExW(HKEY_CURRENT_USER,path.c_str(),0,KEY_QUERY_VALUE,&key.value);if(result==ERROR_FILE_NOT_FOUND)return false;require(result==ERROR_SUCCESS,"registry-open");return true;}
std::optional<std::string> raw(HKEY key,const wchar_t* name){
  DWORD type=0,length=0;auto status=RegQueryValueExW(key,name,nullptr,&type,nullptr,&length);if(status==ERROR_FILE_NOT_FOUND)return {};
  require(status==ERROR_SUCCESS&&type==REG_BINARY&&length>0&&length<=max_record,"registry-size");std::string value(length,'\0');DWORD read=length;
  status=RegQueryValueExW(key,name,nullptr,&type,reinterpret_cast<BYTE*>(value.data()),&read);require(status==ERROR_SUCCESS&&type==REG_BINARY&&read==length,"registry-read");return value;
}
std::string field(const Json& object,const char* name){const auto* value=object.find(name);require(value&&value->kind==Json::Kind::string,"field");return value->text;}
std::uint64_t decimal(const std::string& value){require(!value.empty()&&value.find_first_not_of("0123456789")==std::string::npos,"number");try{return std::stoull(value);}catch(const std::exception&){throw std::runtime_error("Windows private state number invalid");}}
std::string encode(const StoredState& value){
  const auto result=Json::object({{"version",Json::number(1)},{"appKey",Json::string(base64(value.app_key))},{"qimei",Json::string(base64(value.identifiers.qimei))},{"qimei36",Json::string(base64(value.identifiers.qimei36))},{"riskUntilMs",Json::string(std::to_string(value.risk_until_ms))}}).encode();require(result.size()<=65536,"state-size");return result;
}
StoredState decode(const std::string& encoded){
  require(encoded.size()<=65536,"state-size");const auto object=Json::parse(encoded);const auto* version=object.find("version");require(version&&version->integer()==1,"state-version");
  return {unbase64(field(object,"appKey")),{unbase64(field(object,"qimei")),unbase64(field(object,"qimei36"))},decimal(field(object,"riskUntilMs"))};
}
std::string digest(std::uint64_t sequence,const std::string& payload){auto input=bytes("UNR-QIMEI-STATE-1:"+std::to_string(sequence));input.push_back(0);input.insert(input.end(),payload.begin(),payload.end());return hex(crypto::digest(input,crypto::Hash::sha256));}
struct Record {std::uint64_t sequence=0;std::string identity;StoredState state;};
Record decode_record(const std::string& value){
  const auto object=Json::parse(value);const auto* version=object.find("version");require(version&&version->integer()==1,"record-version");const auto sequence=decimal(field(object,"sequence"));const auto payload=field(object,"payload");require(sequence>0&&sequence<=std::uint64_t(std::numeric_limits<std::int64_t>::max()),"record-sequence");require(field(object,"digest")==digest(sequence,payload),"record-integrity");
  const auto data=Json::parse(payload);const auto identity=field(data,"identity");require(!identity.empty()&&identity.size()<=16384,"identity-size");return {sequence,identity,decode(field(data,"state"))};
}
std::string encode_record(const Record& record){
  require(!record.identity.empty()&&record.identity.size()<=16384,"identity-size");const auto payload=Json::object({{"identity",Json::string(record.identity)},{"state",Json::string(encode(record.state))}}).encode();
  const auto result=Json::object({{"version",Json::number(1)},{"sequence",Json::string(std::to_string(record.sequence))},{"payload",Json::string(payload)},{"digest",Json::string(digest(record.sequence,payload))}}).encode();require(result.size()<=max_record,"record-size");return result;
}
std::optional<Record> latest(const std::wstring& path){
  Key key;if(!open(key,path))return {};const auto first=raw(key.value,L"a"),second=raw(key.value,L"b");std::optional<Record> selected;
  // A damaged record is an error, even if the other snapshot is readable.
  // Automatically rolling back could discard a persisted -4403 cooldown.
  for(const auto* encoded:{&first,&second})if(*encoded){const auto record=decode_record(**encoded);if(selected){require(selected->identity==record.identity&&selected->sequence!=record.sequence,"record-history");if(selected->sequence>record.sequence)continue;}selected=record;}
  return selected;
}
void persist(const std::wstring& path,const Record& record){
  const auto encoded=encode_record(record);Key key;require(RegCreateKeyExW(HKEY_CURRENT_USER,path.c_str(),0,nullptr,REG_OPTION_NON_VOLATILE,KEY_QUERY_VALUE|KEY_SET_VALUE,nullptr,&key.value,nullptr)==ERROR_SUCCESS,"registry-create");
  const auto* slot=(record.sequence&1)?L"a":L"b";
  require(RegSetValueExW(key.value,slot,0,REG_BINARY,reinterpret_cast<const BYTE*>(encoded.data()),static_cast<DWORD>(encoded.size()))==ERROR_SUCCESS,"registry-write");
  require(RegFlushKey(key.value)==ERROR_SUCCESS,"registry-flush");require(raw(key.value,slot)==encoded,"registry-readback");
}
}
WindowsStore::WindowsStore(const std::filesystem::path& directory){
  Handle handle;handle.value=CreateFileW(directory.c_str(),FILE_READ_ATTRIBUTES,FILE_SHARE_READ|FILE_SHARE_WRITE|FILE_SHARE_DELETE,nullptr,OPEN_EXISTING,FILE_FLAG_BACKUP_SEMANTICS,nullptr);require(handle.value!=INVALID_HANDLE_VALUE,"directory-handle");
  const auto length=GetFinalPathNameByHandleW(handle.value,nullptr,0,FILE_NAME_NORMALIZED|VOLUME_NAME_DOS);require(length>0&&length<=32768,"directory-name-size");std::wstring canonical(length,L'\0');const auto count=GetFinalPathNameByHandleW(handle.value,canonical.data(),length,FILE_NAME_NORMALIZED|VOLUME_NAME_DOS);require(count>0&&count<length,"directory-name-read");canonical.resize(count);
  const auto* first=reinterpret_cast<const std::uint8_t*>(canonical.data());const auto hash=hex(crypto::digest(Bytes(first,first+canonical.size()*sizeof(wchar_t)),crypto::Hash::sha256));subkey_=L"Software\\UniversalNovelReader\\QidianProvider\\v1\\"+std::wstring(hash.begin(),hash.end());
}
std::optional<std::string> WindowsStore::identity_json(){std::lock_guard<std::mutex> guard(mutex_);const auto record=latest(subkey_);return record?std::optional<std::string>(record->identity):std::nullopt;}
bool WindowsStore::state_present(){std::lock_guard<std::mutex> guard(mutex_);return latest(subkey_).has_value();}
void WindowsStore::initialize(const std::string& identity,const StoredState& state){std::lock_guard<std::mutex> guard(mutex_);require(!latest(subkey_),"already-initialized");persist(subkey_,{1,identity,state});}
StoredState WindowsStore::read(){std::lock_guard<std::mutex> guard(mutex_);const auto record=latest(subkey_);return record?record->state:StoredState{};}
bool WindowsStore::save(const StoredState& state){std::lock_guard<std::mutex> guard(mutex_);try{const auto previous=latest(subkey_);require(previous&&previous->sequence<std::uint64_t(std::numeric_limits<std::int64_t>::max()),"state-not-initialized");persist(subkey_,{previous->sequence+1,previous->identity,state});return true;}catch(const std::exception&){return false;}}
}
