#pragma once
#include "qimei_response.hpp"
#include <functional>
#include <memory>
#include <string>

namespace qimei {
struct StoredState {
  Bytes app_key;
  Identifiers identifiers;
  std::uint64_t risk_until_ms=0;
};
class StateStore {
 public:
  virtual ~StateStore()=default;
  virtual StoredState read()=0;
  // Implementations must replace their state atomically or report failure.
  virtual bool save(const StoredState& state)=0;
};
struct DeviceSnapshot {
  CommonInfo common;
  Record report;
};
struct AppRequest {
  std::string path="/argus/api/v1/client/ostar";
  std::map<std::string,std::string> form;
};
struct AppReply {int http_status=0;std::string body;};
using Transport=std::function<AppReply(const AppRequest&)>;
using Collector=std::function<DeviceSnapshot(const Identifiers&)>;
using Clock=std::function<std::uint64_t()>;
using IdentifiersChanged=std::function<void(const Identifiers&)>;
enum class ProviderStatus {
  ready,busy,closed,cooldown,privacy_required,transport_failed,http_rejected,
  app_rejected,invalid_response,empty_identifiers,store_failed,refresh_failed
};
struct ProviderResult {
  ProviderStatus status=ProviderStatus::invalid_response;
  Identifiers identifiers;
  std::int64_t service_code=0;
  std::int32_t native_error=0;
  bool ready()const{return status==ProviderStatus::ready;}
};
// Protocol/client implementation, independent of the original SDK. Device reads,
// App API authentication/challenges and UI remain the application's responsibilities.
class Provider {
 public:
  Provider(Profile profile,Bytes app_key,std::shared_ptr<StateStore> store,Clock clock,IdentifiersChanged changed);
  ~Provider();
  Provider(const Provider&)=delete;
  Provider& operator=(const Provider&)=delete;
  Identifiers current()const;
  // Read-only gate for callers serving cached identifiers. A ready gate means
  // operations are permitted; it does not mean a QIMEI pair has been issued.
  ProviderStatus gate_status()const;
  ProviderResult register_now(const Collector& collect,const Transport& transport,bool privacy_agreed);
  ProviderResult note_risk();
  void close();
 private:
  struct Runtime;
  std::shared_ptr<Runtime> runtime_;
};
// Adds the pair to a copy of an already authorized report. No account or
// environment field is generated or replaced here.
using IbexFields=std::map<std::string,std::string>;
IbexFields with_identifiers(IbexFields report,const Identifiers& ids);
}
