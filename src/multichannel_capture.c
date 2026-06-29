#include "multichannel_capture.h"

// Compile the miniaudio implementation into this translation unit. Exactly one
// .c file in the build must define MINIAUDIO_IMPLEMENTATION before including
// the header; everywhere else it is just declarations.
#define MINIAUDIO_IMPLEMENTATION
#include "miniaudio.h"

// A very short-lived native function.
//
// For very short-lived functions, it is fine to call them on the main isolate.
// They will block the Dart execution while running the native function, so
// only do this for native functions which are guaranteed to be short-lived.
FFI_PLUGIN_EXPORT int sum(int a, int b) { return a + b; }

// A longer-lived native function, which occupies the thread calling it.
//
// Do not call these kind of native functions in the main isolate. They will
// block Dart execution. This will cause dropped frames in Flutter applications.
// Instead, call these native functions on a separate isolate.
FFI_PLUGIN_EXPORT int sum_long_running(int a, int b) {
  // Simulate work.
#if _WIN32
  Sleep(5000);
#else
  usleep(5000 * 1000);
#endif
  return a + b;
}

// Smoke test: prove miniaudio is linked by returning its version string.
FFI_PLUGIN_EXPORT const char *mc_version(void) { return ma_version_string(); }
