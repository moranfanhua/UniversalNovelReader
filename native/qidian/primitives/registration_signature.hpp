#pragma once
#include <cstdint>
#include <string>
namespace qimei::http {
struct RegistrationSignatureFields {
  // Logical FormBody field value, before application/x-www-form-urlencoded.
  std::string data,qimei;
  std::uint32_t version_code=1996;
  std::uint64_t timestamp_ms=0;
};
// Selected App v6.d.cihai, POST with its single `data` field. Keeps bootstrap
// QIMEI empty and later uses the exact cached server-issued value.
std::string registration_canonical(const RegistrationSignatureFields& fields);
std::string registration_borgus(const RegistrationSignatureFields& fields);
}
