#include "multichannel_capture.h"

#include <stdatomic.h>
#include <string.h>

// Raw host-clock reading in the platform's native "system units". On Apple this is
// mach_absolute_time() — the exact currency CMClockMakeHostTimeFromSystemUnits
// consumes and the clock CMClockGetHostTimeClock stamps video PTS on, so audio and
// video land on one timeline with zero conversion. (Non-Apple builds fall back to a
// monotonic nanosecond clock so the source still compiles; the package ships macOS
// only, where the mach path is the real one.)
#if defined(__APPLE__)
#include <mach/mach_time.h>
static inline uint64_t mc_host_now(void) { return mach_absolute_time(); }
#else
#include <time.h>
static inline uint64_t mc_host_now(void) {
  struct timespec ts;
  clock_gettime(CLOCK_MONOTONIC, &ts);
  return (uint64_t)ts.tv_sec * 1000000000ull + (uint64_t)ts.tv_nsec;
}
#endif

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

// ---------------------------------------------------------------------------
// Timed capture: companion anchor ring (Phase 5).
//
// The engine ALWAYS anchors — an unconditional side-channel to the untimed path,
// which reads the PCM ring exactly as before and never consults these. Every
// callback that commits >=1 frame stamps one anchor mapping the cumulative
// WRITTEN-frame index of its first committed frame to a raw host-time reading
// taken at the top of that callback.
//
// The anchor index is cumulative frames WRITTEN to the ring (post-drop), which
// equals the drain-side delivered index ONLY because the PCM ring is lossless
// FIFO: every committed frame drains in order, and drops happen before the index
// advances. Advance g_frames_committed by frames *committed*, never by the
// callback's frameCount.
//
// INVARIANT (see docs/PROPOSAL-timestamps.md): the anchor ring must OUT-SPAN the
// PCM ring. MC_ANCHOR_CAPACITY anchors at ~one-per-callback (~10ms) ≈ 2.5s of
// slack, comfortably longer than the PCM ring's ~0.34s (MC_RB_CAPACITY_FRAMES) —
// so the reader, which lags by at most one PCM-ring depth, always finds live
// anchors bracketing the frame it is placing, even mid-stall. If either ring is
// resized, preserve this relationship.
// ---------------------------------------------------------------------------
#define MC_ANCHOR_CAPACITY 256

#include "mc_anchor.h"  // mc_anchor + the pure, unit-tested mc_interp().

static mc_anchor g_anchors[MC_ANCHOR_CAPACITY];
static _Atomic uint64_t g_anchor_seq = 0;  // total anchors ever written; newest slot = (seq-1) % CAP
static uint64_t g_frames_committed = 0;    // audio-thread only: cumulative frames written to the ring
static uint64_t g_frames_read = 0;         // timed-reader only: cumulative frames drained
static _Atomic uint64_t g_dropped = 0;     // cumulative frames dropped on ring overflow

// Interpolate the host time of delivered frame `R` from the anchor ring. Returns 1
// and writes *out_host on success, 0 if no anchors exist yet. The reader lags the
// writer by well under the anchor span, so the slots it touches are quiescent; a
// bounded retry re-checks the sequence in case a wrap raced the read.
static int mc_interpolate_host_time(uint64_t R, uint64_t *out_host) {
  for (int attempt = 0; attempt < 4; attempt++) {
    uint64_t seq0 = atomic_load_explicit(&g_anchor_seq, memory_order_acquire);
    if (seq0 == 0) {
      return 0;
    }
    uint64_t n = (seq0 < MC_ANCHOR_CAPACITY) ? seq0 : MC_ANCHOR_CAPACITY;
    uint64_t oldest = seq0 - n;

    uint64_t host;
    const int ok = mc_interp(g_anchors, MC_ANCHOR_CAPACITY, seq0, R, &host);

    // Retry if the writer wrapped over the window we just read (the reader lags well
    // under the anchor span, so this effectively never fires).
    uint64_t seq1 = atomic_load_explicit(&g_anchor_seq, memory_order_acquire);
    if (seq1 - oldest > MC_ANCHOR_CAPACITY) {
      continue;
    }
    if (!ok) {
      return 0;
    }
    *out_host = host;
    return 1;
  }
  return 0;
}

// Runs on the native audio thread. Keep it allocation-free and non-blocking.
static void mc_capture_data_callback(ma_device *pDevice, void *pOutput,
                                     const void *pInput, ma_uint32 frameCount) {
  (void)pOutput; // capture-only device: no output to fill.

  // Anchor: raw host time at callback entry (a commpage read, no syscall) plus the
  // cumulative WRITTEN index this callback's first committed frame will take.
  const uint64_t hostTime = mc_host_now();
  const uint64_t firstIndex = g_frames_committed;

  const ma_uint32 bytesPerFrame = g_capture_channels * (ma_uint32)sizeof(float);
  const ma_uint8 *src = (const ma_uint8 *)pInput;
  ma_uint32 framesRemaining = frameCount;
  ma_uint32 committed = 0;

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
    committed += framesToWrite;
  }

  // Anything not committed was dropped on overflow.
  if (framesRemaining > 0) {
    atomic_fetch_add_explicit(&g_dropped, framesRemaining, memory_order_relaxed);
  }

  // Publish an anchor ONLY when this callback committed >=1 frame. A fully-dropped
  // callback must not publish, or sustained overflow yields multiple anchors sharing
  // one frameIndex and interpolation degenerates. This keeps frameIndex strictly
  // increasing. Write the slot, then release-store the sequence so the reader sees
  // a fully-written anchor.
  if (committed > 0) {
    uint64_t seq = atomic_load_explicit(&g_anchor_seq, memory_order_relaxed);
    uint64_t slot = seq % MC_ANCHOR_CAPACITY;
    g_anchors[slot].frameIndex = firstIndex;
    g_anchors[slot].hostTime = hostTime;
    atomic_store_explicit(&g_anchor_seq, seq + 1, memory_order_release);
    g_frames_committed = firstIndex + committed;
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

  // Reset timed-capture state for the new session.
  g_frames_committed = 0;
  g_frames_read = 0;
  atomic_store_explicit(&g_dropped, 0, memory_order_relaxed);
  atomic_store_explicit(&g_anchor_seq, 0, memory_order_release);

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

// Timed peer of mc_read_frames. Computes the host time of the first delivered frame
// in this batch BEFORE draining (from the anchor ring), then drains the same PCM
// ring identically and advances the delivered-frame counter. See the header for the
// out-param contract and the sole-drainer requirement.
FFI_PLUGIN_EXPORT int mc_read_frames_timed(float *out_buffer, int max_frames,
                                           uint64_t *out_host_time,
                                           uint64_t *out_first_frame_index) {
  if (!g_capture_active) {
    return -1;
  }
  if (out_buffer == NULL || max_frames <= 0) {
    return 0;
  }

  const uint64_t firstIndex = g_frames_read; // first delivered frame of this batch.
  uint64_t hostTime = 0;
  const int haveTime = mc_interpolate_host_time(firstIndex, &hostTime);

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

  if (totalRead > 0) {
    g_frames_read += totalRead;
    if (out_first_frame_index != NULL) {
      *out_first_frame_index = firstIndex;
    }
    if (out_host_time != NULL) {
      *out_host_time = haveTime ? hostTime : 0;
    }
  }

  return (int)totalRead;
}

// Cumulative frames dropped on ring overflow since capture start.
FFI_PLUGIN_EXPORT uint64_t mc_capture_dropped_frames(void) {
  return atomic_load_explicit(&g_dropped, memory_order_relaxed);
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
