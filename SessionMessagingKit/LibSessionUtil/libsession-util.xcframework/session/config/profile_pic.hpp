#pragma once

#include "session/types.hpp"

namespace session::config {

// Profile pic info.  Note that `url` is null terminated (though the null lies just beyond the end
// of the string view: that is, it views into a full std::string).
struct profile_pic {
  private:
    std::string url_;
    ustring key_;

  public:
    std::string_view url;
    ustring_view key;

    // Default constructor, makes an empty profile pic
    profile_pic() = default;

    // Constructs from string views: the values must stay alive for the duration of the profile_pic
    // instance.  (If not, use `set_url`/`set_key` or the rvalue-argument constructor instead).
    profile_pic(std::string_view url, ustring_view key) : url{url}, key{key} {}

    // Constructs from temporary strings; the strings are stored/managed internally
    profile_pic(std::string&& url, ustring&& key) :
            url_{std::move(url)}, key_{std::move(key)}, url{url_}, key{key_} {}

    // Returns true if either url or key are empty
    bool empty() const { return url.empty() || key.empty(); }

    // Sets the url or key to a temporary value that needs to be copied and owned by this
    // profile_pic object.  (This is only needed when the source string may not outlive the
    // profile_pic object; if it does, the `url` or `key` can be assigned to directly).
    void set_url(std::string url);
    void set_key(ustring key);
};

}  // namespace session::config
