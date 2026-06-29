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

// ---------------------------------------------------------------------------
// Input (capture) device enumeration.
//
// miniaudio hands back an array of ma_device_info owned by the context; those
// pointers stay valid until the next enumeration or until the context is torn
// down. We therefore keep one long-lived context and cache the capture array,
// exposing it to Dart through simple index-based accessors (the device id is a
// fat opaque union that does not marshal cleanly across FFI, so we keep it on
// the C side and refer to devices by index).
// ---------------------------------------------------------------------------

static ma_context g_context;
static ma_bool32 g_context_inited = MA_FALSE;
static ma_device_info *g_capture_infos = NULL;
static ma_uint32 g_capture_count = 0;

// (Re)enumerate input devices. Returns the number of capture devices found,
// or -1 on error. Must be called before the accessors below; call again to
// pick up hardware that was plugged in or removed.
FFI_PLUGIN_EXPORT int mc_refresh_input_devices(void) {
  if (!g_context_inited) {
    if (ma_context_init(NULL, 0, NULL, &g_context) != MA_SUCCESS) {
      return -1;
    }
    g_context_inited = MA_TRUE;
  }

  ma_device_info *playback_infos = NULL;
  ma_uint32 playback_count = 0;
  if (ma_context_get_devices(&g_context, &playback_infos, &playback_count,
                             &g_capture_infos, &g_capture_count) != MA_SUCCESS) {
    g_capture_infos = NULL;
    g_capture_count = 0;
    return -1;
  }
  return (int)g_capture_count;
}

// Number of input devices found by the last mc_refresh_input_devices() call.
FFI_PLUGIN_EXPORT int mc_input_device_count(void) {
  return (int)g_capture_count;
}

// Name of the input device at `index`, or NULL if out of range. The returned
// pointer is owned by miniaudio's context; copy it, do not free it.
FFI_PLUGIN_EXPORT const char *mc_input_device_name(int index) {
  if (index < 0 || (ma_uint32)index >= g_capture_count) {
    return NULL;
  }
  return g_capture_infos[index].name;
}

// Whether the input device at `index` is the system default (1) or not (0).
// Returns 0 for an out-of-range index.
FFI_PLUGIN_EXPORT int mc_input_device_is_default(int index) {
  if (index < 0 || (ma_uint32)index >= g_capture_count) {
    return 0;
  }
  return g_capture_infos[index].isDefault ? 1 : 0;
}

// Native channel count of the input device at `index`, or -1 on error. The
// channel count is not filled in during plain enumeration, so this queries the
// device's full info on demand. A value of 0 means "all channel counts
// supported" (miniaudio's wildcard).
FFI_PLUGIN_EXPORT int mc_input_device_channels(int index) {
  if (index < 0 || (ma_uint32)index >= g_capture_count) {
    return -1;
  }
  ma_device_info info;
  if (ma_context_get_device_info(&g_context, ma_device_type_capture,
                                 &g_capture_infos[index].id,
                                 &info) != MA_SUCCESS) {
    return -1;
  }
  if (info.nativeDataFormatCount == 0) {
    return 0;
  }
  return (int)info.nativeDataFormats[0].channels;
}
