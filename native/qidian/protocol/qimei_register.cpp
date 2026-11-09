#include "qimei_register.hpp"
namespace qimei {
Record android_register_body(const AndroidRegisterFields& input){
  // com.ola.star.aj.f.a(String), selected SDK 5.1.2.28-yw.
  // 5 is reserved; 7/8/10/11 invoke empty implementations in this APK.
  return {{1,input.channel},{2,input.target_sdk},{3,input.user_id_json},{4,input.brand},
    {5,Bytes{}},{6,input.oaid},{7,Bytes{}},{8,Bytes{}},{9,input.android_id},
    {10,Bytes{}},{11,Bytes{}},{12,input.extended_json},{13,input.sdk_name},
    {14,input.device_type},{15,input.uptime_history},{16,input.boot_id_history}};
}
}
