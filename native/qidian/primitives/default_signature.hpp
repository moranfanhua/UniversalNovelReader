#pragma once
#include "fock_digest.hpp"

namespace qimei::http {
using Sha256Digest=std::array<std::uint8_t,32>;
Sha256Digest sha256(const Input& input);
// Only the selected APK's bundled API_SIGN script (id 0). A server-provided
// script must be processed separately; it must not silently use this fallback.
// The caller supplies fresh entropy, independent from stable device identity.
// Does not initialize the original SDK or execute JavaScript.
std::string cecelia_default(const Input& canonical,std::uint16_t seed);
}
