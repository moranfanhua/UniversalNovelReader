#ifndef UNR_MBEDTLS_CONFIG_H
#define UNR_MBEDTLS_CONFIG_H

// Force-included by the build hook, before Mbed TLS chooses its configuration.
#ifndef MBEDTLS_CONFIG_FILE
#define MBEDTLS_CONFIG_FILE "unr_mbedtls_config.h"
#endif

// Only the block ciphers needed by the existing App chapter protocols.
#define MBEDTLS_AES_C
#define MBEDTLS_DES_C
#define MBEDTLS_CIPHER_MODE_CBC
#define MBEDTLS_CIPHER_MODE_CTR
// Immutable tables also avoid lazy, shared table initialization across
// isolates.
#define MBEDTLS_AES_ROM_TABLES

#endif
