#pragma once
#include "qimei_protocol.hpp"
#include <cstdint>
#include <string>

namespace qimei {
struct DecodedResponse {
  std::int32_t native_error=0;
  std::int64_t service_code=0;
  Bytes body;
  bool succeeded()const{return native_error==0;}
};
struct Identifiers {
  Bytes qimei,qimei36;
  bool empty()const{return qimei.empty()&&qimei36.empty();}
  bool complete()const{return !qimei.empty()&&!qimei36.empty();}
  bool operator==(const Identifiers& other)const{return qimei==other.qimei&&qimei36==other.qimei36;}
};
// Input is the SDK transport bridge object (is/bd/ic/rc/em), before the native decoder.
DecodedResponse decode_transport_response(const std::string& transport,const SessionKey& request_key);
// REGISTER response bytes: wire type 0 becomes the SDK's signed 32-bit integer;
// wire type 2 retains the original byte string.
Record decode_body(const Bytes& protobuf);
Identifiers identifiers_from_body(const Bytes& protobuf);
// App API's outer ServerResponse.data is unwrapped exactly once.
std::string sdk_transport_response(const std::string& app_data);
}
