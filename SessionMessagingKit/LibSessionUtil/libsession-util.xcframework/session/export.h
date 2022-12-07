#pragma once

#if defined(_WIN32) || defined(WIN32)
#define LIBSESSION_EXPORT __declspec(dllexport)
#else
#define LIBSESSION_EXPORT __attribute__((visibility("default")))
#endif
#define LIBSESSION_C_API extern "C" LIBSESSION_EXPORT
