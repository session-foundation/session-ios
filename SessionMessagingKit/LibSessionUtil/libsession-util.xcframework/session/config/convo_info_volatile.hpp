#pragma once

#include <chrono>
#include <cstddef>
#include <iterator>
#include <memory>
#include <session/config.hpp>

#include "base.hpp"
#include "community.hpp"

using namespace std::literals;

extern "C" {
struct convo_info_volatile_1to1;
struct convo_info_volatile_community;
struct convo_info_volatile_legacy_group;
}

namespace session::config {

class ConvoInfoVolatile;

/// keys used in this config, either currently or in the past (so that we don't reuse):
///
/// Note that this is a high-frequency object, intended only for properties that change frequently (
/// (currently just the read timestamp for each conversation).
///
/// 1 - dict of one-to-one conversations.  Each key is the Session ID of the contact (in hex).
///     Values are dicts with keys:
///     r - the unix timestamp (in integer milliseconds) of the last-read message.  Always
///         included, but will be 0 if no messages are read.
///     u - will be present and set to 1 if this conversation is specifically marked unread.
///
/// o - community conversations.  This is a nested dict where the outer keys are the BASE_URL of the
///     community and the outer value is a dict containing:
///     - `#` -- the 32-byte server pubkey
///     - `R` -- dict of rooms on the server; each key is the lower-case room name, value is a dict
///       containing keys:
///       r - the unix timestamp (in integer milliseconds) of the last-read message.  Always
///           included, but will be 0 if no messages are read.
///       u - will be present and set to 1 if this conversation is specifically marked unread.
///
/// C - legacy group conversations (aka closed groups).  The key is the group identifier (which
///     looks indistinguishable from a Session ID, but isn't really a proper Session ID).  Values
///     are dicts with keys:
///     r - the unix timestamp (integer milliseconds) of the last-read message.  Always included,
///         but will be 0 if no messages are read.
///     u - will be present and set to 1 if this conversation is specifically marked unread.
///
/// c - reserved for future tracking of new group conversations.

namespace convo {

    struct base {
        int64_t last_read = 0;
        bool unread = false;

      protected:
        void load(const dict& info_dict);
    };

    struct one_to_one : base {
        std::string session_id;  // in hex

        // Constructs an empty one_to_one from a session_id.  Session ID can be either bytes (33) or
        // hex (66).
        explicit one_to_one(std::string&& session_id);
        explicit one_to_one(std::string_view session_id);

        // Internal ctor/method for C API implementations:
        one_to_one(const struct convo_info_volatile_1to1& c);  // From c struct
        void into(convo_info_volatile_1to1& c) const;          // Into c struct

        friend class session::config::ConvoInfoVolatile;
    };

    struct community : config::community, base {

        using config::community::community;

        // Internal ctor/method for C API implementations:
        community(const convo_info_volatile_community& c);  // From c struct
        void into(convo_info_volatile_community& c) const;  // Into c struct

        friend class session::config::ConvoInfoVolatile;
        friend struct session::config::comm_iterator_helper;
    };

    struct legacy_group : base {
        std::string id;  // in hex, indistinguishable from a Session ID

        // Constructs an empty legacy_group from a quasi-session_id
        explicit legacy_group(std::string&& group_id);
        explicit legacy_group(std::string_view group_id);

        // Internal ctor/method for C API implementations:
        legacy_group(const struct convo_info_volatile_legacy_group& c);  // From c struct
        void into(convo_info_volatile_legacy_group& c) const;            // Into c struct

      private:
        friend class session::config::ConvoInfoVolatile;
    };

    using any = std::variant<one_to_one, community, legacy_group>;
}  // namespace convo

class ConvoInfoVolatile : public ConfigBase {

  public:
    // No default constructor
    ConvoInfoVolatile() = delete;

    /// Constructs a conversation list from existing data (stored from `dump()`) and the user's
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
    ConvoInfoVolatile(ustring_view ed25519_secretkey, std::optional<ustring_view> dumped);

    Namespace storage_namespace() const override { return Namespace::ConvoInfoVolatile; }

    const char* encryption_domain() const override { return "ConvoInfoVolatile"; }

    /// Our pruning ages.  We ignore added conversations that are more than PRUNE_LOW before now,
    /// and we active remove (when doing a new push) any conversations that are more than PRUNE_HIGH
    /// before now.  Clients can mostly ignore these and just add all conversations; the class just
    /// transparently ignores (or removes) pruned values.
    static constexpr auto PRUNE_LOW = 30 * 24h;
    static constexpr auto PRUNE_HIGH = 45 * 24h;

    /// Overrides push() to prune stale last-read values before we do the push.
    std::pair<ustring, seqno_t> push() override;

    /// Looks up and returns a contact by session ID (hex).  Returns nullopt if the session ID was
    /// not found, otherwise returns a filled out `convo::one_to_one`.
    std::optional<convo::one_to_one> get_1to1(std::string_view session_id) const;

    /// Looks up and returns a community conversation.  Takes the base URL and room name (case
    /// insensitive).  Retuns nullopt if the community was not found, otherwise a filled out
    /// `convo::community`.
    std::optional<convo::community> get_community(
            std::string_view base_url, std::string_view room) const;

    /// Looks up and returns a legacy group conversation by ID.  The ID looks like a hex Session ID,
    /// but isn't really a Session ID.  Returns nullopt if there is no record of the group
    /// conversation.
    std::optional<convo::legacy_group> get_legacy_group(std::string_view pubkey_hex) const;

    /// These are the same as the above methods (without "_or_construct" in the name), except that
    /// when the conversation doesn't exist a new one is created, prefilled with the pubkey/url/etc.
    convo::one_to_one get_or_construct_1to1(std::string_view session_id) const;
    convo::legacy_group get_or_construct_legacy_group(std::string_view pubkey_hex) const;

    /// This is similar to get_community, except that it also takes the pubkey; the community is
    /// looked up by the url & room; if not found, it is constructed using room, url, and pubkey; if
    /// it *is* found, then it will always have the *input* pubkey, not the stored pubkey
    /// (effectively the provided pubkey replaces the stored one in the returned object; this is not
    /// applied to storage, however, unless/until the instance is given to `set()`).
    ///
    /// Note, however, that when modifying an object like this the update is *only* applied to the
    /// returned object; like other fields, it is not updated in the internal state unless/until
    /// that community instance is passed to `set()`.
    convo::community get_or_construct_community(
            std::string_view base_url, std::string_view room, std::string_view pubkey_hex) const;
    convo::community get_or_construct_community(
            std::string_view base_url, std::string_view room, ustring_view pubkey) const;

    /// Inserts or replaces existing conversation info.  For example, to update a 1-to-1
    /// conversation last read time you would do:
    ///
    ///     auto info = conversations.get_or_construct_1to1(some_session_id);
    ///     info.last_read = new_unix_timestamp;
    ///     conversations.set(info);
    ///
    void set(const convo::one_to_one& c);
    void set(const convo::legacy_group& c);
    void set(const convo::community& c);

    void set(const convo::any& c);  // Variant which can be any of the above

  protected:
    void set_base(const convo::base& c, DictFieldProxy& info);

    // Drills into the nested dicts to access community details; if the second argument is
    // non-nullptr then it will be set to the community's pubkey, if it exists.
    DictFieldProxy community_field(
            const convo::community& og, ustring_view* get_pubkey = nullptr) const;

  public:
    /// Removes a one-to-one conversation.  Returns true if found and removed, false if not present.
    bool erase_1to1(std::string_view pubkey);

    /// Removes a community conversation record.  Returns true if found and removed, false if not
    /// present.  Arguments are the same as `get_community`.
    bool erase_community(std::string_view base_url, std::string_view room);

    /// Removes a legacy group conversation.  Returns true if found and removed, false if not
    /// present.
    bool erase_legacy_group(std::string_view pubkey_hex);

    /// Removes a conversation taking the convo::whatever record (rather than the pubkey/url).
    bool erase(const convo::one_to_one& c);
    bool erase(const convo::community& c);
    bool erase(const convo::legacy_group& c);

    bool erase(const convo::any& c);  // Variant of any of them

    struct iterator;

    /// This works like erase, but takes an iterator to the conversation to remove.  The element is
    /// removed and the iterator to the next element after the removed one is returned.  This is
    /// intended for use where elements are to be removed during iteration: see below for an
    /// example.
    iterator erase(iterator it);

    /// Returns the number of conversations (of any type).
    size_t size() const;

    /// Returns the number of 1-to-1, community, and legacy group conversations, respectively.
    size_t size_1to1() const;
    size_t size_communities() const;
    size_t size_legacy_groups() const;

    /// Returns true if the conversation list is empty.
    bool empty() const { return size() == 0; }

    /// Iterators for iterating through all conversations.  Typically you access this implicit via a
    /// for loop over the `ConvoInfoVolatile` object:
    ///
    ///     for (auto& convo : conversations) {
    ///         if (auto* dm = std::get_if<convo::one_to_one>(&convo)) {
    ///             // use dm->session_id, dm->last_read, etc.
    ///         } else if (auto* og = std::get_if<convo::community>(&convo)) {
    ///             // use og->base_url, og->room, om->last_read, etc.
    ///         } else if (auto* lcg = std::get_if<convo::legacy_group>(&convo)) {
    ///             // use lcg->id, lcg->last_read
    ///         }
    ///     }
    ///
    /// This iterates through all conversations in sorted order (sorted first by convo type, then by
    /// id within the type).
    ///
    /// It is permitted to modify and add records while iterating (e.g. by modifying one of the
    /// `dm`/`og`/`lcg` and then calling set()).
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
    /// through that vector calling `erase_1to1()`/`erase_community()`/`erase_legacy_group()` for
    /// each one.
    ///
    iterator begin() const { return iterator{data}; }
    iterator end() const { return iterator{}; }

    template <typename ConvoType>
    struct subtype_iterator;

    /// Returns an iterator that iterates only through one type of conversations
    subtype_iterator<convo::one_to_one> begin_1to1() const { return {data}; }
    subtype_iterator<convo::community> begin_communities() const { return {data}; }
    subtype_iterator<convo::legacy_group> begin_legacy_groups() const { return {data}; }

    using iterator_category = std::input_iterator_tag;
    using value_type = std::variant<convo::one_to_one, convo::community, convo::legacy_group>;
    using reference = value_type&;
    using pointer = value_type*;
    using difference_type = std::ptrdiff_t;

    struct iterator {
      protected:
        std::shared_ptr<convo::any> _val;
        std::optional<dict::const_iterator> _it_11, _end_11, _it_lgroup, _end_lgroup;
        std::optional<comm_iterator_helper> _it_comm;
        void _load_val();
        iterator() = default;  // Constructs an end tombstone
        explicit iterator(
                const DictFieldRoot& data,
                bool oneto1 = true,
                bool communities = true,
                bool legacy_groups = true);
        friend class ConvoInfoVolatile;

      public:
        bool operator==(const iterator& other) const;
        bool operator!=(const iterator& other) const { return !(*this == other); }
        bool done() const;  // Equivalent to comparing against the end iterator
        convo::any& operator*() const { return *_val; }
        convo::any* operator->() const { return _val.get(); }
        iterator& operator++();
        iterator operator++(int) {
            auto copy{*this};
            ++*this;
            return copy;
        }
    };

    template <typename ConvoType>
    struct subtype_iterator : iterator {
      protected:
        subtype_iterator(const DictFieldRoot& data) :
                iterator(
                        data,
                        std::is_same_v<convo::one_to_one, ConvoType>,
                        std::is_same_v<convo::community, ConvoType>,
                        std::is_same_v<convo::legacy_group, ConvoType>) {}
        friend class ConvoInfoVolatile;

      public:
        ConvoType& operator*() const { return std::get<ConvoType>(*_val); }
        ConvoType* operator->() const { return &std::get<ConvoType>(*_val); }
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
