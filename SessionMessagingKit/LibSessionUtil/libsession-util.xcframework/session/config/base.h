#pragma once

#ifdef __cplusplus
extern "C" {
#endif

#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>

#include "../config.h"

// Config object base type: this type holds the internal object and is initialized by the various
// config-dependent settings (e.g. config_user_profile_init) then passed to the various functions.
typedef struct config_object {
    // Internal opaque object pointer; calling code should leave this alone.
    void* internals;
    // When an error occurs in the C API this string will be set to the specific error message.  May
    // be NULL.
    const char* last_error;
} config_object;

// Common functions callable on any config instance:

/// Frees a config object created with one of the config-dependent ..._init functions (e.g.
/// user_profile_init).
void config_free(config_object* conf);

typedef enum config_log_level {
    LOG_LEVEL_DEBUG = 0,
    LOG_LEVEL_INFO,
    LOG_LEVEL_WARNING,
    LOG_LEVEL_ERROR
} config_log_level;

/// Sets a logging function; takes the log function pointer and a context pointer (which can be NULL
/// if not needed).  The given function pointer will be invoked with one of the above values, a
/// null-terminated c string containing the log message, and the void* context object given when
/// setting the logger (this is for caller-specific state data and won't be touched).
///
/// The logging function must have signature:
///
/// void log(config_log_level lvl, const char* msg, void* ctx);
///
/// Can be called with callback set to NULL to clear an existing logger.
///
/// The config object itself has no log level: the caller should filter by level as needed.
void config_set_logger(
        config_object* conf, void (*callback)(config_log_level, const char*, void*), void* ctx);

/// Returns the numeric namespace in which config messages of this type should be stored.
int16_t config_storage_namespace(const config_object* conf);

/// Merges the config object with one or more remotely obtained config strings.  After this call the
/// config object may be unchanged, complete replaced, or updated and needing a push, depending on
/// the messages that are merged; the caller should check config_needs_push().
///
/// `msg_hashes` is an array of null-terminated C strings containing the hashes of the configs being
/// provided.
/// `configs` is an array of pointers to the start of the (binary) data.
/// `lengths` is an array of lengths of the binary data
/// `count` is the length of all three arrays.
int config_merge(
        config_object* conf,
        const char** msg_hashes,
        const unsigned char** configs,
        const size_t* lengths,
        size_t count);

/// Returns true if this config object contains updated data that has not yet been confirmed stored
/// on the server.
bool config_needs_push(const config_object* conf);

/// Returned struct of config push data.
typedef struct config_push_data {
    // The config seqno (to be provided later in `config_confirm_pushed`).
    seqno_t seqno;
    // The config message to push (binary data, not null-terminated).
    unsigned char* config;
    // The length of `config`
    size_t config_len;
    // Array of obsolete message hashes to delete; each element is a null-terminated C string
    char** obsolete;
    // length of `obsolete`
    size_t obsolete_len;
} config_push_data;

/// Obtains the configuration data that needs to be pushed to the server.
///
/// Generally this call should be guarded by a call to `config_needs_push`, however it can be used
/// to re-obtain the current serialized config even if no push is needed (for example, if the client
/// wants to re-submit it after a network error).
///
/// NB: The returned pointer belongs to the caller: that is, the caller *MUST* free() it when
/// done with it.
config_push_data* config_push(config_object* conf);

/// Reports that data obtained from `config_push` has been successfully stored on the server with
/// message hash `msg_hash`.  The seqno value is the one returned by the config_push call that
/// yielded the config data.
void config_confirm_pushed(config_object* conf, seqno_t seqno, const char* msg_hash);

/// Returns a binary dump of the current state of the config object.  This dump can be used to
/// resurrect the object at a later point (e.g. after a restart).  Allocates a new buffer and sets
/// it in `out` and the length in `outlen`.  Note that this is binary data, *not* a null-terminated
/// C string.
///
/// NB: It is the caller's responsibility to `free()` the buffer when done with it.
///
/// Immediately after this is called `config_needs_dump` will start returning true (until the
/// configuration is next modified).
void config_dump(config_object* conf, unsigned char** out, size_t* outlen);

/// Returns true if something has changed since the last call to `dump()` that requires calling
/// and saving the `config_dump()` data again.
bool config_needs_dump(const config_object* conf);

/// Struct containing a list of C strings.  Typically where this is returned by this API it must be
/// freed (via `free()`) when done with it.
typedef struct config_string_list {
    char** value; // array of null-terminated C strings
    size_t len; // length of `value`
} config_string_list;

/// Obtains the current active hashes.  Note that this will be empty if the current hash is unknown
/// or not yet determined (for example, because the current state is dirty or because the most
/// recent push is still pending and we don't know the hash yet).
///
/// The returned pointer belongs to the caller and must be freed via `free()` when done with it.
config_string_list* config_current_hashes(const config_object* conf);

/// Config key management; see the corresponding method docs in base.hpp.  All `key` arguments here
/// are 32-byte binary buffers (and since fixed-length, there is no keylen argument).
void config_add_key(config_object* conf, const unsigned char* key);
void config_add_key_low_prio(config_object* conf, const unsigned char* key);
int config_clear_keys(config_object* conf);
bool config_remove_key(config_object* conf, const unsigned char* key);
int config_key_count(const config_object* conf);
bool config_has_key(const config_object* conf, const unsigned char* key);
// Returns a pointer to the 32-byte binary key at position i.  This is *not* null terminated (and is
// exactly 32 bytes long).  `i < config_key_count(conf)` must be satisfied.  Ownership of the data
// remains in the object (that is: the caller must not attempt to free it).
const unsigned char* config_key(const config_object* conf, size_t i);

/// Returns the encryption domain C-str used to encrypt values for this config object.  (This is
/// here only for debugging/testing).
const char* config_encryption_domain(const config_object* conf);

#ifdef __cplusplus
}  // extern "C"
#endif
