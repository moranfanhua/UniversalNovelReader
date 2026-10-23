#pragma once
#include "qimei_provider.hpp"
#include <filesystem>
#include <mutex>

namespace qimei {
// Use a path in the calling application's own private data directory.
// The file contains identifiers and is not an account/session store.
class FileStateStore final:public StateStore {
 public:
  explicit FileStateStore(std::filesystem::path path);
  StoredState read()override;
  bool save(const StoredState& state)override;
 private:
  std::filesystem::path path_;
  std::mutex mutex_;
};
}
