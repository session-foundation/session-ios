#pragma once

#include <chrono>
#include <cstddef>
#include <iterator>
#include <memory>
#include <session/config.hpp>

#include "base.hpp"

extern "C" {
struct convo_info_volatile_1to1;
struct convo_info_volatile_open;
struct convo_info_volatile_legacy_closed;
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
/// o - open group conversations.  Each key is: BASE_URL + '\0' + LC_ROOM_NAME + '\0' +
///     SERVER_PUBKEY (in bytes).  Note that room name is *always* lower-cased here (so that clients
///     with the same room but with different cases will always set the same key).  Values are dicts
///     with keys:
///     r - the unix timestamp (in integer milliseconds) of the last-read message.  Always included,
///         but will be 0 if no messages are read.
///     u - will be present and set to 1 if this conversation is specifically marked unread.
///
/// C - legacy closed group conversations.  The key is the closed group identifier (which looks
///     indistinguishable from a Session ID, but isn't really a proper Session ID).  Values are
///     dicts with keys:
///     r - the unix timestamp (integer milliseconds) of the last-read message.  Always included,
///         but will be 0 if no messages are read.
///     u - will be present and set to 1 if this conversation is specifically marked unread.
///
/// c - reserved for future tracking of new closed group conversations.

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

    struct open_group : base {
        // 267 = len('https://') + 253 (max valid DNS name length) + len(':XXXXX')
        static constexpr size_t MAX_URL = 267, MAX_ROOM = 64;

        std::string_view base_url() const;  // Accesses the base url (i.e. not including room or
                                            // pubkey). Always lower-case.
        std::string_view room()
                const;  // Accesses the room name, always in lower-case.  (Note that the
                        // actual open group info might not be lower-case; it is just in
                        // the open group convo where we force it lower-case).
        ustring_view pubkey() const;     // Accesses the server pubkey (32 bytes).
        std::string pubkey_hex() const;  // Accesses the server pubkey as hex (64 hex digits).

        open_group() = default;

        // Constructs an empty open_group convo struct from url, room, and pubkey.  `base_url` and
        // `room` will be lower-cased if not already (they do not have to be passed lower-case).
        // pubkey is 32 bytes.
        open_group(std::string_view base_url, std::string_view room, ustring_view pubkey);

        // Same as above, but takes pubkey as a hex string.
        open_group(std::string_view base_url, std::string_view room, std::string_view pubkey_hex);

        // Takes a combined room URL (e.g. https://whatever.com/r/Room?public_key=01234....), either
        // new style (with /r/) or old style (without /r/).  Note that the URL gets canonicalized so
        // the resulting `base_url()` and `room()` values may not be exactly equal to what is given.
        //
        // See also `parse_full_url` which does the same thing but returns it in pieces rather than
        // constructing a new `open_group` object.
        explicit open_group(std::string_view full_url);

        // Internal ctor/method for C API implementations:
        open_group(const struct convo_info_volatile_open& c);  // From c struct
        void into(convo_info_volatile_open& c) const;          // Into c struct

        // Replaces the baseurl/room/pubkey of this object.  Note that changing this and then giving
        // it to `set` will end up inserting a *new* record but not removing the *old* one (you need
        // to erase first to do that).
        void set_server(std::string_view base_url, std::string_view room, ustring_view pubkey);
        void set_server(
                std::string_view base_url, std::string_view room, std::string_view pubkey_hex);
        void set_server(std::string_view full_url);

        // Loads the baseurl/room/pubkey of this object from an encoded key.  Throws
        // std::invalid_argument if the encoded key does not look right.
        void load_encoded_key(std::string key);

        // Takes a base URL as input and returns it in canonical form.  This involves doing things
        // like lower casing it and removing redundant ports (e.g. :80 when using http://).
        static std::string canonical_url(std::string_view url);

        // Takes a full room URL, splits it up into canonical url (see above), lower-case room
        // token, and server pubkey.  We take both the deprecated form (e.g.
        // https://example.com/SomeRoom?public_key=...) and new form
        // (https://example.com/r/SomeRoom?public_key=...).  The public_key is typically specified
        // in hex (64 digits), but we also accept unpadded base64 (43 chars) and base32z (52 chars)
        // encodings (for slightly shorter URLs).
        static std::tuple<std::string, std::string, ustring> parse_full_url(
                std::string_view full_url);

      private:
        std::string key;
        size_t url_size = 0;

        friend class session::config::ConvoInfoVolatile;

        // Returns the key value we use in the stored dict for this open group, i.e.
        // lc(URL) + lc(NAME) + PUBKEY_BYTES.
        static std::string make_key(
                std::string_view base_url, std::string_view room, std::string_view pubkey_hex);
        static std::string make_key(
                std::string_view base_url, std::string_view room, ustring_view pubkey);
    };

    struct legacy_closed_group : base {
        std::string id;  // in hex, indistinguishable from a Session ID

        // Constructs an empty legacy_closed_group from a quasi-session_id
        explicit legacy_closed_group(std::string&& group_id);
        explicit legacy_closed_group(std::string_view group_id);

        // Internal ctor/method for C API implementations:
        legacy_closed_group(const struct convo_info_volatile_legacy_closed& c);  // From c struct
        void into(convo_info_volatile_legacy_closed& c) const;                   // Into c struct

      private:
        friend class session::config::ConvoInfoVolatile;
    };

    using any = std::variant<one_to_one, open_group, legacy_closed_group>;
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

    /// Looks up and returns a contact by session ID (hex).  Returns nullopt if the session ID was
    /// not found, otherwise returns a filled out `convo::one_to_one`.
    std::optional<convo::one_to_one> get_1to1(std::string_view session_id) const;

    /// Looks up and returns an open group conversation.  Takes the base URL, room name (case
    /// insensitive), and pubkey (in hex).  Retuns nullopt if the open group was not found,
    /// otherwise a filled out `convo::open_group`.
    std::optional<convo::open_group> get_open(
            std::string_view base_url, std::string_view room, std::string_view pubkey_hex) const;

    /// Same as above, but takes the pubkey as bytes instead of hex
    std::optional<convo::open_group> get_open(
            std::string_view base_url, std::string_view room, ustring_view pubkey) const;

    /// Looks up and returns a legacy closed group conversation by ID.  The ID looks like a hex
    /// Session ID, but isn't really a Session ID.  Returns nullopt if there is no record of the
    /// closed group conversation.
    std::optional<convo::legacy_closed_group> get_legacy_closed(std::string_view pubkey_hex) const;

    /// These are the same as the above methods (without "_or_construct" in the name), except that
    /// when the conversation doesn't exist a new one is created, prefilled with the pubkey/url/etc.
    convo::one_to_one get_or_construct_1to1(std::string_view session_id) const;
    convo::open_group get_or_construct_open(
            std::string_view base_url, std::string_view room, std::string_view pubkey_hex) const;
    convo::open_group get_or_construct_open(
            std::string_view base_url, std::string_view room, ustring_view pubkey) const;
    convo::legacy_closed_group get_or_construct_legacy_closed(std::string_view pubkey_hex) const;

    /// Inserts or replaces existing conversation info.  For example, to update a 1-to-1
    /// conversation last read time you would do:
    ///
    ///     auto info = conversations.get_or_construct_1to1(some_session_id);
    ///     info.last_read = new_unix_timestamp;
    ///     conversations.set(info);
    ///
    void set(const convo::one_to_one& c);
    void set(const convo::legacy_closed_group& c);
    void set(const convo::open_group& c);

    void set(const convo::any& c);  // Variant which can be any of the above

  protected:
    void set_base(const convo::base& c, DictFieldProxy& info);

  public:
    /// Removes a one-to-one conversation.  Returns true if found and removed, false if not present.
    bool erase_1to1(std::string_view pubkey);

    /// Removes an open group conversation record.  Returns true if found and removed, false if not
    /// present.  Arguments are the same as `get_open`.
    bool erase_open(std::string_view base_url, std::string_view room, std::string_view pubkey_hex);
    bool erase_open(std::string_view base_url, std::string_view room, ustring_view pubkey);

    /// Removes a legacy closed group conversation.  Returns true if found and removed, false if not
    /// present.
    bool erase_legacy_closed(std::string_view pubkey_hex);

    /// Removes a conversation taking the convo::whatever record (rather than the pubkey/url).
    bool erase(const convo::one_to_one& c);
    bool erase(const convo::open_group& c);
    bool erase(const convo::legacy_closed_group& c);

    bool erase(const convo::any& c);  // Variant of any of them

    struct iterator;

    /// This works like erase, but takes an iterator to the conversation to remove.  The element is
    /// removed and the iterator to the next element after the removed one is returned.  This is
    /// intended for use where elements are to be removed during iteration: see below for an
    /// example.
    iterator erase(iterator it);

    /// Returns the number of conversations (of any type).
    size_t size() const;

    /// Returns the number of 1-to-1, open group, and legacy closed group conversations,
    /// respectively.
    size_t size_1to1() const;
    size_t size_open() const;
    size_t size_legacy_closed() const;

    /// Returns true if the conversation list is empty.
    bool empty() const { return size() == 0; }

    /// Iterators for iterating through all conversations.  Typically you access this implicit via a
    /// for loop over the `ConvoInfoVolatile` object:
    ///
    ///     for (auto& convo : conversations) {
    ///         if (auto* dm = std::get_if<convo::one_to_one>(&convo)) {
    ///             // use dm->session_id, dm->last_read, etc.
    ///         } else if (auto* og = std::get_if<convo::open_group>(&convo)) {
    ///             // use og->base_url, og->room, om->last_read, etc.
    ///         } else if (auto* lcg = std::get_if<convo::legacy_closed_group>(&convo)) {
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
    /// through that vector calling `erase_1to1()`/`erase_open()`/`erase_legacy_closed()` for each
    /// one.
    ///
    iterator begin() const { return iterator{data}; }
    iterator end() const { return iterator{}; }

    template <typename ConvoType>
    struct subtype_iterator;

    /// Returns an iterator that iterates only through one type of conversations
    subtype_iterator<convo::one_to_one> begin_1to1() const { return {data}; }
    subtype_iterator<convo::open_group> begin_open() const { return {data}; }
    subtype_iterator<convo::legacy_closed_group> begin_legacy_closed() const { return {data}; }

    using iterator_category = std::input_iterator_tag;
    using value_type =
            std::variant<convo::one_to_one, convo::open_group, convo::legacy_closed_group>;
    using reference = value_type&;
    using pointer = value_type*;
    using difference_type = std::ptrdiff_t;

    struct iterator {
      protected:
        std::shared_ptr<convo::any> _val;
        std::optional<dict::const_iterator> _it_11, _end_11, _it_open, _end_open, _it_lclosed,
                _end_lclosed;
        void _load_val();
        iterator() = default;  // Constructs an end tombstone
        explicit iterator(
                const DictFieldRoot& data,
                bool oneto1 = true,
                bool open = true,
                bool closed = true);
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
                        std::is_same_v<convo::open_group, ConvoType>,
                        std::is_same_v<convo::legacy_closed_group, ConvoType>) {}
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
