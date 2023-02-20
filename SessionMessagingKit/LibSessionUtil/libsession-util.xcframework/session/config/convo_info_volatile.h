#pragma once

#ifdef __cplusplus
extern "C" {
#endif

#include "base.h"
#include "profile_pic.h"

typedef struct convo_info_volatile_1to1 {
    char session_id[67];  // in hex; 66 hex chars + null terminator.

    int64_t last_read;  // milliseconds since unix epoch
    bool unread;        // true if the conversation is explicitly marked unread
} convo_info_volatile_1to1;

typedef struct convo_info_volatile_community {
    char base_url[268];  // null-terminated (max length 267), normalized (i.e. always lower-case,
                         // only has port if non-default, has trailing / removed)
    char room[65];       // null-terminated (max length 64), normalized (always lower-case)
    unsigned char pubkey[32];  // 32 bytes (not terminated, can contain nulls)

    int64_t last_read;  // ms since unix epoch
    bool unread;        // true if marked unread
} convo_info_volatile_community;

typedef struct convo_info_volatile_legacy_group {
    char group_id[67];  // in hex; 66 hex chars + null terminator.  Looks just like a Session ID,
                        // though isn't really one.

    int64_t last_read;  // ms since unix epoch
    bool unread;        // true if marked unread
} convo_info_volatile_legacy_group;

/// Constructs a conversations config object and sets a pointer to it in `conf`.
///
/// \param ed25519_secretkey must be the 32-byte secret key seed value.  (You can also pass the
/// pointer to the beginning of the 64-byte value libsodium calls the "secret key" as the first 32
/// bytes of that are the seed).  This field cannot be null.
///
/// \param dump - if non-NULL this restores the state from the dumped byte string produced by a past
/// instantiation's call to `dump()`.  To construct a new, empty object this should be NULL.
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
int convo_info_volatile_init(
        config_object** conf,
        const unsigned char* ed25519_secretkey,
        const unsigned char* dump,
        size_t dumplen,
        char* error) __attribute__((warn_unused_result));

/// Fills `convo` with the conversation info given a session ID (specified as a null-terminated hex
/// string), if the conversation exists, and returns true.  If the conversation does not exist then
/// `convo` is left unchanged and false is returned.
bool convo_info_volatile_get_1to1(
        const config_object* conf, convo_info_volatile_1to1* convo, const char* session_id)
        __attribute__((warn_unused_result));

/// Same as the above except that when the conversation does not exist, this sets all the convo
/// fields to defaults and loads it with the given session_id.
///
/// Returns true as long as it is given a valid session_id.  A false return is considered an error,
/// and means the session_id was not a valid session_id.
///
/// This is the method that should usually be used to create or update a conversation, followed by
/// setting fields in the convo, and then giving it to convo_info_volatile_set().
bool convo_info_volatile_get_or_construct_1to1(
        const config_object* conf, convo_info_volatile_1to1* convo, const char* session_id)
        __attribute__((warn_unused_result));

/// community versions of the 1-to-1 functions:
///
/// Gets a community convo info.  `base_url` and `room` are null-terminated c strings; pubkey is
/// 32 bytes.  base_url and room will always be lower-cased (if not already).
bool convo_info_volatile_get_community(
        const config_object* conf,
        convo_info_volatile_community* comm,
        const char* base_url,
        const char* room) __attribute__((warn_unused_result));
bool convo_info_volatile_get_or_construct_community(
        const config_object* conf,
        convo_info_volatile_community* convo,
        const char* base_url,
        const char* room,
        unsigned const char* pubkey) __attribute__((warn_unused_result));

/// Fills `convo` with the conversation info given a legacy group ID (specified as a null-terminated
/// hex string), if the conversation exists, and returns true.  If the conversation does not exist
/// then `convo` is left unchanged and false is returned.
bool convo_info_volatile_get_legacy_group(
        const config_object* conf, convo_info_volatile_legacy_group* convo, const char* id)
        __attribute__((warn_unused_result));

/// Same as the above except that when the conversation does not exist, this sets all the convo
/// fields to defaults and loads it with the given id.
///
/// Returns true as long as it is given a valid legacy group id (i.e. same format as a session id).
/// A false return is considered an error, and means the id was not a valid session id.
///
/// This is the method that should usually be used to create or update a conversation, followed by
/// setting fields in the convo, and then giving it to convo_info_volatile_set().
bool convo_info_volatile_get_or_construct_legacy_group(
        const config_object* conf, convo_info_volatile_legacy_group* convo, const char* id)
        __attribute__((warn_unused_result));

/// Adds or updates a conversation from the given convo info
void convo_info_volatile_set_1to1(config_object* conf, const convo_info_volatile_1to1* convo);
void convo_info_volatile_set_community(
        config_object* conf, const convo_info_volatile_community* convo);
void convo_info_volatile_set_legacy_group(
        config_object* conf, const convo_info_volatile_legacy_group* convo);

/// Erases a conversation from the conversation list.  Returns true if the conversation was found
/// and removed, false if the conversation was not present.  You must not call this during
/// iteration; see details below.
bool convo_info_volatile_erase_1to1(config_object* conf, const char* session_id);
bool convo_info_volatile_erase_community(
        config_object* conf, const char* base_url, const char* room);
bool convo_info_volatile_erase_legacy_group(config_object* conf, const char* group_id);

/// Returns the number of conversations.
size_t convo_info_volatile_size(const config_object* conf);
/// Returns the number of conversations of the specific type.
size_t convo_info_volatile_size_1to1(const config_object* conf);
size_t convo_info_volatile_size_communities(const config_object* conf);
size_t convo_info_volatile_size_legacy_groups(const config_object* conf);

/// Functions for iterating through the entire conversation list.  Intended use is:
///
///     convo_info_volatile_1to1 c1;
///     convo_info_volatile_community c2;
///     convo_info_volatile_legacy_group c3;
///     convo_info_volatile_iterator *it = convo_info_volatile_iterator_new(my_convos);
///     for (; !convo_info_volatile_iterator_done(it); convo_info_volatile_iterator_advance(it)) {
///         if (convo_info_volatile_it_is_1to1(it, &c1)) {
///             // use c1.whatever
///         } else if (convo_info_volatile_it_is_community(it, &c2)) {
///             // use c2.whatever
///         } else if (convo_info_volatile_it_is_legacy_group(it, &c3)) {
///             // use c3.whatever
///         }
///     }
///     convo_info_volatile_iterator_free(it);
///
/// It is permitted to modify records (e.g. with a call to one of the `convo_info_volatile_set_*`
/// functions) and add records while iterating.
///
/// If you need to remove while iterating then usage is slightly different: you must advance the
/// iteration by calling either convo_info_volatile_iterator_advance if not deleting, or
/// convo_info_volatile_iterator_erase to erase and advance.  Usage looks like this:
///
///     convo_info_volatile_1to1 c1;
///     convo_info_volatile_iterator *it = convo_info_volatile_iterator_new(my_convos);
///     while (!convo_info_volatile_iterator_done(it)) {
///         if (convo_it_is_1to1(it, &c1)) {
///             bool should_delete = /* ... */;
///             if (should_delete)
///                 convo_info_volatile_iterator_erase(it);
///             else
///                 convo_info_volatile_iterator_advance(it);
///         } else {
///             convo_info_volatile_iterator_advance(it);
///         }
///     }
///     convo_info_volatile_iterator_free(it);
///

typedef struct convo_info_volatile_iterator convo_info_volatile_iterator;

// Starts a new iterator that iterates over all conversations.
convo_info_volatile_iterator* convo_info_volatile_iterator_new(const config_object* conf);

// The same as `convo_info_volatile_iterator_new` except that this iterates *only* over one type of
// conversation. You still need to use `convo_info_volatile_it_is_1to1` (or the alternatives) to
// load the data in each pass of the loop.  (You can, however, safely ignore the bool return value
// of the `it_is_whatever` function: it will always be true for the particular type being iterated
// over).
convo_info_volatile_iterator* convo_info_volatile_iterator_new_1to1(const config_object* conf);
convo_info_volatile_iterator* convo_info_volatile_iterator_new_communities(
        const config_object* conf);
convo_info_volatile_iterator* convo_info_volatile_iterator_new_legacy_groups(
        const config_object* conf);

// Frees an iterator once no longer needed.
void convo_info_volatile_iterator_free(convo_info_volatile_iterator* it);

// Returns true if iteration has reached the end.
bool convo_info_volatile_iterator_done(convo_info_volatile_iterator* it);

// Advances the iterator.
void convo_info_volatile_iterator_advance(convo_info_volatile_iterator* it);

// If the current iterator record is a 1-to-1 conversation this sets the details into `c` and
// returns true.  Otherwise it returns false.
bool convo_info_volatile_it_is_1to1(convo_info_volatile_iterator* it, convo_info_volatile_1to1* c);

// If the current iterator record is a community conversation this sets the details into `c` and
// returns true.  Otherwise it returns false.
bool convo_info_volatile_it_is_community(
        convo_info_volatile_iterator* it, convo_info_volatile_community* c);

// If the current iterator record is a legacy group conversation this sets the details into `c` and
// returns true.  Otherwise it returns false.
bool convo_info_volatile_it_is_legacy_group(
        convo_info_volatile_iterator* it, convo_info_volatile_legacy_group* c);

// Erases the current convo while advancing the iterator to the next convo in the iteration.
void convo_info_volatile_iterator_erase(config_object* conf, convo_info_volatile_iterator* it);

#ifdef __cplusplus
}  // extern "C"
#endif
