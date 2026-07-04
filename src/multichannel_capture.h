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

// Notification invoked from the audio thread when captured frames are
// available to drain. On the Dart side this is a NativeCallable.listener.
typedef void (*mc_data_ready_callback)(void);

// Open the input device at `device_index` (or the system default if out of
// range / negative) and start capturing interleaved 32-bit float PCM. Pass 0
// for sample_rate/channels to accept the device's native values. Returns 0 on
// success, -1 on error. Enumerate first to select a device by index.
FFI_PLUGIN_EXPORT int mc_start_capture(int device_index, int sample_rate,
                                       int channels,
                                       mc_data_ready_callback on_data_ready);

// Drain up to `max_frames` of captured audio into `out_buffer` (interleaved
// f32; must hold max_frames * channels floats). Returns frames written, or -1
// if not capturing.
FFI_PLUGIN_EXPORT int mc_read_frames(float *out_buffer, int max_frames);

// Timed peer of mc_read_frames: drains the SAME PCM ring, and additionally
// reports the host-clock time of the FIRST frame in the returned batch plus that
// frame's cumulative index since capture start.
//
// `*out_host_time` is in RAW mach host-time units (the value mach_absolute_time()
// returns — the same clock CMClockGetHostTimeClock stamps video PTS on; feed it to
// CMClockMakeHostTimeFromSystemUnits, do NOT assume nanoseconds). `*out_first_frame_index`
// is the cumulative count of frames DELIVERED before this batch (monotonic,
// continuous, never skips — a drop puts no hole in it; drops surface via
// mc_capture_dropped_frames). Both out-params are written only when the return
// value is > 0. Returns frames written, or -1 if not capturing.
//
// This reader assumes it is the sole drainer of the ring for the session (the Dart
// layer enforces one active stream per capture). Do NOT interleave it with
// mc_read_frames on the same session, or the delivered index desyncs.
FFI_PLUGIN_EXPORT int mc_read_frames_timed(float *out_buffer, int max_frames,
                                           uint64_t *out_host_time,
                                           uint64_t *out_first_frame_index);

// Cumulative count of frames the device delivered that were DROPPED because the
// PCM ring was full, since capture start. 0 in a healthy session. A muxer can
// insert exactly this much silence to keep audio length == wall-clock length.
FFI_PLUGIN_EXPORT uint64_t mc_capture_dropped_frames(void);

// Stop capturing and release the device + ring buffer. Returns 0.
FFI_PLUGIN_EXPORT int mc_stop_capture(void);

// Actual channel count of the running capture, or 0 if not capturing.
FFI_PLUGIN_EXPORT int mc_capture_channels(void);

// Actual sample rate of the running capture, or 0 if not capturing.
FFI_PLUGIN_EXPORT int mc_capture_sample_rate(void);
