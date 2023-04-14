#pragma once

#include <chrono>
#include <cstddef>
#include <iterator>
#include <memory>
#include <session/config.hpp>

#include "base.hpp"
#include "community.hpp"
#include "namespaces.hpp"
#include "notify.hpp"

extern "C" {
struct ugroups_legacy_group_info;
struct ugroups_community_info;
}

namespace session::config {

/// keys used in this config, either currently or in the past (so that we don't reuse):
///
/// C - dict of legacy groups; within this dict each key is the group pubkey (binary, 33 bytes) and
/// value is a dict containing keys:
///
///     n - name (string).  Always set, even if empty.
///     k - encryption public key (32 bytes).  Optional.
///     K - encryption secret key (32 bytes).  Optional.
///     m - set of member session ids (each 33 bytes).
///     a - set of admin session ids (each 33 bytes).
///     E - disappearing messages duration, in seconds, > 0.  Omitted if disappearing messages is
///         disabled.  (Note that legacy groups only support expire after-read)
///     @ - notification setting (int).  Omitted = use default setting; 1 = all, 2 = disabled, 3 =
///         mentions-only.
///     ! - mute timestamp: if set then don't show notifications for this contact's messages until
///         this unix timestamp (i.e.  overriding the current notification setting until the given
///         time).
///     + - the conversation priority, for pinned/hidden messages.  Integer.  Omitted means not
///         pinned; -1 means hidden, and a positive value is a pinned message for which higher
///         priority values means the conversation is meant to appear earlier in the pinned
///         conversation list.
///     j - joined at unix timestamp.  Omitted if 0.
///
/// o - dict of communities (AKA open groups); within this dict (which deliberately has the same
///     layout as convo_info_volatile) each key is the SOGS base URL (in canonical form), and value
///     is a dict of:
///
///     # - server pubkey
///     R - dict of rooms on the server. Each key is the *lower-case* room name; each value is:
///         n - the room name as is commonly used, i.e. with possible capitalization (if
///             appropriate).  For instance, a room name SudokuSolvers would be "sudokusolvers" in
///             the outer key, with the capitalization variation in use ("SudokuSolvers") in this
///             key.  This key is *always* present (to keep the room dict non-empty).
///         @ - notification setting (see above).
///         ! - mute timestamp (see above).
///         + - the conversation priority, for pinned messages.  Omitted means not pinned; -1 means
///             hidden; otherwise an integer value >0, where a higher priority means the
///             conversation is meant to appear earlier in the pinned conversation list.
///         j - joined at unix timestamp.  Omitted if 0.
///
/// c - reserved for future storage of new-style group info.

/// Common base type with fields shared by all the groups
struct base_group_info {
    int priority = 0;       // The priority; 0 means unpinned, -1 means hidden, positive means
                            // pinned higher (i.e.  higher priority conversations come first).
    int64_t joined_at = 0;  // unix timestamp (seconds) when the group was joined (or re-joined)
    notify_mode notifications = notify_mode::defaulted;  // When the user wants notifications
    int64_t mute_until = 0;  // unix timestamp (seconds) until which notifications are disabled

  protected:
    void load(const dict& info_dict);
};

/// Struct containing legacy group info (aka "closed groups").
struct legacy_group_info : base_group_info {
    static constexpr size_t NAME_MAX_LENGTH = 100;  // in bytes; name will be truncated if exceeded

    std::string session_id;  // The legacy group "session id" (33 bytes).
    std::string name;  // human-readable; this should normally always be set, but in theory could be
                       // set to an empty string.
    ustring enc_pubkey;                          // bytes (32 or empty)
    ustring enc_seckey;                          // bytes (32 or empty)
    std::chrono::seconds disappearing_timer{0};  // 0 == disabled.

    /// Constructs a new legacy group info from an id (which must look like a session_id).  Throws
    /// if id is invalid.
    explicit legacy_group_info(std::string sid);

    // Accesses the session ids (in hex) of members of this group.  The key is the hex session_id;
    // the value indicates whether the member is an admin (true) or not (false).
    const std::map<std::string, bool>& members() const { return members_; }

    // Returns a pair of the number of admins, and regular members of this group.  (If all you want
    // is the overall number just use `.members().size()` instead).
    std::pair<size_t, size_t> counts() const;

    // Adds a member (by session id and admin status) to this group.  Returns true if the member was
    // inserted or changed admin status, false if the member already existed.  Throws
    // std::invalid_argument if the given session id is invalid.
    bool insert(std::string session_id, bool admin);

    // Removes a member (by session id) from this group.  Returns true if the member was
    // removed, false if the member was not present.
    bool erase(const std::string& session_id);

    // Internal ctor/method for C API implementations:
    legacy_group_info(const struct ugroups_legacy_group_info& c);  // From c struct
    legacy_group_info(struct ugroups_legacy_group_info&& c);       // From c struct
    void into(struct ugroups_legacy_group_info& c) const&;         // Copy into c struct
    void into(struct ugroups_legacy_group_info& c) &&;             // Move into c struct

  private:
    // session_id => (is admin)
    std::map<std::string, bool> members_;

    friend class UserGroups;

    // Private implementations of the to/from C struct methods
    struct impl_t {};
    static constexpr inline impl_t impl{};
    legacy_group_info(const struct ugroups_legacy_group_info& c, impl_t);
    void into(struct ugroups_legacy_group_info& c, impl_t) const;

    void load(const dict& info_dict);
};

/// Community (aka open group) info
struct community_info : base_group_info, community {
    // Note that *changing* url/room/pubkey and then doing a set inserts a new room under the given
    // url/room/pubkey, it does *not* update an existing room.

    // See community_base (comm_base.hpp) for common constructors
    using community::community;

    // Internal ctor/method for C API implementations:
    community_info(const struct ugroups_community_info& c);  // From c struct
    void into(ugroups_community_info& c) const;              // Into c struct

  private:
    void load(const dict& info_dict);

    friend class UserGroups;
    friend class comm_iterator_helper;
};

using any_group_info = std::variant<community_info, legacy_group_info>;

class UserGroups : public ConfigBase {

  public:
    // No default constructor
    UserGroups() = delete;

    /// Constructs a user group list from existing data (stored from `dump()`) and the user's
    /// secret key for generating the data encryption key.  To construct a blank list (i.e. with no
    /// pre-existing dumped data to load) pass `std::nullopt` as the second argument.
    ///
    /// \param ed25519_secretkey - contains the libsodium secret key used to encrypt/decrypt the
    /// data when pushing/pulling from the swarm.  This can either be the full 64-byte value (which
    /// is technically the 32-byte seed followed by the 32-byte pubkey), or just the 32-byte seed of
    /// the secret key.
    ///
    /// \param dumped - either `std::nullopt` to construct a new, empty object; or binary state data
    /// that was previously dumped from an instance of this class by calling `dump()`.
    UserGroups(ustring_view ed25519_secretkey, std::optional<ustring_view> dumped);

    Namespace storage_namespace() const override { return Namespace::UserGroups; }

    const char* encryption_domain() const override { return "UserGroups"; }

    /// Looks up and returns a community (aka open group) conversation.  Takes the base URL and room
    /// token (case insensitive).  Retuns nullopt if the open group was not found, otherwise a
    /// filled out `community_info`.  Note that the `room` argument here is case-insensitive, but
    /// the returned value will be the room as stored in the object (i.e. it may have a different
    /// case from the requested `room` value).
    std::optional<community_info> get_community(
            std::string_view base_url, std::string_view room) const;

    /// Looks up a community from a full URL.  It is permitted for the URL to omit the pubkey (it
    /// is not used or needed by this call).
    std::optional<community_info> get_community(std::string_view partial_url) const;

    /// Looks up and returns a legacy group by group ID (hex, looks like a Session ID).  Returns
    /// nullopt if the group was not found, otherwise returns a filled out `legacy_group_info`.
    std::optional<legacy_group_info> get_legacy_group(std::string_view pubkey_hex) const;

    /// Same as `get_community`, except if the community isn't found a new blank one is created for
    /// you, prefilled with the url/room/pubkey.
    ///
    /// Note that `room` and `pubkey` have special handling:
    /// - `room` is case-insensitive for the lookup: if a matching room is found then the returned
    ///   value reflects the room case of the existing record, which is not necessarily the same as
    ///   the `room` argument given here (to force a case change, set it within the returned
    ///   object).
    /// - `pubkey` is not used to find an existing community, but if the community found has a
    ///   *different* pubkey from the one given then the returned record has its pubkey updated in
    ///   the return instance (note that this changed value is not committed to storage, however,
    ///   until the instance is passed to `set()`).  For the string_view version the pubkey is
    ///   accepted as hex, base32z, or base64.
    community_info get_or_construct_community(
            std::string_view base_url,
            std::string_view room,
            std::string_view pubkey_encoded) const;
    community_info get_or_construct_community(
            std::string_view base_url, std::string_view room, ustring_view pubkey) const;
    /// Shortcut to pass the url through community::parse_full_url, then call the above.
    community_info get_or_construct_community(std::string_view full_url) const;

    /// Gets or constructs a blank legacy_group_info for the given group id.
    legacy_group_info get_or_construct_legacy_group(std::string_view pubkey_hex) const;

    /// Inserts or replaces existing group info.  For example, to update the info for a community
    /// you would do:
    ///
    ///     auto info = conversations.get_or_construct_community(some_session_id);
    ///     info.last_read = new_unix_timestamp;
    ///     conversations.set(info);
    ///
    void set(const community_info& info);
    void set(const legacy_group_info& info);
    /// Takes a variant of either group type to set:
    void set(const any_group_info& info);

  protected:
    // Drills into the nested dicts to access open group details
    DictFieldProxy community_field(
            const community_info& og, ustring_view* get_pubkey = nullptr) const;

    void set_base(const base_group_info& bg, DictFieldProxy& info) const;

  public:
    /// Removes a community group.  Returns true if found and removed, false if not present.
    /// Arguments are the same as `get_community`.
    bool erase_community(std::string_view base_url, std::string_view room);

    /// Removes a legacy group conversation.  Returns true if found and removed, false if not
    /// present.
    bool erase_legacy_group(std::string_view pubkey_hex);

    /// Removes a conversation taking the community_info or legacy_group_info instance (rather than
    /// the pubkey/url) for convenience.
    bool erase(const community_info& g);
    bool erase(const legacy_group_info& c);
    bool erase(const any_group_info& info);

    struct iterator;

    /// This works like erase, but takes an iterator to the group to remove.  The element is removed
    /// and the iterator to the next element after the removed one is returned.  This is intended
    /// for use where elements are to be removed during iteration: see below for an example.
    iterator erase(iterator it);

    /// Returns the number of groups (of any type).
    size_t size() const;

    /// Returns the number of communities
    size_t size_communities() const;

    /// Returns the number of legacy groups
    size_t size_legacy_groups() const;

    /// Returns true if the group list is empty.
    bool empty() const { return size() == 0; }

    /// Iterators for iterating through all groups.  Typically you access this implicit via a
    /// for loop over the `UserGroups` object:
    ///
    ///     for (auto& group : usergroups) {
    ///         if (auto* comm = std::get_if<community_info>(&group)) {
    ///             // use comm->name, comm->priority, etc.
    ///         } else if (auto* lg = std::get_if<legacy_group_info>(&convo)) {
    ///             // use lg->session_id, lg->priority, etc.
    ///         }
    ///     }
    ///
    /// This iterates through all groups in sorted order (sorted first by convo type, then by
    /// id within the type).
    ///
    /// It is permitted to modify and add records while iterating (e.g. by modifying one of the
    /// `comm`/`lg` objects and then calling set()).
    ///
    /// If you need to erase the current conversation during iteration then care is required: you
    /// need to advance the iterator via the iterator version of erase when erasing an element
    /// rather than incrementing it regularly.  For example:
    ///
    ///     for (auto it = conversations.begin(); it != conversations.end(); ) {
    ///         if (should_remove(*it))
    ///             it = converations.erase(it);
    ///         else
    ///             ++it;
    ///     }
    ///
    /// Alternatively, you can use the first version with two loops: the first loop through all
    /// converations doesn't erase but just builds a vector of IDs to erase, then the second loops
    /// through that vector calling `erase_1to1()`/`erase_open()`/`erase_legacy_group()` for each
    /// one.
    ///
    iterator begin() const { return iterator{data}; }
    iterator end() const { return iterator{}; }

    template <typename GroupType>
    struct subtype_iterator;

    /// Returns an iterator that iterates only through one type of conversations.  (The regular
    /// `.end()` iterator is valid for testing the end of these iterations).
    subtype_iterator<community_info> begin_communities() const { return {data}; }
    subtype_iterator<legacy_group_info> begin_legacy_groups() const { return {data}; }

    using iterator_category = std::input_iterator_tag;
    using value_type = std::variant<community_info, legacy_group_info>;
    using reference = value_type&;
    using pointer = value_type*;
    using difference_type = std::ptrdiff_t;

    struct iterator {
      protected:
        std::shared_ptr<any_group_info> _val;
        std::optional<comm_iterator_helper> _it_comm;
        std::optional<dict::const_iterator> _it_legacy, _end_legacy;
        void _load_val();
        iterator() = default;  // Constructs an end tombstone
        explicit iterator(
                const DictFieldRoot& data, bool communities = true, bool legacy_closed = true);
        friend class UserGroups;

      public:
        bool operator==(const iterator& other) const;
        bool operator!=(const iterator& other) const { return !(*this == other); }
        bool done() const;  // Equivalent to comparing against the end iterator
        any_group_info& operator*() const { return *_val; }
        any_group_info* operator->() const { return _val.get(); }
        iterator& operator++();
        iterator operator++(int) {
            auto copy{*this};
            ++*this;
            return copy;
        }
    };

    template <typename GroupType>
    struct subtype_iterator : iterator {
      protected:
        subtype_iterator(const DictFieldRoot& data) :
                iterator(
                        data,
                        std::is_same_v<community_info, GroupType>,
                        std::is_same_v<legacy_group_info, GroupType>) {}
        friend class UserGroups;

      public:
        GroupType& operator*() const { return std::get<GroupType>(*_val); }
        GroupType* operator->() const { return &std::get<GroupType>(*_val); }
        subtype_iterator& operator++() {
            iterator::operator++();
            return *this;
        }
        subtype_iterator operator++(int) {
            auto copy{*this};
            ++*this;
            return copy;
        }
    };
};

}  // namespace session::config
