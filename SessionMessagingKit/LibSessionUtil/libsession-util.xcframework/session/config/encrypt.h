#pragma once

#ifdef __cplusplus
extern "C" {
#endif

#include <stddef.h>

/// Wrapper around session::config::encrypt.  message and key_base are binary: message has the
/// length provided, key_base must be exactly 32 bytes.  domain is a c string.  Returns a newly
/// allocated buffer containing the encrypted data, and sets the data's length into
/// `ciphertext_size`.  It is the caller's responsibility to `free()` the returned buffer!
///
/// Returns nullptr on error.
unsigned char* config_encrypt(
        const unsigned char* message,
        size_t mlen,
        const unsigned char* key_base,
        const char* domain,
        size_t* ciphertext_size);

/// Works just like config_encrypt, but in reverse.
unsigned char* config_decrypt(
        const unsigned char* ciphertext,
        size_t clen,
        const unsigned char* key_base,
        const char* domain,
        size_t* plaintext_size);

/// Returns the amount of padding needed for a plaintext of size s with encryption overhead
/// `overhead`.
size_t config_padded_size(size_t s, size_t overhead);

#ifdef __cplusplus
}
#endif
