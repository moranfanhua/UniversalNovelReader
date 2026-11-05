#include "windows_context.hpp"
#include "http_windows.hpp"
#include "qimei_json.hpp"
#ifndef NOMINMAX
#define NOMINMAX
#endif
#include <windows.h>
#include <cstdlib>
#include <cstring>
#include <limits>
#include <map>
#include <mutex>
#include <stdexcept>

namespace {
using namespace qimei;
using namespace qimei::client;
constexpr std::uint64_t maximum=2*1024*1024;
void require(bool value){if(!value)throw std::invalid_argument("Native parameter input invalid");}
std::string text(const Json& input,const char* name,const std::string& fallback={}){const auto* value=input.find(name);if(!value)return fallback;require(value->kind==Json::Kind::string);return value->text;}
bool flag(const Json& input,const char* name,bool fallback=false){const auto* value=input.find(name);if(!value)return fallback;require(value->kind==Json::Kind::boolean);return value->boolean;}
Json boolean(bool value){return Json::parse(value?"true":"false");}
std::uint64_t identifier(const Json& input){const auto value=text(input,"handle");require(!value.empty()&&value.find_first_not_of("0123456789")==std::string::npos);const auto id=std::stoull(value);require(id>0);return id;}
const char* status(ProviderStatus value){switch(value){case ProviderStatus::ready:return "ready";case ProviderStatus::busy:return "busy";case ProviderStatus::closed:return "closed";case ProviderStatus::cooldown:return "cooldown";case ProviderStatus::privacy_required:return "privacy_required";case ProviderStatus::transport_failed:return "transport_failed";case ProviderStatus::http_rejected:return "http_rejected";case ProviderStatus::app_rejected:return "app_rejected";case ProviderStatus::invalid_response:return "invalid_response";case ProviderStatus::empty_identifiers:return "empty_identifiers";case ProviderStatus::store_failed:return "store_failed";case ProviderStatus::refresh_failed:return "refresh_failed";}return "unavailable";}
struct Owner {std::shared_ptr<WindowsContext> context;std::shared_ptr<WindowsHttp> http;std::unique_ptr<Client> client;};
struct Registry {std::mutex mutex;std::map<std::uint64_t,std::shared_ptr<Owner>> owners;std::uint64_t next=1;};
// Explicit close owns shutdown. Avoid running blocking network cancellation
// from a DLL's CRT teardown under the Windows loader lock at process exit.
Registry& registry(){static auto* value=new Registry;return *value;}
std::shared_ptr<Owner> owner(std::uint64_t id){auto& r=registry();std::lock_guard<std::mutex> guard(r.mutex);const auto found=r.owners.find(id);if(found==r.owners.end())throw std::runtime_error("Native parameter handle closed");return found->second;}
Json dispatch(const Json& input){
  require(input.kind==Json::Kind::object);const auto op=text(input,"op");
  if(op=="info")return Json::object({{"ok",boolean(true)},{"apiVersion",Json::number(1)},{"platform",Json::string("windows")},{"originalSdkRequired",boolean(false)}});
  if(op=="create"){
    require(flag(input,"privacyAgreed"));const auto directory=std::filesystem::u8path(text(input,"directory"));require(!directory.empty()&&directory.is_absolute());WindowsSession session;
    if(const auto* account=input.find("session")){require(account->kind==Json::Kind::object);session.device_id=text(*account,"deviceId");session.user_id=text(*account,"userId","0");session.oaid=text(*account,"oaid");session.huawei_referrer=text(*account,"huaweiReferrer");session.strategy_android_id=text(*account,"strategyAndroidId");session.cookie.token=text(*account,"token");session.cookie.yw_key=text(*account,"ywKey");session.cookie.yw_guid=text(*account,"ywGuid");}
    auto value=std::make_shared<Owner>();value->context=WindowsContext::open(directory,true,session);value->http=std::make_shared<WindowsHttp>();value->client=make_windows_client(value->context,value->http,flag(input,"allowNetwork",true));
    auto& r=registry();std::lock_guard<std::mutex> guard(r.mutex);require(r.next<std::uint64_t(std::numeric_limits<std::int64_t>::max()));const auto id=r.next++;r.owners.emplace(id,std::move(value));return Json::object({{"ok",boolean(true)},{"handle",Json::string(std::to_string(id))}});
  }
  if(op=="close"){
    const auto id=identifier(input);std::shared_ptr<Owner> value;auto& r=registry();{std::lock_guard<std::mutex> guard(r.mutex);const auto found=r.owners.find(id);if(found!=r.owners.end()){value=found->second;r.owners.erase(found);}}
    if(value){value->client->close();}
    return Json::object({{"ok",boolean(true)},{"closed",boolean(true)}});
  }
  if(op=="pause"){const auto result=owner(identifier(input))->client->note_risk();return Json::object({{"ok",boolean(true)},{"persisted",boolean(result.status==ProviderStatus::cooldown)}});}
  if(op=="headers"){
    const auto value=owner(identifier(input));std::map<std::string,std::string> fields;const auto* parameters=input.find("params");require(parameters&&parameters->kind==Json::Kind::object);for(const auto& entry:parameters->members){require(entry.second.kind==Json::Kind::string);fields.emplace(entry.first,entry.second.text);}
    app::CookieContext session;std::string user="0";if(const auto* account=input.find("session")){require(account->kind==Json::Kind::object);user=text(*account,"userId","0");session.token=text(*account,"token");session.yw_key=text(*account,"ywKey");session.yw_guid=text(*account,"ywGuid");}
    const auto result=value->client->prepare(fields,session,user);std::map<std::string,Json> headers;for(const auto& [name,data]:result)headers.emplace(name,Json::string(data));return Json::object({{"ok",boolean(true)},{"headers",Json::object(std::move(headers))}});
  }
  if(op=="script_auth"){
    const auto value=owner(identifier(input));if(value->client->gate_status()==ProviderStatus::cooldown)return Json::object({{"ok",boolean(false)},{"serviceCode",Json::number(-4403)}});
    std::map<std::string,Json> headers;for(const auto& [name,data]:script::authorization(text(input,"uid"),text(input,"timestamp")))headers.emplace(name,Json::string(data));return Json::object({{"ok",boolean(true)},{"headers",Json::object(std::move(headers))}});
  }
  if(op=="script_install"){
    const auto id=input.find("id");require(id&&id->kind==Json::Kind::number&&id->integer(-1)>=0);owner(identifier(input))->client->install_script(std::uint64_t(id->integer()),unbase64(text(input,"data")));return Json::object({{"ok",boolean(true)}});
  }
  if(op=="ensure"){
    const auto value=owner(identifier(input));const auto result=value->client->ensure(true,flag(input,"forceRefresh"));
    return Json::object({{"ok",boolean(true)},{"ready",boolean(result.ready())},{"status",Json::string(status(result.provider.status))},{"pairComplete",boolean(result.pair_complete())},{"fromCache",boolean(result.from_cache)},{"serviceCode",Json::number(result.provider.service_code)},{"qimei",Json::string(std::string(result.provider.identifiers.qimei.begin(),result.provider.identifiers.qimei.end()))},{"qimei36",Json::string(std::string(result.provider.identifiers.qimei36.begin(),result.provider.identifiers.qimei36.end()))},{"ibex",Json::string(result.ibex)}});
  }
  throw std::invalid_argument("Native parameter operation invalid");
}
void* allocate(std::uint64_t length){if(length>maximum)return nullptr;auto* block=static_cast<std::size_t*>(std::calloc(1,sizeof(std::size_t)+static_cast<std::size_t>(length)+1));if(!block)return nullptr;*block=static_cast<std::size_t>(length)+1;return block+1;}
char* output(const std::string& value){auto* memory=static_cast<char*>(allocate(value.size()));if(memory)std::memcpy(memory,value.data(),value.size());return memory;}
}
extern "C" __declspec(dllexport) void* unr_qidian_allocate(std::uint64_t length)noexcept{return allocate(length);}
extern "C" __declspec(dllexport) void unr_qidian_free(void* pointer)noexcept{if(!pointer)return;auto* block=static_cast<std::size_t*>(pointer)-1;const auto length=*block;SecureZeroMemory(block,sizeof(std::size_t)+length);std::free(block);}
extern "C" __declspec(dllexport) char* unr_qidian_dispatch(const std::uint8_t* input,std::uint64_t length)noexcept{
  try{require(input&&length>0&&length<=maximum);return output(dispatch(Json::parse(std::string(reinterpret_cast<const char*>(input),static_cast<std::size_t>(length)))).encode());}
  catch(...){return output("{\"ok\":false,\"error\":\"native_parameters_unavailable\"}");}
}
