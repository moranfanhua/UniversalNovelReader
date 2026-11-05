#pragma once
#include "client.hpp"
#include <filesystem>

namespace qimei::client {
class WindowsHttp;
struct WindowsSession {
  std::string device_id,user_id="0",oaid,huawei_referrer,strategy_android_id;
  app::CookieContext cookie;
};
// A persistent, explicitly virtual Android wire profile on a Windows host.
// It does not claim Windows supplies physical Android properties or identifiers.
// All generated identifiers belong to this local installation; QIMEI is never
// generated here and can only be accepted from the registration response.
class WindowsContext {
 public:
  static std::shared_ptr<WindowsContext> open(const std::filesystem::path& directory,bool privacy_agreed,const WindowsSession& session={});
  ~WindowsContext();
  Snapshot collect(const Identifiers& identifiers)const;
  std::shared_ptr<StateStore> state_store()const;
  std::string identity_fingerprint()const;
 private:
  struct Runtime;
  explicit WindowsContext(std::shared_ptr<Runtime> runtime);
  std::shared_ptr<Runtime> runtime_;
};
std::uint64_t system_time_ms();
Profile bundled_protocol();
std::unique_ptr<Client> make_windows_client(const std::shared_ptr<WindowsContext>& context,std::shared_ptr<WindowsHttp> transport={},bool allow_network=true);
}
