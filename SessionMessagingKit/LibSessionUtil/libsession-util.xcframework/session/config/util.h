#pragma once

#ifdef __cplusplus
extern "C" {
#endif

#include <stdbool.h>

/// Returns true if session_id has the right form (66 hex digits).  This is a quick check, not a
/// robust one: it does not check the leading byte prefix, nor the cryptographic properties of the
/// pubkey for actual validity.
bool session_id_is_valid(const char* session_id);

#ifdef __cplusplus
}
#endif
