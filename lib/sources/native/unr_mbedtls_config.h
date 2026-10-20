#ifndef UNR_MBEDTLS_CONFIG_H
#define UNR_MBEDTLS_CONFIG_H

// Only the block ciphers needed by the existing App chapter protocols.
#define MBEDTLS_AES_C
#define MBEDTLS_DES_C
#define MBEDTLS_CIPHER_MODE_CBC
#define MBEDTLS_CIPHER_MODE_CTR
// Immutable tables also avoid lazy, shared table initialization across
// isolates.
#define MBEDTLS_AES_ROM_TABLES

#endif
