#pragma once
#include "script_crypto.hpp"
#include <cstdint>
#include <map>
namespace qimei::script {
inline constexpr char app_key[]="60256761-e7d0-4406-8254-c6d0bde2c306";
struct SigningScript {std::uint64_t id;Bytes bytecode;};
std::map<std::string,std::string> authorization(const std::string& uid,const std::string& timestamp);
Bytes evaluate(const Bytes& bytecode,const std::string& placeholder={});
Bytes decode(const Bytes& envelope);
std::string sign(const Bytes& bytecode,std::uint64_t id,const Bytes& canonical,std::uint16_t seed);
}
