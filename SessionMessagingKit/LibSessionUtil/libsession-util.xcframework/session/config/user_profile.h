#pragma once

#ifdef __cplusplus
extern "C" {
#endif

#include "base.h"
#include "profile_pic.h"

/// Constructs a user profile config object and sets a pointer to it in `conf`.
///
/// \param ed25519_secretkey must be the 32-byte secret key seed value.  (You can also pass the
/// pointer to the beginning of the 64-byte value libsodium calls the "secret key" as the first 32
/// bytes of that are the seed).  This field cannot be null.
///
/// \param dump - if non-NULL this restores the state from the dumped byte string produced by a past
/// instantiation's call to `dump()`.  To construct a new, empty profile this should be NULL.
///
/// \param dumplen - the length of `dump` when restoring from a dump, or 0 when `dump` is NULL.
///
/// \param error - the pointer to a buffer in which we will write an error string if an error
/// occurs; error messages are discarded if this is given as NULL.  If non-NULL this must be a
/// buffer of at least 256 bytes.
///
/// Returns 0 on success; returns a non-zero error code and write the exception message as a
/// C-string into `error` (if not NULL) on failure.
///
/// When done with the object the `config_object` must be destroyed by passing the pointer to
/// config_free() (in `session/config/base.h`).
int user_profile_init(
        config_object** conf,
        const unsigned char* ed25519_secretkey,
        const unsigned char* dump,
        size_t dumplen,
        char* error) __attribute__((warn_unused_result));

/// Returns a pointer to the currently-set name (null-terminated), or NULL if there is no name at
/// all.  Should be copied right away as the pointer may not remain valid beyond other API calls.
const char* user_profile_get_name(const config_object* conf);

/// Sets the user profile name to the null-terminated C string.  Returns 0 on success, non-zero on
/// error (and sets the config_object's error string).
int user_profile_set_name(config_object* conf, const char* name);

// Obtains the current profile pic.  The pointers in the returned struct will be NULL if a profile
// pic is not currently set, and otherwise should be copied right away (they will not be valid
// beyond other API calls on this config object).
user_profile_pic user_profile_get_pic(const config_object* conf);

// Sets a user profile
int user_profile_set_pic(config_object* conf, user_profile_pic pic);

// Gets the current note-to-self priority level. Will always be >= 0.
int user_profile_get_nts_priority(const config_object* conf);

// Sets the current note-to-self priority level. Should be >= 0 (negatives will be set to 0).
void user_profile_set_nts_priority(config_object* conf, int priority);

#ifdef __cplusplus
}  // extern "C"
#endif
