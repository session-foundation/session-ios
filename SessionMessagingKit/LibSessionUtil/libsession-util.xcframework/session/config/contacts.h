#pragma once

#ifdef __cplusplus
extern "C" {
#endif

#include "base.h"
#include "profile_pic.h"

typedef struct contacts_contact {
    char session_id[67];  // in hex; 66 hex chars + null terminator.

    // These can be NULL.  When setting, either NULL or empty string will clear the setting.
    const char* name;
    const char* nickname;
    user_profile_pic profile_pic;

    bool approved;
    bool approved_me;
    bool blocked;

} contacts_contact;

/// Constructs a contacts config object and sets a pointer to it in `conf`.
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
int contacts_init(
        config_object** conf,
        const unsigned char* ed25519_secretkey,
        const unsigned char* dump,
        size_t dumplen,
        char* error) __attribute__((warn_unused_result));

/// Returns true if session_id has the right form (66 hex digits).  This is a quick check, not a
/// robust one: it does not check the leading byte prefix, nor the cryptographic properties of the
/// pubkey for actual validity.
bool session_id_is_valid(const char* session_id);

/// Fills `contact` with the contact info given a session ID (specified as a null-terminated hex
/// string), if the contact exists, and returns true.  If the contact does not exist then `contact`
/// is left unchanged and false is returned.
bool contacts_get(const config_object* conf, contacts_contact* contact, const char* session_id)
        __attribute__((warn_unused_result));

/// Same as the above except that when the contact does not exist, this sets all the contact fields
/// to defaults and loads it with the given session_id.
///
/// Returns true as long as it is given a valid session_id.  A false return is considered an error,
/// and means the session_id was not a valid session_id.
///
/// This is the method that should usually be used to create or update a contact, followed by
/// setting fields in the contact, and then giving it to contacts_set().
bool contacts_get_or_create(
        const config_object* conf, contacts_contact* contact, const char* session_id)
        __attribute__((warn_unused_result));

/// Adds or updates a contact from the given contact info struct.
void contacts_set(config_object* conf, const contacts_contact* contact);

// NB: wrappers for set_name, set_nickname, etc. C++ methods are deliberately omitted as they would
// save very little in actual calling code.  The procedure for updating a single field without them
// is simple enough; for example to update `approved` and leave everything else unchanged:
//
// contacts_contact c;
// if (contacts_get_or_create(conf, &c, some_session_id)) {
//     const char* new_nickname = "Joe";
//     c.approved = new_nickname;
//     contacts_set_or_create(conf, &c);
// } else {
//     // some_session_id was invalid!
// }

/// Erases a contact from the contact list.  session_id is in hex.  Returns true if the contact was
/// found and removed, false if the contact was not present.  You must not call this during
/// iteration; see details below.
bool contacts_erase(config_object* conf, const char* session_id);

/// Functions for iterating through the entire contact list, in sorted order.  Intended use is:
///
///     contacts_contact c;
///     contacts_iterator *it = contacts_iterator_new(contacts);
///     for (; !contacts_iterator_done(it, &c); contacts_iterator_advance(it)) {
///         // c.session_id, c.nickname, etc. are loaded
///     }
///     contacts_iterator_free(it);
///
/// It is permitted to modify records (e.g. with a call to `contacts_set`) and add records while
/// iterating.
///
/// If you need to remove while iterating then usage is slightly different: you must advance the
/// iteration by calling either contacts_iterator_advance if not deleting, or
/// contacts_iterator_erase to erase and advance.  Usage looks like this:
///
///     contacts_contact c;
///     contacts_iterator *it = contacts_iterator_new(contacts);
///     while (!contacts_iterator_done(it, &c)) {
///         // c.session_id, c.nickname, etc. are loaded
///
///         bool should_delete = /* ... */;
///
///         if (should_delete)
///             contacts_iterator_erase(it);
///         else
///             contacts_iterator_advance(it);
///     }
///     contacts_iterator_free(it);
///
///

typedef struct contacts_iterator {
    void* _internals;
} contacts_iterator;

// Starts a new iterator.
contacts_iterator* contacts_iterator_new(const config_object* conf);
// Frees an iterator once no longer needed.
void contacts_iterator_free(contacts_iterator* it);

// Returns true if iteration has reached the end.  Otherwise `c` is populated and false is returned.
bool contacts_iterator_done(contacts_iterator* it, contacts_contact* c);

// Advances the iterator.
void contacts_iterator_advance(contacts_iterator* it);

// Erases the current contact while advancing the iterator to the next contact in the iteration.
void contacts_iterator_erase(config_object* conf, contacts_iterator* it);

#ifdef __cplusplus
}  // extern "C"
#endif
