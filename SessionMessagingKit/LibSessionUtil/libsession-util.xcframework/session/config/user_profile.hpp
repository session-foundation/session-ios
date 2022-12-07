#pragma once

#include <memory>
#include <session/config.hpp>

#include "base.hpp"
#include "namespaces.hpp"

namespace session::config {

/// keys used in this config, either currently or in the past (so that we don't reuse):
///
/// n - user profile name
/// p - user profile url
/// q - user profile decryption key (binary)

// Profile pic info.  Note that `url` is null terminated (though the null lies just beyond the end
// of the string view: that is, it views into a full std::string).
struct profile_pic {
    std::string_view url;
    ustring_view key;
};

class UserProfile final : public ConfigBase {

  public:
    // No default constructor
    UserProfile() = delete;

    /// Constructs a user profile from existing data (stored from `dump()`) and the user's secret
    /// key for generating the data encryption key.  To construct a blank profile (i.e. with no
    /// pre-existing dumped data to load) pass `std::nullopt` as the second argument.
    ///
    /// \param ed25519_secretkey - contains the libsodium secret key used to encrypt/decrypt user
    /// profile messages; these can either be the full 64-byte value (which is technically the
    /// 32-byte seed followed by the 32-byte pubkey), or just the 32-byte seed of the secret key.
    ///
    /// \param dumped - either `std::nullopt` to construct a new, empty user profile; or binary
    /// state data that was previously dumped from a UserProfile object by calling `dump()`.
    UserProfile(ustring_view ed25519_secretkey, std::optional<ustring_view> dumped);

    Namespace storage_namespace() const override { return Namespace::UserProfile; }

    const char* encryption_domain() const override { return "UserProfile"; }

    /// Returns the user profile name, or std::nullopt if there is no profile name set.
    const std::optional<std::string_view> get_name() const;

    /// Sets the user profile name; if given an empty string then the name is removed.
    void set_name(std::string_view new_name);

    /// Gets the user's current profile pic URL and decryption key.  Returns nullptr for *both*
    /// values if *either* value is unset or empty in the config data.
    std::optional<profile_pic> get_profile_pic() const;

    /// Sets the user's current profile pic to a new URL and decryption key.  Clears both if either
    /// one is empty.
    void set_profile_pic(std::string_view url, ustring_view key);
    void set_profile_pic(profile_pic pic);

  private:
    void load_key(ustring_view ed25519_secretkey);
};

}  // namespace session::config
