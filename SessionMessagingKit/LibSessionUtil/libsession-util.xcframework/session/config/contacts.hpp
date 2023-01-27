#pragma once

#include <cstddef>
#include <iterator>
#include <memory>
#include <session/config.hpp>

#include "base.hpp"
#include "namespaces.hpp"
#include "profile_pic.hpp"

extern "C" struct contacts_contact;

namespace session::config {

/// keys used in this config, either currently or in the past (so that we don't reuse):
///
/// c - dict of contacts; within this dict each key is the session pubkey (binary, 33 bytes) and
///     value is a dict containing keys:
///
///     ! - dummy value that is always set to an empty string.  This ensures that we always have at
///         least one key set, which is required to keep the dict value alive (empty dicts get
///         pruned when serialied).
///     n - contact name (string)
///     N - contact nickname (string)
///     p - profile url (string)
///     q - profile decryption key (binary)
///     a - 1 if approved, omitted otherwise (int)
///     A - 1 if remote has approved me, omitted otherwise (int)
///     b - 1 if contact is blocked, omitted otherwise

/// Struct containing contact info.  Note that data must be copied/used immediately as the data will
/// not remain valid beyond other calls into the library.  When settings things in this externally
/// (e.g. to pass into `set()`), take note that the `name` and `nickname` are string_views: that is,
/// they must reference existing string data that remains valid for the duration of the contact_info
/// instance.
struct contact_info {
    std::string session_id;  // in hex
    std::optional<std::string_view> name;
    std::optional<std::string_view> nickname;
    std::optional<profile_pic> profile_picture;
    bool approved = false;
    bool approved_me = false;
    bool blocked = false;

    explicit contact_info(std::string sid);

    // Internal ctor/method for C API implementations:
    contact_info(const struct contacts_contact& c);  // From c struct
    void into(contacts_contact& c) const;            // Into c struct

    // Sets a name, storing the name internally in the object.  This is intended for use where the
    // source string is a temporary may not outlive the `contact_info` object: the name is first
    // copied into an internal std::string, and then the name string_view references that.
    void set_name(std::string name);

    // Same as above, but for nickname.
    void set_nickname(std::string nickname);

  private:
    friend class Contacts;

    std::string name_;
    std::string nickname_;

    void load(const dict& info_dict);
};

class Contacts : public ConfigBase {

  public:
    // No default constructor
    Contacts() = delete;

    /// Constructs a contact list from existing data (stored from `dump()`) and the user's secret
    /// key for generating the data encryption key.  To construct a blank list (i.e. with no
    /// pre-existing dumped data to load) pass `std::nullopt` as the second argument.
    ///
    /// \param ed25519_secretkey - contains the libsodium secret key used to encrypt/decrypt the
    /// data when pushing/pulling from the swarm.  This can either be the full 64-byte value (which
    /// is technically the 32-byte seed followed by the 32-byte pubkey), or just the 32-byte seed of
    /// the secret key.
    ///
    /// \param dumped - either `std::nullopt` to construct a new, empty object; or binary state data
    /// that was previously dumped from an instance of this class by calling `dump()`.
    Contacts(ustring_view ed25519_secretkey, std::optional<ustring_view> dumped);

    Namespace storage_namespace() const override { return Namespace::Contacts; }

    const char* encryption_domain() const override { return "Contacts"; }

    /// Looks up and returns a contact by session ID (hex).  Returns nullopt if the session ID was
    /// not found, otherwise returns a filled out `contact_info`.
    std::optional<contact_info> get(std::string_view pubkey_hex) const;

    /// Similar to get(), but if the session ID does not exist this returns a filled-out
    /// contact_info containing the session_id (all other fields will be empty/defaulted).  This is
    /// intended to be combined with `set` to set-or-create a record.
    ///
    /// NB: calling this does *not* add the session id to the contact list when called: that
    /// requires also calling `set` with this value.
    contact_info get_or_construct(std::string_view pubkey_hex) const;

    /// Sets or updates multiple contact info values at once with the given info.  The usual use is
    /// to access the current info, change anything desired, then pass it back into set_contact,
    /// e.g.:
    ///
    ///     auto c = contacts.get_or_construct(pubkey);
    ///     c.name = "Session User 42";
    ///     c.nickname = "BFF";
    ///     contacts.set(c);
    void set(const contact_info& contact);

    /// Alternative to `set()` for setting individual fields.
    void set_name(std::string_view session_id, std::string name);
    void set_nickname(std::string_view session_id, std::string nickname);
    void set_profile_pic(std::string_view session_id, profile_pic pic);
    void set_approved(std::string_view session_id, bool approved);
    void set_approved_me(std::string_view session_id, bool approved_me);
    void set_blocked(std::string_view session_id, bool blocked);

    /// Removes a contact, if present.  Returns true if it was found and removed, false otherwise.
    /// Note that this removes all fields related to a contact, even fields we do not know about.
    bool erase(std::string_view session_id);

    struct iterator;

    /// This works like erase, but takes an iterator to the contact to remove.  The element is
    /// removed and the iterator to the next element after the removed one is returned.  This is
    /// intended for use where elements are to be removed during iteration: see below for an
    /// example.
    iterator erase(iterator it);

    /// Returns the number of contacts.
    size_t size() const;

    /// Returns true if the contact list is empty.
    bool empty() const { return size() == 0; }

    /// Iterators for iterating through all contacts.  Typically you access this implicit via a for
    /// loop over the `Contacts` object:
    ///
    ///     for (auto& contact : contacts) {
    ///         // use contact.session_id, contact.name, etc.
    ///     }
    ///
    /// This iterates in sorted order through the session_ids.
    ///
    /// It is permitted to modify and add records while iterating (e.g. by modifying `contact` and
    /// then calling set()).
    ///
    /// If you need to erase the current contact during iteration then care is required: you need to
    /// advance the iterator via the iterator version of erase when erasing an element rather than
    /// incrementing it regularly.  For example:
    ///
    ///     for (auto it = contacts.begin(); it != contacts.end(); ) {
    ///         if (should_remove(*it))
    ///             it = contacts.erase(it);
    ///         else
    ///             ++it;
    ///     }
    ///
    /// Alternatively, you can use the first version with two loops: the first loop through all
    /// contacts doesn't erase but just builds a vector of IDs to erase, then the second loops
    /// through that vector calling `erase()` for each one.
    ///
    iterator begin() const { return iterator{data["c"].dict()}; }
    iterator end() const { return iterator{nullptr}; }

    using iterator_category = std::input_iterator_tag;
    using value_type = contact_info;
    using reference = value_type&;
    using pointer = value_type*;
    using difference_type = std::ptrdiff_t;

    struct iterator {
      private:
        std::shared_ptr<contact_info> _val;
        dict::const_iterator _it;
        const dict* _contacts;
        void _load_info();
        iterator(const dict* contacts) : _contacts{contacts} {
            if (_contacts) {
                _it = _contacts->begin();
                _load_info();
            }
        }
        friend class Contacts;

      public:
        bool operator==(const iterator& other) const;
        bool operator!=(const iterator& other) const { return !(*this == other); }
        bool done() const;  // Equivalent to comparing against the end iterator
        contact_info& operator*() const { return *_val; }
        contact_info* operator->() const { return _val.get(); }
        iterator& operator++();
        iterator operator++(int) {
            auto copy{*this};
            ++*this;
            return copy;
        }
    };
};

}  // namespace session::config
