#pragma once
#include "app_headers.hpp"
#include "qimei_provider.hpp"
#include "ibex_generator.hpp"
#include <memory>

namespace qimei::client {
struct Snapshot {
  DeviceSnapshot registration;
  app::HeaderContext headers;
  ibex::Report report;
};
struct SignedRequest {
  std::string path="/argus/api/v1/client/ostar";
  app::Headers headers;
  std::string form_body;
};
using Collector=std::function<Snapshot(const Identifiers&)>;
using Send=std::function<AppReply(const SignedRequest&)>;
using Cancel=std::function<void()>;
using EncodeIbex=std::function<std::string(ibex::Report&,std::int64_t)>;
enum class Stage {idle,collect,encode,sign,transport,complete};
struct Result {
  ProviderResult provider;
  std::string ibex;
  bool from_cache=false;
  Stage stage=Stage::idle;
  // The selected SDK accepts a nonempty Q16 or Q36; completeness is separate.
  bool ready()const{return provider.ready()&&!provider.identifiers.empty()&&!ibex.empty();}
  bool pair_complete()const{return provider.identifiers.complete();}
};
std::string form_encode(const std::string& logical);
std::u16string utf16(const Bytes& encoded);

// Owns one identity/cache lifecycle. Collection and request signing use the
// same snapshot. QIMEI is only accepted from the decoded server response.
class Client {
 public:
  Client(Profile protocol,Bytes app_key,std::shared_ptr<StateStore> store,Collector collect,app::Encrypt encrypt,EncodeIbex encode,Send send,Cancel cancel,Clock clock);
  ~Client();
  Client(const Client&)=delete;
  Client& operator=(const Client&)=delete;
  Result ensure(bool privacy_agreed,bool force_refresh=false);
  app::Headers prepare(const std::map<std::string,std::string>& fields,const app::CookieContext& session,const std::string& user_id);
  ProviderResult note_risk();
  void close();
  Identifiers current()const;
  std::string current_ibex()const;
  ProviderStatus gate_status()const;
  void install_script(std::uint64_t id,const Bytes& envelope);
 private:
  struct Runtime;
  std::shared_ptr<Runtime> runtime_;
  std::unique_ptr<Provider> provider_;
};
}
