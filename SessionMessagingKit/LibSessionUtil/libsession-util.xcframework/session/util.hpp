#pragma once
#include "types.hpp"

namespace session {

// Helper function to go to/from char pointers to unsigned char pointers:
inline const unsigned char* to_unsigned(const char* x) {
    return reinterpret_cast<const unsigned char*>(x);
}
inline unsigned char* to_unsigned(char* x) {
    return reinterpret_cast<unsigned char*>(x);
}
inline const char* from_unsigned(const unsigned char* x) {
    return reinterpret_cast<const char*>(x);
}
inline char* from_unsigned(unsigned char* x) {
    return reinterpret_cast<char*>(x);
}
// Helper function to switch between string_view and ustring_view
inline ustring_view to_unsigned_sv(std::string_view v) {
    return {to_unsigned(v.data()), v.size()};
}
inline std::string_view from_unsigned_sv(ustring_view v) {
    return {from_unsigned(v.data()), v.size()};
}

}  // namespace session
