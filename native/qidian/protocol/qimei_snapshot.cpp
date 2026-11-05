#include "qimei_snapshot.hpp"
#include "qimei_json.hpp"
#include <stdexcept>
namespace qimei {
namespace {
Bytes string_field(const Json& object,const std::string& key){
  const auto* value=object.find(key);if(!value||value->kind!=Json::Kind::string)throw std::runtime_error("QIMEI Android snapshot string unavailable");
  // JSON escaped NUL becomes an actual code unit; JNI re-encodes it as C0 80.
  // Surrogate handling follows the collector runtime's already encoded text.
  Bytes out;for(const auto ch:value->text){if(ch==0){out.push_back(0xc0);out.push_back(0x80);}else out.push_back(std::uint8_t(ch));}return out;
}
}
DeviceSnapshot snapshot_from_android_json(const std::string& encoded){
  const auto root=Json::parse(encoded);const auto* common=root.find("common");const auto* report=root.find("report");
  if(!common||!report||common->kind!=Json::Kind::object||report->kind!=Json::Kind::object)throw std::runtime_error("QIMEI Android snapshot structure invalid");
  DeviceSnapshot out;out.common.app_key=string_field(*common,"appKey");out.common.sdk_version=string_field(*common,"sdkVersion");out.common.app_version=string_field(*common,"appVersion");out.common.os_version=string_field(*common,"osVersion");out.common.process_name=string_field(*common,"processName");out.common.network=string_field(*common,"network");out.common.model=string_field(*common,"model");
  if(out.common.app_key.empty()||out.common.process_name.empty())throw std::runtime_error("QIMEI Android snapshot identity unavailable");
  for(unsigned number=1;number<=16;++number)out.report[number]=string_field(*report,std::to_string(number));
  return out;
}
}
