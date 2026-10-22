#include "registration_signature.hpp"
#include "fock_digest.hpp"
namespace qimei::http {
std::string registration_canonical(const RegistrationSignatureFields& fields){
  return "clienttype=1&data="+fields.data+"&qimei="+fields.qimei+"&tstamp="+std::to_string(fields.timestamp_ms)+"&versioncode="+std::to_string(fields.version_code);
}
std::string registration_borgus(const RegistrationSignatureFields& fields){const auto value=registration_canonical(fields);return sn(Input(value.begin(),value.end()));}
}
