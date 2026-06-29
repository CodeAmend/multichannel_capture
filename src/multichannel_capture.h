#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>

#if _WIN32
#include <windows.h>
#else
#include <pthread.h>
#include <unistd.h>
#endif

#if _WIN32
#define FFI_PLUGIN_EXPORT __declspec(dllexport)
#else
#define FFI_PLUGIN_EXPORT
#endif

// A very short-lived native function.
//
// For very short-lived functions, it is fine to call them on the main isolate.
// They will block the Dart execution while running the native function, so
// only do this for native functions which are guaranteed to be short-lived.
FFI_PLUGIN_EXPORT int sum(int a, int b);

// A longer lived native function, which occupies the thread calling it.
//
// Do not call these kind of native functions in the main isolate. They will
// block Dart execution. This will cause dropped frames in Flutter applications.
// Instead, call these native functions on a separate isolate.
FFI_PLUGIN_EXPORT int sum_long_running(int a, int b);

// Returns the version string of the bundled miniaudio library, e.g. "0.11.25".
//
// Smoke test confirming the miniaudio backend is compiled and linked. The
// returned pointer is static storage owned by miniaudio; do not free it.
FFI_PLUGIN_EXPORT const char *mc_version(void);

// (Re)enumerate input (capture) devices into an internal cache. Returns the
// number of devices found, or -1 on error. Call before the accessors below,
// and again to refresh after hardware changes.
FFI_PLUGIN_EXPORT int mc_refresh_input_devices(void);

// Number of input devices from the last mc_refresh_input_devices() call.
FFI_PLUGIN_EXPORT int mc_input_device_count(void);

// Name of the input device at `index`, or NULL if out of range. Owned by the
// native side; copy it, do not free it.
FFI_PLUGIN_EXPORT const char *mc_input_device_name(int index);

// Whether the input device at `index` is the system default (1) or not (0).
FFI_PLUGIN_EXPORT int mc_input_device_is_default(int index);

// Native channel count of the input device at `index`, or -1 on error.
// 0 means miniaudio reports "all channel counts supported".
FFI_PLUGIN_EXPORT int mc_input_device_channels(int index);
