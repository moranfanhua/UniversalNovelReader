#include "qimei_provider.hpp"
#include "qimei_json.hpp"
#include <algorithm>
#include <limits>
#include <mutex>
#include <stdexcept>
#include <utility>

namespace qimei {
namespace {
std::string text(const Bytes& value){return std::string(value.begin(),value.end());}
std::uint64_t after(std::uint64_t now,std::uint64_t wait){return now>std::numeric_limits<std::uint64_t>::max()-wait?std::numeric_limits<std::uint64_t>::max():now+wait;}
bool same(const Identifiers& left,const Identifiers& right){return left==right;}
bool risk_response(std::string text){
  for(unsigned depth=0;depth<2;++depth){
    Json value;try{value=Json::parse(text);}catch(const std::exception&){return false;}
    const auto* code=value.find("code");if(code&&code->integer()==-4403)return true;
    const auto* data=value.find("data");if(!data||data->kind!=Json::Kind::string)return false;text=data->text;
  }
  return false;
}
bool usable(const Bytes& value){
  if(value.empty()||std::all_of(value.begin(),value.end(),[](std::uint8_t c){return c<=0x20;}))return false;
  if(value.size()!=4)return true;
  return !((value[0]=='n'||value[0]=='N')&&(value[1]=='u'||value[1]=='U')&&(value[2]=='l'||value[2]=='L')&&(value[3]=='l'||value[3]=='L'));
}
class RequestKey {
 public:
  SessionKey value=random_session_key();
  ~RequestKey(){volatile std::uint8_t* pointer=value.data();for(std::size_t i=0;i<value.size();++i)pointer[i]=0;}
};
}
struct Provider::Runtime {
  Profile profile;Bytes app_key;std::shared_ptr<StateStore> store;Clock clock;IdentifiersChanged changed;
  mutable std::mutex mutex;std::recursive_mutex delivery;StoredState state;bool closed=false,inflight=false;
  std::uint64_t epoch=0;std::uint32_t sequence=0;Bytes installation_uin;
  ProviderResult result(ProviderStatus status,std::int64_t service=0,std::int32_t native=0)const{return {status,state.identifiers,service,native};}
};
Provider::Provider(Profile profile,Bytes app_key,std::shared_ptr<StateStore> store,Clock clock,IdentifiersChanged changed):runtime_(std::make_shared<Runtime>()){
  if(app_key.empty()||!store||!clock||!changed)throw std::invalid_argument("QIMEI provider configuration is incomplete");
  auto& runtime=*runtime_;runtime.profile=std::move(profile);runtime.app_key=std::move(app_key);runtime.store=std::move(store);runtime.clock=std::move(clock);runtime.changed=std::move(changed);
  runtime.state=runtime.store->read();
  if(!runtime.state.app_key.empty()&&runtime.state.app_key!=runtime.app_key)throw std::runtime_error("QIMEI state belongs to another application profile");
  runtime.state.app_key=runtime.app_key;
}
Provider::~Provider(){close();}
Identifiers Provider::current()const{auto runtime=runtime_;std::lock_guard<std::mutex> lock(runtime->mutex);return runtime->state.identifiers;}
ProviderStatus Provider::gate_status()const{auto runtime=runtime_;std::lock_guard<std::mutex> lock(runtime->mutex);if(runtime->closed)return ProviderStatus::closed;if(runtime->inflight)return ProviderStatus::busy;if(runtime->clock()<runtime->state.risk_until_ms)return ProviderStatus::cooldown;return ProviderStatus::ready;}
ProviderResult Provider::note_risk(){
  auto r=runtime_;std::lock_guard<std::mutex> lock(r->mutex);if(r->closed)return r->result(ProviderStatus::closed);
  ++r->epoch;r->state.risk_until_ms=std::max(r->state.risk_until_ms,after(r->clock(),600000));
  try{if(!r->store->save(r->state))return r->result(ProviderStatus::store_failed,-4403);}catch(...){return r->result(ProviderStatus::store_failed,-4403);}
  return r->result(ProviderStatus::cooldown,-4403);
}
void Provider::close(){auto runtime=runtime_;std::lock_guard<std::recursive_mutex> delivery(runtime->delivery);std::lock_guard<std::mutex> lock(runtime->mutex);runtime->closed=true;++runtime->epoch;}
ProviderResult Provider::register_now(const Collector& collect,const Transport& transport,bool privacy_agreed){
  auto runtime=runtime_;Identifiers cached;std::uint64_t epoch=0;std::int32_t sequence=0;
  {
    std::lock_guard<std::mutex> lock(runtime->mutex);
    if(runtime->closed)return runtime->result(ProviderStatus::closed);
    if(!privacy_agreed)return runtime->result(ProviderStatus::privacy_required);
    if(runtime->inflight)return runtime->result(ProviderStatus::busy);
    if(runtime->clock()<runtime->state.risk_until_ms)return runtime->result(ProviderStatus::cooldown,-4403);
    runtime->inflight=true;epoch=runtime->epoch;cached=runtime->state.identifiers;
    ++runtime->sequence;sequence=runtime->sequence<=0x7fffffff?std::int32_t(runtime->sequence):std::int32_t(std::int64_t(runtime->sequence)-0x100000000LL);
  }
  struct Finished {std::shared_ptr<Runtime> runtime;~Finished(){std::lock_guard<std::mutex> lock(runtime->mutex);runtime->inflight=false;}} finished{runtime};
  const auto fail=[&](ProviderStatus status,std::int64_t service=0,std::int32_t native=0){std::lock_guard<std::mutex> lock(runtime->mutex);return runtime->result(runtime->closed||runtime->epoch!=epoch?ProviderStatus::closed:status,service,native);};
  AppReply reply;std::unique_ptr<RequestKey> request_key;
  try{
    request_key=std::make_unique<RequestKey>();
    auto snapshot=collect(cached);
    if(snapshot.common.app_key!=runtime->app_key)return fail(ProviderStatus::invalid_response);
    snapshot.common.command=1;snapshot.common.qimei=cached.qimei;snapshot.common.qimei36=cached.qimei36;snapshot.common.sequence=sequence;
    if(snapshot.common.installation_uin.empty()){
      std::lock_guard<std::mutex> lock(runtime->mutex);
      if(runtime->installation_uin.empty())runtime->installation_uin=bytes(std::to_string(runtime->clock())+random_nonce());
      snapshot.common.installation_uin=runtime->installation_uin;
    }
    const auto body=encode_body(snapshot.report);
    if(body.empty())return fail(ProviderStatus::invalid_response);
    const auto pms=seal_payload(encode_frame(snapshot.common,body),request_key->value,runtime->profile);
    const auto key=encrypt_request_key(request_key->value,runtime->profile),time=std::to_string(runtime->clock()),nonce=random_nonce();
    const auto sign=signature(signature_input(1,key,pms,time,nonce),runtime->clock(),runtime->profile.signature_salt);
    const auto envelope=Json::object({{"cpt",Json::string("1")},{"ext",Json::string("")},{"ky",Json::string(key)},{"nn",Json::string(nonce)},{"pms",Json::string(pms)},{"sn",Json::string(sign)},{"tm",Json::string(time)}}).encode();
    {std::lock_guard<std::mutex> lock(runtime->mutex);if(runtime->closed||runtime->epoch!=epoch)return runtime->result(ProviderStatus::closed);}
    reply=transport(AppRequest{"/argus/api/v1/client/ostar",{{"data",envelope}}});
  }catch(const std::exception&){return fail(ProviderStatus::transport_failed);}
  if(reply.http_status<200||reply.http_status>=300)return fail(ProviderStatus::http_rejected,reply.http_status);
  std::string app_data;std::int64_t app_code=0;DecodedResponse decoded;
  try{
    // ServerResponse uses Gson @SerializedName("Result") / @SerializedName("Data").
    // Lowercase code/data belong exclusively to the nested SDK response.
    const auto outer=Json::parse(reply.body);const auto* code=outer.find("Result");
    if(!code||code->kind!=Json::Kind::number)return fail(ProviderStatus::invalid_response);
    app_code=code->integer(std::numeric_limits<std::int64_t>::min());
    if(app_code==std::numeric_limits<std::int64_t>::min())return fail(ProviderStatus::invalid_response);
    const auto* data=outer.find("Data");
    if(data){
      if(data->kind==Json::Kind::string)app_data=data->text;
      else if(data->kind==Json::Kind::number)app_data=data->text;
      else if(data->kind==Json::Kind::boolean)app_data=data->boolean?"true":"false";
      else if(data->kind!=Json::Kind::null_value)return fail(ProviderStatus::invalid_response);
    }
    if(app_code==-4403||risk_response(app_data))decoded.service_code=-4403;
    else decoded=decode_transport_response(sdk_transport_response(app_data),request_key->value);
  }catch(const std::exception&){return fail(ProviderStatus::invalid_response);}
  if(app_code==-4403||decoded.service_code==-4403){
    std::lock_guard<std::mutex> lock(runtime->mutex);if(runtime->closed||runtime->epoch!=epoch)return runtime->result(ProviderStatus::closed);
    auto next=runtime->state;next.risk_until_ms=after(runtime->clock(),600000);runtime->state.risk_until_ms=next.risk_until_ms;
    try{if(!runtime->store->save(next))return runtime->result(ProviderStatus::store_failed,-4403,decoded.native_error);}catch(const std::exception&){return runtime->result(ProviderStatus::store_failed,-4403,decoded.native_error);}
    return runtime->result(ProviderStatus::cooldown,-4403,decoded.native_error);
  }
  if(app_code!=0)return fail(ProviderStatus::app_rejected,app_code,decoded.native_error);
  if(!decoded.succeeded())return fail(ProviderStatus::invalid_response,decoded.service_code,decoded.native_error);
  Identifiers incoming;
  try{incoming=identifiers_from_body(decoded.body);}catch(const std::exception&){return fail(ProviderStatus::invalid_response);}
  if(!usable(incoming.qimei))incoming.qimei.clear();
  if(!usable(incoming.qimei36))incoming.qimei36.clear();
  if(incoming.empty())return fail(ProviderStatus::empty_identifiers);
  Identifiers updated;
  {
    std::lock_guard<std::mutex> lock(runtime->mutex);if(runtime->closed||runtime->epoch!=epoch)return runtime->result(ProviderStatus::closed);
    auto next=runtime->state;if(!incoming.qimei.empty())next.identifiers.qimei=incoming.qimei;if(!incoming.qimei36.empty())next.identifiers.qimei36=incoming.qimei36;next.risk_until_ms=0;
    try{if(!runtime->store->save(next))return runtime->result(ProviderStatus::store_failed);}catch(const std::exception&){return runtime->result(ProviderStatus::store_failed);}
    runtime->state=std::move(next);updated=runtime->state.identifiers;
  }
  {
    std::lock_guard<std::recursive_mutex> delivery(runtime->delivery);
    {std::lock_guard<std::mutex> lock(runtime->mutex);if(runtime->closed||runtime->epoch!=epoch||!same(runtime->state.identifiers,updated))return runtime->result(ProviderStatus::closed);}
    try{runtime->changed(updated);}catch(const std::exception&){return fail(ProviderStatus::refresh_failed);}
  }
  return fail(ProviderStatus::ready);
}
IbexFields with_identifiers(IbexFields report,const Identifiers& ids){report["qimei"]=text(ids.qimei);report["qimei36"]=text(ids.qimei36);return report;}
}
