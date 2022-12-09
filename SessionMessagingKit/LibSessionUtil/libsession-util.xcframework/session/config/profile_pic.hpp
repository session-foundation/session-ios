#pragma once

#include "session/types.hpp"

namespace session::config {
// Profile pic info.  Note that `url` is null terminated (though the null lies just beyond the end
// of the string view: that is, it views into a full std::string).
struct profile_pic {
    std::string_view url;
    ustring_view key;

    profile_pic(std::string_view url, ustring_view key) : url{url}, key{key} {}

    // Returns true if either url or key are empty
    bool empty() const { return url.empty() || key.empty(); }

    // Guard against accidentally passing in a temporary string or ustring:
    template <
            typename UrlType,
            typename KeyType,
            std::enable_if_t<
                    std::is_same_v<UrlType, std::string> || std::is_same_v<KeyType, ustring>>>
    profile_pic(UrlType&& url, KeyType&& key) = delete;
};

}  // namespace session::config
