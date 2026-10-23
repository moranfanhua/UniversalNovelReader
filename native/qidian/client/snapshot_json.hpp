#pragma once
#include "client.hpp"
namespace qimei::client {
// Application-owned DTO. Errors never include field contents. The registration
// subtree is AndroidSnapshot's existing common/report shape; other subtrees
// carry the same explicitly captured header and ibex context.
Snapshot snapshot_from_json(const std::string& encoded);
}
