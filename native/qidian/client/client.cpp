#include "client.hpp"
#include "qimei_crypto.hpp"
#include "qimei_json.hpp"
#include <algorithm>
#include <mutex>
#include <optional>
#include <stdexcept>

namespace qimei::client {
namespace {
std::string text(const Bytes& value){return {value.begin(),value.end()};}
void bind(Snapshot& snapshot,const Identifiers& ids){
  snapshot.headers.device.qimei16=text(ids.qimei);snapshot.headers.device.qimei36=text(ids.qimei36);
  snapshot.report.set_text("qimei",utf16(ids.qimei));snapshot.report.set_text("qimei36",utf16(ids.qimei36));
  snapshot.report.set_text("guid",utf16(bytes(snapshot.headers.session.yw_guid)));
}
void validate(const Snapshot& snapshot){
  const auto& c=snapshot.headers.device;const auto& common=snapshot.registration.common;
  if(c.device.empty()||c.model.empty()||c.version.empty()||snapshot.headers.brand.empty()||common.model!=bytes(c.model))throw std::invalid_argument("Device/header snapshot is inconsistent");
  const auto version=c.version+'.'+std::to_string(c.version_code);
  const auto os=text(common.os_version),prefix="Android "+c.os_release+",level ";
  if(common.app_version!=bytes(version)||os.compare(0,prefix.size(),prefix)!=0||os.size()==prefix.size()||os.find_first_not_of("0123456789",prefix.size())!=std::string::npos)throw std::invalid_argument("Application profile snapshot is inconsistent");
  const auto report=snapshot.registration.report.find(3);
  if(report!=snapshot.registration.report.end())if(const auto* value=std::get_if<Bytes>(&report->second);value&&!value->empty()){
    const auto object=Json::parse(text(*value));const auto* user=object.find("userId");if(user&&(user->kind!=Json::Kind::string||user->text!=c.user_id))throw std::invalid_argument("Account snapshot is inconsistent");
  }
  // Required measurements are checked before any transport callback can run.
  app::environment_json(snapshot.headers.environment);
}
}
std::string form_encode(const std::string& logical){
  // OkHttp FormBody.Builder.add, UTF-8, once. It encodes spaces as %20 and
  // literal plus/percent signs as %2B/%25; '*' remains unescaped, '~' does not.
  constexpr char symbols[]="0123456789ABCDEF";
  const std::string encoded_set=" \"':;<=>@[]^`{}|/\\?#&!$(),~%+";std::string out;
  for(const auto ch:bytes(logical)){if(ch<0x20||ch>=0x7f||encoded_set.find(char(ch))!=std::string::npos){out+='%';out+=symbols[ch>>4];out+=symbols[ch&15];}else out+=char(ch);}return out;
}
std::u16string utf16(const Bytes& encoded){
  std::u16string out;
  for(std::size_t i=0;i<encoded.size();){
    const auto first=encoded[i++];std::uint32_t point=first;unsigned remaining=0;
    if(first>=0xc2&&first<=0xdf){point=first&31;remaining=1;}
    else if(first>=0xe0&&first<=0xef){point=first&15;remaining=2;}
    else if(first>=0xf0&&first<=0xf4){point=first&7;remaining=3;}
    else if(first>=0x80)throw std::invalid_argument("Identifier UTF-8 invalid");
    if(i+remaining>encoded.size())throw std::invalid_argument("Identifier UTF-8 truncated");
    for(unsigned n=0;n<remaining;++n){const auto next=encoded[i++];if((next&0xc0)!=0x80)throw std::invalid_argument("Identifier UTF-8 continuation invalid");point=(point<<6)|(next&63);}
    if((remaining==1&&point<0x80)||(remaining==2&&point<0x800)||(remaining==3&&point<0x10000)||point>0x10ffff)throw std::invalid_argument("Identifier UTF-8 scalar invalid");
    if(point<0x10000)out.push_back(char16_t(point));else{point-=0x10000;out.push_back(char16_t(0xd800+(point>>10)));out.push_back(char16_t(0xdc00+(point&1023)));}
  }return out;
}
struct Client::Runtime {
  mutable std::mutex state;std::mutex operation;bool closed=false;Stage stage=Stage::idle;
  Collector collect;app::Encrypt encrypt;EncodeIbex encode;Send send;Cancel cancel;Clock clock;
  std::optional<Snapshot> pending;std::string ibex;Identifiers encoded_ids;
};
Client::Client(Profile protocol,Bytes app_key,std::shared_ptr<StateStore> store,Collector collect,app::Encrypt encrypt,EncodeIbex encode,Send send,Cancel cancel,Clock clock):runtime_(std::make_shared<Runtime>()){
  if(!collect||!encrypt||!encode||!send||!cancel||!clock)throw std::invalid_argument("QIMEI client configuration missing");
  auto r=runtime_;r->collect=std::move(collect);r->encrypt=std::move(encrypt);r->encode=std::move(encode);r->send=std::move(send);r->cancel=std::move(cancel);r->clock=std::move(clock);
  provider_=std::make_unique<Provider>(std::move(protocol),std::move(app_key),std::move(store),r->clock,[r](const Identifiers& ids){
    Snapshot updated;
    {std::lock_guard<std::mutex> guard(r->state);if(r->closed||!r->pending)throw std::runtime_error("QIMEI refresh superseded");updated=*r->pending;r->ibex.clear();}
    bind(updated,ids);const auto token=r->encode(updated.report,std::int64_t(r->clock()));if(token.empty())throw std::runtime_error("Ibex encoder returned no parameter");
    std::lock_guard<std::mutex> guard(r->state);if(r->closed)throw std::runtime_error("QIMEI refresh superseded");r->pending=std::move(updated);r->ibex=token;r->encoded_ids=ids;
  });
}
Client::~Client(){close();}
void Client::close(){auto r=runtime_;{std::lock_guard<std::mutex> guard(r->state);if(r->closed)return;r->closed=true;}provider_->close();try{r->cancel();}catch(...){} }
Identifiers Client::current()const{return provider_->current();}
std::string Client::current_ibex()const{if(provider_->gate_status()!=ProviderStatus::ready)return {};std::lock_guard<std::mutex> guard(runtime_->state);const auto ids=provider_->current();return runtime_->closed||ids.empty()||!(runtime_->encoded_ids==ids)?std::string():runtime_->ibex;}
ProviderResult Client::note_risk(){return provider_->note_risk();}
app::Headers Client::prepare(const std::map<std::string,std::string>& fields,const app::CookieContext& session,const std::string& user_id){
  auto r=runtime_;std::unique_lock<std::mutex> operation(r->operation);
  if(user_id.empty()||user_id.find_first_not_of("0123456789")!=std::string::npos||provider_->gate_status()!=ProviderStatus::ready)throw std::runtime_error("Client request unavailable");
  const auto ids=provider_->current();Snapshot snapshot;
  {std::lock_guard<std::mutex> guard(r->state);if(r->closed||!r->pending||ids.empty()||!(r->encoded_ids==ids))throw std::runtime_error("Client snapshot unavailable");snapshot=*r->pending;}
  snapshot.headers.session=session;snapshot.headers.device.user_id=user_id;bind(snapshot,ids);
  const auto stamp=r->clock();snapshot.headers.timestamp_ms=stamp;snapshot.headers.cookie_timestamp_ms=stamp;std::array<std::uint8_t,2> entropy{};crypto::random(entropy.data(),entropy.size());snapshot.headers.cecelia_seed=std::uint16_t(entropy[0]|(std::uint16_t(entropy[1])<<8));
  const auto token=r->encode(snapshot.report,std::int64_t(stamp));if(token.empty())throw std::runtime_error("Client report unavailable");
  auto headers=app::request_headers(fields,snapshot.headers,r->encrypt,token);
  std::lock_guard<std::mutex> guard(r->state);if(r->closed||provider_->gate_status()!=ProviderStatus::ready)throw std::runtime_error("Client request superseded");return headers;
}
Result Client::ensure(bool consent,bool force){
  auto r=runtime_;std::unique_lock<std::mutex> operation(r->operation,std::try_to_lock);
  const auto output=[&](ProviderResult result,bool cached=false){std::lock_guard<std::mutex> guard(r->state);if(r->closed)result.status=ProviderStatus::closed;return Result{result,result.ready()?r->ibex:std::string(),cached,r->stage};};
  if(!operation.owns_lock())return output({ProviderStatus::busy,provider_->current(),0,0});
  if(!consent)return output({ProviderStatus::privacy_required,provider_->current(),0,0});
  const auto gate=provider_->gate_status();if(gate!=ProviderStatus::ready)return output({gate,provider_->current(),gate==ProviderStatus::cooldown?-4403:0,0});
  const auto stage=[&](Stage value){std::lock_guard<std::mutex> guard(r->state);r->stage=value;if(r->closed)throw std::runtime_error("QIMEI operation closed");};
  const auto collect_snapshot=[&](const Identifiers& ids){stage(Stage::collect);auto snapshot=r->collect(ids);bind(snapshot,ids);validate(snapshot);return snapshot;};
  const auto cached=provider_->current();
  if(!cached.empty()&&!force){
    try{auto snapshot=collect_snapshot(cached);stage(Stage::encode);const auto token=r->encode(snapshot.report,std::int64_t(r->clock()));if(token.empty())throw std::runtime_error("Ibex parameter unavailable");{std::lock_guard<std::mutex> guard(r->state);if(r->closed)throw std::runtime_error("QIMEI operation closed");r->pending=std::move(snapshot);r->ibex=token;r->encoded_ids=cached;r->stage=Stage::complete;}return output({ProviderStatus::ready,cached,0,0},true);}
    catch(const std::exception&){return output({ProviderStatus::refresh_failed,provider_->current(),0,0},true);}
  }
  const auto result=provider_->register_now([&](const Identifiers& ids){auto snapshot=collect_snapshot(ids);auto registration=snapshot.registration;std::lock_guard<std::mutex> guard(r->state);r->pending=std::move(snapshot);return registration;},[&](const AppRequest& request){
    Snapshot snapshot;{std::lock_guard<std::mutex> guard(r->state);if(r->closed||!r->pending)throw std::runtime_error("QIMEI request superseded");snapshot=*r->pending;}
    stage(Stage::encode);const auto timestamp=r->clock();const auto token=r->encode(snapshot.report,std::int64_t(timestamp));if(token.empty())throw std::runtime_error("Ibex request parameter unavailable");
    std::array<std::uint8_t,2> entropy{};crypto::random(entropy.data(),entropy.size());snapshot.headers.timestamp_ms=timestamp;snapshot.headers.cookie_timestamp_ms=timestamp;snapshot.headers.cecelia_seed=std::uint16_t(entropy[0]|(std::uint16_t(entropy[1])<<8));
    if(request.path!="/argus/api/v1/client/ostar"||request.form.size()!=1||request.form.count("data")!=1)throw std::runtime_error("QIMEI transport boundary invalid");
    stage(Stage::sign);const auto& logical=request.form.at("data");SignedRequest signed_request{request.path,app::registration_headers(logical,snapshot.headers,r->encrypt,token),"data="+form_encode(logical)};
    stage(Stage::transport);return r->send(signed_request);
  },true);
  if(result.ready()){std::lock_guard<std::mutex> guard(r->state);r->stage=Stage::complete;}
  return output(result);
}
}
