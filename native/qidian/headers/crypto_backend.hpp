#pragma once
#if defined(QIMEI_USE_CNG) && QIMEI_USE_CNG
#include "crypto_cng.hpp"
namespace qimei::app {inline constexpr auto platform_encrypt=cng_encrypt;}
#else
#include "crypto_openssl.hpp"
namespace qimei::app {inline constexpr auto platform_encrypt=openssl_encrypt;}
#endif
