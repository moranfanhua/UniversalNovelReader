#include "snapshot_json.hpp"
#include "qimei_json.hpp"
#include "qimei_snapshot.hpp"
#include <limits>
#include <stdexcept>

namespace qimei::client {
namespace {
const Json& required(const Json& parent,const char* name,Json::Kind kind){const auto* value=parent.find(name);if(!value||value->kind!=kind)throw std::invalid_argument("Client snapshot field missing or invalid");return *value;}
const Json& object(const Json& parent,const char* name){return required(parent,name,Json::Kind::object);}
std::string text(const Json& parent,const char* name){return required(parent,name,Json::Kind::string).text;}
std::uint32_t number(const Json& parent,const char* name){const auto value=required(parent,name,Json::Kind::number).integer(-1);if(value<0||value>std::numeric_limits<std::uint32_t>::max())throw std::invalid_argument("Client snapshot number invalid");return std::uint32_t(value);}
}
Snapshot snapshot_from_json(const std::string& encoded){
  if(encoded.size()>4*1024*1024)throw std::length_error("Client snapshot too large");
  const auto root=Json::parse(encoded);const auto& registration=object(root,"registration");const auto& headers=object(root,"headers");const auto& c=object(headers,"context");const auto& env=object(headers,"environment");const auto& session=object(headers,"session");const auto& report=object(root,"report");
  Snapshot out;out.registration=snapshot_from_android_json(registration.encode());
  out.registration.common.installation_uin=bytes(text(object(registration,"common"),"installationUin"));
  auto& h=out.headers;auto& device=h.device;
  device.device=text(c,"device");device.version=text(c,"version");device.stored_channel=text(c,"storedChannel");device.os_release=text(c,"osRelease");device.model=text(c,"model");device.package_channel=text(c,"packageChannel");device.user_id=text(c,"userId");device.android_id=text(c,"androidId");device.huawei_referrer=text(c,"huaweiReferrer");device.oaid=text(c,"oaid");
  device.width=number(c,"width");device.height=number(c,"height");device.client_type=number(c,"clientType");device.version_code=number(c,"versionCode");device.network_type=number(c,"networkType");device.emulator=number(c,"emulator");device.app_flag=number(c,"appFlag");
  h.brand=text(headers,"brand");h.status_bar_dp=number(headers,"statusBarDp");h.include_android_id=required(headers,"includeAndroidId",Json::Kind::boolean).boolean;
  h.environment={text(env,"env"),text(env,"root"),text(env,"xposed"),text(env,"emulator"),text(env,"accessibility"),text(env,"debug"),text(env,"autojs"),text(env,"virtualXposed"),text(env,"x86")};app::environment_json(h.environment);
  h.session.token=text(session,"token");h.session.yw_key=text(session,"ywKey");h.session.yw_guid=text(session,"ywGuid");h.session.app_id=text(session,"appId");h.session.area_id=text(session,"areaId");h.session.language=text(session,"language");h.session.mode=text(session,"mode");h.session.bar=text(session,"bar");
  for(const auto& [key,value]:report.members){
    switch(value.kind){
      case Json::Kind::null_value:out.report.set_null(key);break;
      case Json::Kind::boolean:out.report.set_boolean(key,value.boolean);break;
      case Json::Kind::string:out.report.set_text(key,utf16(bytes(value.text)));break;
      case Json::Kind::number:{
        if(value.text.find_first_of(".eE")==std::string::npos){try{std::size_t used=0;const auto integer=std::stoll(value.text,&used);if(used!=value.text.size())throw std::invalid_argument("Snapshot integer invalid");out.report.set_integer(key,integer);break;}catch(const std::exception&){throw std::invalid_argument("Snapshot integer out of range");}}
        // Selected ibex slots use integer countCAS. Other numeric report fields
        // are metadata; keep their encoded text without rounding identifiers.
        out.report.set_text(key,utf16(bytes(value.text)));break;
      }
      case Json::Kind::array:case Json::Kind::object:out.report.set_text(key,utf16(bytes(value.encode())));break;
    }
  }
  return out;
}
}
