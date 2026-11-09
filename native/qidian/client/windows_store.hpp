#pragma once
#include "qimei_provider.hpp"
#include <filesystem>
#include <mutex>
#include <optional>

namespace qimei::client {
// Current-user, application-owned registry namespace, derived from the caller's
// canonical private directory. Each checksummed snapshot
// contains identity and the whole cache; failed/torn snapshots are retained and
// rejected, never silently rolled back into an older risk state.
class WindowsStore final:public StateStore {
 public:
  explicit WindowsStore(const std::filesystem::path& directory);
  std::optional<std::string> identity_json();
  bool state_present();
  void initialize(const std::string& identity,const StoredState& state);
  StoredState read()override;
  bool save(const StoredState& state)override;
  // Storage metadata, not device identity. Do not include it in request logs.
  const std::wstring& registry_subkey()const{return subkey_;}
 private:
  std::wstring subkey_;
  std::mutex mutex_;
};
}
