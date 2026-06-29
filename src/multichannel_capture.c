#include "multichannel_capture.h"

#include <string.h>

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

// ---------------------------------------------------------------------------
// PCM capture.
//
// Audio is always captured as interleaved 32-bit float (ma_format_f32). The
// miniaudio capture callback runs on a high-priority native audio thread; it
// must never block or allocate. So the callback does only two cheap things:
//   1. copy the incoming frames into a lock-free SPSC ring buffer, and
//   2. ping Dart via a registered callback to say "frames are available".
// Dart then drains the ring buffer at its leisure via mc_read_frames(), fully
// decoupling the audio thread from Dart's event loop and garbage collector.
// ---------------------------------------------------------------------------

#define MC_CAPTURE_FORMAT ma_format_f32

// Ring buffer capacity in frames. ~16k frames ≈ 0.34s at 48kHz, plenty of
// slack for Dart to drain between audio callbacks without overflowing.
#define MC_RB_CAPACITY_FRAMES 16384

// Signature of the "frames available" notification handed to mc_start_capture.
// On the Dart side this is a NativeCallable.listener, safe to invoke from the
// audio thread; it simply wakes Dart to drain the ring buffer.
typedef void (*mc_data_ready_callback)(void);

static ma_device g_capture_device;
static ma_pcm_rb g_capture_rb;
static ma_bool32 g_capture_active = MA_FALSE;
static ma_uint32 g_capture_channels = 0;
static ma_uint32 g_capture_sample_rate = 0;
static mc_data_ready_callback g_data_ready_cb = NULL;

// Runs on the native audio thread. Keep it allocation-free and non-blocking.
static void mc_capture_data_callback(ma_device *pDevice, void *pOutput,
                                     const void *pInput, ma_uint32 frameCount) {
  (void)pOutput; // capture-only device: no output to fill.

  const ma_uint32 bytesPerFrame = g_capture_channels * (ma_uint32)sizeof(float);
  const ma_uint8 *src = (const ma_uint8 *)pInput;
  ma_uint32 framesRemaining = frameCount;

  while (framesRemaining > 0) {
    ma_uint32 framesToWrite = framesRemaining;
    void *pWrite = NULL;
    if (ma_pcm_rb_acquire_write(&g_capture_rb, &framesToWrite, &pWrite) !=
        MA_SUCCESS) {
      break;
    }
    if (framesToWrite == 0) {
      break; // Ring buffer full: drop the rest (Dart isn't draining fast enough).
    }
    memcpy(pWrite, src, framesToWrite * bytesPerFrame);
    ma_pcm_rb_commit_write(&g_capture_rb, framesToWrite);
    src += framesToWrite * bytesPerFrame;
    framesRemaining -= framesToWrite;
  }

  if (g_data_ready_cb != NULL) {
    g_data_ready_cb();
  }
}

// Open the input device at `device_index` (or the system default if the index
// is out of range / negative) and begin capturing. Pass sample_rate/channels
// of 0 to accept the device's native value. `on_data_ready` is pinged from the
// audio thread whenever frames are available. Returns 0 on success, -1 on
// error. Enumerate first (mc_refresh_input_devices) to select by index.
FFI_PLUGIN_EXPORT int mc_start_capture(int device_index, int sample_rate,
                                       int channels,
                                       mc_data_ready_callback on_data_ready) {
  if (g_capture_active) {
    return -1; // Already capturing; stop first.
  }
  if (!g_context_inited) {
    if (ma_context_init(NULL, 0, NULL, &g_context) != MA_SUCCESS) {
      return -1;
    }
    g_context_inited = MA_TRUE;
  }

  ma_device_config config = ma_device_config_init(ma_device_type_capture);
  config.capture.format = MC_CAPTURE_FORMAT;
  config.capture.channels = (channels > 0) ? (ma_uint32)channels : 0;
  config.sampleRate = (sample_rate > 0) ? (ma_uint32)sample_rate : 0;
  config.dataCallback = mc_capture_data_callback;
  if (device_index >= 0 && (ma_uint32)device_index < g_capture_count &&
      g_capture_infos != NULL) {
    config.capture.pDeviceID = &g_capture_infos[device_index].id;
  }

  if (ma_device_init(&g_context, &config, &g_capture_device) != MA_SUCCESS) {
    return -1;
  }

  g_capture_channels = g_capture_device.capture.channels;
  g_capture_sample_rate = g_capture_device.sampleRate;
  g_data_ready_cb = on_data_ready;

  if (ma_pcm_rb_init(MC_CAPTURE_FORMAT, g_capture_channels,
                     MC_RB_CAPACITY_FRAMES, NULL, NULL,
                     &g_capture_rb) != MA_SUCCESS) {
    ma_device_uninit(&g_capture_device);
    g_data_ready_cb = NULL;
    return -1;
  }

  if (ma_device_start(&g_capture_device) != MA_SUCCESS) {
    ma_pcm_rb_uninit(&g_capture_rb);
    ma_device_uninit(&g_capture_device);
    g_data_ready_cb = NULL;
    return -1;
  }

  g_capture_active = MA_TRUE;
  return 0;
}

// Drain up to `max_frames` of captured audio into `out_buffer` (interleaved
// f32, so it must hold max_frames * channels floats). Returns the number of
// frames written (0 if none buffered), or -1 if not currently capturing.
FFI_PLUGIN_EXPORT int mc_read_frames(float *out_buffer, int max_frames) {
  if (!g_capture_active) {
    return -1;
  }
  if (out_buffer == NULL || max_frames <= 0) {
    return 0;
  }

  const ma_uint32 bytesPerFrame = g_capture_channels * (ma_uint32)sizeof(float);
  ma_uint8 *dst = (ma_uint8 *)out_buffer;
  ma_uint32 framesRemaining = (ma_uint32)max_frames;
  ma_uint32 totalRead = 0;

  while (framesRemaining > 0) {
    ma_uint32 framesToRead = framesRemaining;
    void *pRead = NULL;
    if (ma_pcm_rb_acquire_read(&g_capture_rb, &framesToRead, &pRead) !=
        MA_SUCCESS) {
      break;
    }
    if (framesToRead == 0) {
      break; // Nothing more buffered.
    }
    memcpy(dst, pRead, framesToRead * bytesPerFrame);
    ma_pcm_rb_commit_read(&g_capture_rb, framesToRead);
    dst += framesToRead * bytesPerFrame;
    framesRemaining -= framesToRead;
    totalRead += framesToRead;
  }

  return (int)totalRead;
}

// Stop capturing and release the device + ring buffer. ma_device_uninit joins
// the audio thread before returning, so no callback can run after this point,
// making it safe to tear down the ring buffer. Returns 0 always.
FFI_PLUGIN_EXPORT int mc_stop_capture(void) {
  if (!g_capture_active) {
    return 0;
  }
  ma_device_uninit(&g_capture_device);
  ma_pcm_rb_uninit(&g_capture_rb);
  g_capture_active = MA_FALSE;
  g_data_ready_cb = NULL;
  g_capture_channels = 0;
  g_capture_sample_rate = 0;
  return 0;
}

// Actual channel count of the running capture, or 0 if not capturing.
FFI_PLUGIN_EXPORT int mc_capture_channels(void) {
  return (int)g_capture_channels;
}

// Actual sample rate of the running capture, or 0 if not capturing.
FFI_PLUGIN_EXPORT int mc_capture_sample_rate(void) {
  return (int)g_capture_sample_rate;
}
