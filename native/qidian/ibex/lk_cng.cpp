#include "lk.hpp"
#include "app_headers.hpp"
#include "crypto_cng.hpp"
namespace nib {
std::optional<Bytes> lk(const Bytes& input){if(input.empty()||input.front()==0)return std::nullopt;return qimei::app::fock_lock(input,qimei::app::cng_encrypt);}
std::optional<Bytes> lk(std::string_view input){return lk(Bytes(input.begin(),input.end()));}
std::optional<Bytes> lk(const char* input){if(!input)return std::nullopt;return lk(std::string_view(input));}
}
