#pragma once
#include "qimei_protocol.hpp"
namespace qimei {
// Values supplied by the selected Android SDK's privacy/business providers.
// This is a packet assembler, not a device collector. In particular Android ID,
// OAID and environment results must come from the actual authorized device.
struct AndroidRegisterFields {
  Bytes channel,target_sdk,user_id_json,brand,oaid,android_id;
  Bytes extended_json,sdk_name,device_type,uptime_history,boot_id_history;
};
Record android_register_body(const AndroidRegisterFields& input);
}
