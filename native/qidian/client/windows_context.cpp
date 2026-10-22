#ifndef NOMINMAX
#define NOMINMAX
#endif
#include <winsock2.h>
#include <ws2tcpip.h>
#include <windows.h>
#include <iphlpapi.h>
#include <psapi.h>
#include "windows_context.hpp"
#include "windows_device_profile.hpp"
#include "http_windows.hpp"
#include "crypto_backend.hpp"
#include "qimei_crypto.hpp"
#include "qimei_file_store.hpp"
#include "windows_store.hpp"
#include "qimei_json.hpp"
#include "qimei_profile.hpp"
#include "qimei_register.hpp"
#include "selected_protocol.hpp"
#include <algorithm>
#include <cctype>
#include <fstream>
#include <iterator>
#include <stdexcept>

namespace qimei::client {
namespace {
struct Handle {HANDLE value=INVALID_HANDLE_VALUE;~Handle(){if(value!=INVALID_HANDLE_VALUE&&value)CloseHandle(value);}};
std::string field(const Json& object,const char* name){const auto* value=object.find(name);if(!value||value->kind!=Json::Kind::string)throw std::runtime_error("Windows identity structure invalid");return value->text;}
std::string random_hex(std::size_t size){Bytes value(size);crypto::random(value.data(),value.size());return hex(value);}
Json validate_identity(const std::string& raw){
  const auto object=Json::parse(raw);const auto* version=object.find("version");if(!version||version->integer()!=1||field(object,"origin")!="declared-virtual-android-on-windows")throw std::runtime_error("Windows identity profile unsupported");
  for(const auto* name:{"androidId","udid","uin","createdMs","abi","model"})if(field(object,name).empty())throw std::runtime_error("Windows identity field missing");
  const auto android_id=field(object,"androidId"),udid=field(object,"udid"),created=field(object,"createdMs");
  if(android_id.size()!=16||android_id.find_first_not_of("0123456789abcdef")!=std::string::npos||udid.size()!=36||created.find_first_not_of("0123456789")!=std::string::npos)throw std::runtime_error("Windows identity field invalid");
  try{if(!std::stoull(created))throw std::runtime_error("Windows identity time invalid");}catch(const std::exception&){throw std::runtime_error("Windows identity time invalid");}return object;
}
Json read_identity(const std::filesystem::path& path){
  std::error_code error;const auto size=std::filesystem::file_size(path,error);if(error||size>16384)throw std::runtime_error("Windows identity size invalid");
  std::ifstream input(path,std::ios::binary);if(!input)throw std::runtime_error("Windows identity unavailable");const std::string raw(std::istreambuf_iterator<char>(input),{});if(input.bad())throw std::runtime_error("Windows identity read failed");return validate_identity(raw);
}
struct Modules {bool xposed=false,virtual_xposed=false,autojs=false;};
Modules modules(){
  std::vector<HMODULE> values(128);DWORD size=0;
  if(!EnumProcessModules(GetCurrentProcess(),values.data(),DWORD(values.size()*sizeof(HMODULE)),&size))throw std::runtime_error("Windows own-module inventory unavailable");
  if(size>values.size()*sizeof(HMODULE)){values.resize(size/sizeof(HMODULE));if(!EnumProcessModules(GetCurrentProcess(),values.data(),size,&size)||size>values.size()*sizeof(HMODULE))throw std::runtime_error("Windows own-module inventory changed");}
  Modules result;
  for(std::size_t i=0;i<size/sizeof(HMODULE);++i){std::array<wchar_t,1024> path{};const auto count=GetModuleBaseNameW(GetCurrentProcess(),values[i],path.data(),DWORD(path.size()));if(!count||count>=path.size()-1)throw std::runtime_error("Windows own-module name unavailable");std::string name;for(DWORD n=0;n<count;++n)name+=path[n]<128?char(std::tolower(static_cast<unsigned char>(path[n]))):'?';
    result.xposed|=name.find("xposed")!=std::string::npos||name.find("lsposed")!=std::string::npos;
    result.virtual_xposed|=name.find("virtualxposed")!=std::string::npos;
    result.autojs|=name.find("autojs")!=std::string::npos||name.find("auto.js")!=std::string::npos;
  }return result;
}
std::string local_ipv4(){
  ULONG size=16384;std::vector<std::uint8_t> buffer(size);auto* adapters=reinterpret_cast<IP_ADAPTER_ADDRESSES*>(buffer.data());auto error=GetAdaptersAddresses(AF_INET,GAA_FLAG_SKIP_ANYCAST|GAA_FLAG_SKIP_MULTICAST|GAA_FLAG_SKIP_DNS_SERVER,nullptr,adapters,&size);
  if(error==ERROR_BUFFER_OVERFLOW&&size<1024*1024){buffer.resize(size);adapters=reinterpret_cast<IP_ADAPTER_ADDRESSES*>(buffer.data());error=GetAdaptersAddresses(AF_INET,GAA_FLAG_SKIP_ANYCAST|GAA_FLAG_SKIP_MULTICAST|GAA_FLAG_SKIP_DNS_SERVER,nullptr,adapters,&size);}if(error!=NO_ERROR)return "0.0.0.0";
  for(auto* adapter=adapters;adapter;adapter=adapter->Next)if(adapter->OperStatus==IfOperStatusUp&&adapter->IfType!=IF_TYPE_SOFTWARE_LOOPBACK&&adapter->FirstUnicastAddress){
    auto* address=adapter->FirstUnicastAddress;while(address&&address->Address.lpSockaddr->sa_family!=AF_INET)address=address->Next;if(!address)continue;
    char ip[INET_ADDRSTRLEN]{};const auto* v4=reinterpret_cast<const sockaddr_in*>(address->Address.lpSockaddr);if(!InetNtopA(AF_INET,&v4->sin_addr,ip,sizeof(ip)))continue;return ip;
  }return "0.0.0.0";
}
std::string flag(bool value){return value?"1":"0";}
}
struct WindowsContext::Runtime {
  std::filesystem::path directory;Handle lock;Json identity;std::shared_ptr<StateStore> store;WindowsSession session;
};
std::uint64_t system_time_ms(){FILETIME stamp{};GetSystemTimeAsFileTime(&stamp);ULARGE_INTEGER value{};value.LowPart=stamp.dwLowDateTime;value.HighPart=stamp.dwHighDateTime;return value.QuadPart/10000-11644473600000ULL;}
Profile bundled_protocol(){return decode_profile(selected_protocol_json);}
WindowsContext::WindowsContext(std::shared_ptr<Runtime> runtime):runtime_(std::move(runtime)){}
WindowsContext::~WindowsContext()=default;
std::shared_ptr<WindowsContext> WindowsContext::open(const std::filesystem::path& directory,bool consent,const WindowsSession& session){
  if(!consent)throw std::invalid_argument("Windows identity requires privacy consent");
  if(directory.empty())throw std::invalid_argument("Windows private directory missing");
  if(session.user_id.empty()||session.user_id.find_first_not_of("0123456789")!=std::string::npos)throw std::invalid_argument("Authorized user identifier invalid");
  auto r=std::make_shared<Runtime>();r->directory=directory;std::error_code error;std::filesystem::create_directories(directory,error);if(error)throw std::runtime_error("Windows identity directory unavailable");
  r->lock.value=CreateFileW((directory/L"identity.lock").c_str(),GENERIC_READ|GENERIC_WRITE,0,nullptr,OPEN_ALWAYS,FILE_ATTRIBUTE_NORMAL,nullptr);if(r->lock.value==INVALID_HANDLE_VALUE)throw std::runtime_error("Windows identity already in use or unavailable");
  auto store=std::make_shared<WindowsStore>(directory);const auto stored=store->identity_json();
  if(stored){r->identity=validate_identity(*stored);}
  else{
    if(store->state_present())throw std::runtime_error("Windows cached state has no identity");
    const auto path=directory/L"identity.json";const bool exists=std::filesystem::exists(path,error);if(error)throw std::runtime_error("Windows identity access failed");
    FileStateStore legacy(directory/L"qimei-state.json");const auto previous=legacy.read();
    if(!previous.app_key.empty()&&previous.app_key!=bytes("0I000JZU8B16UN21"))throw std::runtime_error("Windows legacy state belongs to another profile");
    if(exists)r->identity=read_identity(path);
    else{
      if(!previous.app_key.empty()||!previous.identifiers.empty()||previous.risk_until_ms)throw std::runtime_error("Windows legacy state has no identity");
      const std::string architecture=windows_device_profile::cpu_abi,stamp=std::to_string(system_time_ms());auto raw_uuid=unhex(random_hex(16));raw_uuid[6]=(raw_uuid[6]&15)|64;raw_uuid[8]=(raw_uuid[8]&63)|128;auto uuid=hex(raw_uuid);uuid.insert(8,"-");uuid.insert(13,"-");uuid.insert(18,"-");uuid.insert(23,"-");
      r->identity=Json::object({{"version",Json::number(1)},{"origin",Json::string("declared-virtual-android-on-windows")},{"androidId",Json::string(random_hex(8))},{"udid",Json::string(uuid)},{"uin",Json::string(stamp+random_hex(8))},{"createdMs",Json::string(stamp)},{"abi",Json::string(architecture)},{"model",Json::string(windows_device_profile::model)}});
    }
    store->initialize(r->identity.encode(),previous);
  }
  r->store=std::move(store);r->session=session;return std::shared_ptr<WindowsContext>(new WindowsContext(std::move(r)));
}
std::shared_ptr<StateStore> WindowsContext::state_store()const{return runtime_->store;}
std::string WindowsContext::identity_fingerprint()const{const auto raw=bytes(runtime_->identity.encode());return qimei::http::sn(raw);}
Snapshot WindowsContext::collect(const Identifiers& identifiers)const{
  // Public profile declarations are independent of the persisted installation
  // identity: retain existing Android ID, UDID, UIN, QIMEI and cooldown records.
  const auto& identity=runtime_->identity;const std::string model=windows_device_profile::model,android_id=field(identity,"androidId");const auto now=system_time_ms(),uptime=GetTickCount64();const auto ip=local_ipv4();const auto loaded=modules();
  constexpr bool root=windows_device_profile::root,debug=windows_device_profile::debug,accessibility=windows_device_profile::accessibility;
  const auto profile=bundled_protocol();const std::string brand=windows_device_profile::brand,board="unr_windows_compat",product="unr_android_compat",device="unr_compat",host="unr-windows-compat";
  // Debug, root, accessibility, x86, network type and module names are declared
  // compatibility values. Module flags inspect only this process; local IP is
  // measured on the host. Android-only probes are not claimed to have executed.
  Snapshot result;auto& h=result.headers;h.brand=brand;h.include_android_id=true;h.session=runtime_->session.cookie;auto& c=h.device;
  c.android_id=android_id;c.device=runtime_->session.device_id.empty()?android_id:runtime_->session.device_id;c.user_id=runtime_->session.user_id;c.oaid=runtime_->session.oaid;c.huawei_referrer=runtime_->session.huawei_referrer;c.model=model;c.os_release=windows_device_profile::android_release;c.width=windows_device_profile::screen_width;c.height=windows_device_profile::screen_height;c.stored_channel=c.package_channel="10000431";c.network_type=windows_device_profile::network_type;c.emulator=1;c.qimei16=std::string(identifiers.qimei.begin(),identifiers.qimei.end());c.qimei36=std::string(identifiers.qimei36.begin(),identifiers.qimei36.end());
  h.environment={std::to_string(0x100400|(root?4:0)),flag(root),flag(loaded.xposed),"1",flag(accessibility),flag(debug),flag(loaded.autojs),flag(loaded.virtual_xposed),flag(windows_device_profile::x86)};
  auto& common=result.registration.common;common.app_key=bytes("0I000JZU8B16UN21");common.sdk_version=bytes("5.1.2.28-yw");common.app_version=bytes("7.9.480.1996");common.os_version=bytes(windows_device_profile::os_version);common.model=bytes(model);common.process_name=bytes(windows_device_profile::package_name);common.network=bytes(windows_device_profile::network);common.installation_uin=bytes(field(identity,"uin"));
  const auto extra=Json::object({{"harmony",Json::string("0")},{"clone",Json::string("0")},{"containe",Json::string("unr-windows-compat")},{"oz",Json::string(encode_device_value(bytes(android_id),profile))},{"oz2",Json::string("")},{"oo",Json::string(encode_device_value(bytes(model),profile))},{"kelong",Json::string("0")},{"ip",Json::string(ip)},{"multiUser",Json::string("0")},{"bod",Json::string(board)},{"brd",Json::string(brand)},{"dv",Json::string(device)},{"firstLevel",Json::string(windows_device_profile::android_api_level)},{"manufact",Json::string(brand)},{"name",Json::string(product)},{"host",Json::string(host)},{"kernel",Json::string(windows_device_profile::kernel)},{"pre",Json::string("0")},{"av",Json::string("7.9.480.1996")},{"ch",Json::string("10000431")},{"svr",Json::string("")},{"fit",Json::number(std::int64_t(std::stoull(field(identity,"createdMs"))))}});
  AndroidRegisterFields fields;fields.channel=bytes(c.package_channel);fields.target_sdk=bytes("30");fields.user_id_json=bytes(Json::object({{"userId",Json::string(c.user_id)}}).encode());fields.oaid=bytes(c.oaid);fields.android_id=bytes(runtime_->session.strategy_android_id);fields.brand=bytes(brand);fields.extended_json=bytes(extra.encode());fields.device_type=bytes(windows_device_profile::device_type);fields.uptime_history=bytes(std::to_string((now-std::min(now,std::uint64_t(uptime)))/1000));result.registration.report=android_register_body(fields);
  auto& report=result.report;const auto set=[&](const char* key,const std::string& value){report.set_text(key,utf16(bytes(value)));};
  set("android_id",android_id);set("obs_udid",field(identity,"udid"));set("guid",h.session.yw_guid);set("qimei",c.qimei16);set("qimei36",c.qimei36);set("platform","android");set("obs_packageName",windows_device_profile::package_name);set("obs_deviceModel",model);set("obs_deviceBrand",brand);set("obs_deviceBoard",board);set("obs_deviceManufacturer",brand);set("obs_deviceHost",host);set("obs_deviceCPU_ABI",windows_device_profile::cpu_abi);set("obs_deviceCPU_ABI2",windows_device_profile::cpu_abi2);set("obs_deviceDevice",device);set("obs_deviceOsAPILevel",windows_device_profile::android_api_level);set("obs_deviceRelease",windows_device_profile::android_release);set("obs_hasSuspiciousDylib",windows_device_profile::suspicious_modules);
  report.set_boolean("obs_isAccessibilityEnable",accessibility);report.set_boolean("obs_isDebug",debug);report.set_boolean("obs_isEmulatorByCpuInfo",true);report.set_boolean("obs_isRootByAttr",root);report.set_boolean("obs_isXposedByMaps",loaded.xposed);report.set_boolean("obs_isAutoJsByAccessibility",loaded.autojs);report.set_integer("event_time",std::int64_t(now));
  // Missing Android property/package/root/port probes retain the encoder's
  // documented missing-field semantics. No blanket all-false detector map.
  return result;
}
std::unique_ptr<Client> make_windows_client(const std::shared_ptr<WindowsContext>& context,std::shared_ptr<WindowsHttp> http,bool allow_network){if(!context)throw std::invalid_argument("Windows context missing");if(!http)http=std::make_shared<WindowsHttp>();return std::make_unique<Client>(bundled_protocol(),bytes("0I000JZU8B16UN21"),context->state_store(),[context](const auto& ids){return context->collect(ids);},app::platform_encrypt,[](ibex::Report& report,std::int64_t stamp){return ibex::generate(report,stamp);},[http,allow_network](const auto& request){if(!allow_network)throw std::runtime_error("Offline client transport disabled");return http->send(request);},[http]{http->close();},system_time_ms);}
}
