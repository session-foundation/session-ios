#pragma once

#ifdef __cplusplus
extern "C" {
#endif

#include <stddef.h>

typedef struct user_profile_pic {
    // Null-terminated C string containing the uploaded URL of the pic.  Will be NULL if there is no
    // profile pic.
    const char* url;
    // The profile pic decryption key, in bytes.  This is a byte buffer of length `keylen`, *not* a
    // null-terminated C string.  Will be NULL if there is no profile pic.
    const unsigned char* key;
    size_t keylen;
} user_profile_pic;

#ifdef __cplusplus
}
#endif
