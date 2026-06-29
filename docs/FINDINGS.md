# Findings: quirks, limitations, difficulties & lessons

A running log of things discovered while building this plugin — the stuff that
isn't obvious from the code and would cost hours to rediscover. Newest entries
can go at the top of each section. Each entry notes the phase it surfaced in.

---

## Quirks (surprising behaviour that is *working as the platform intends*)

### miniaudio marks more than one input device as "default" (Phase 2)
On macOS, `isDefault` is **not unique** in the capture list. miniaudio's Core
Audio enumeration zeroes its `info` struct once per *device*, but runs each
device through both the playback and capture callbacks. A device that is the
default **output** *and* also supports input (e.g. a loopback driver) keeps the
default flag set when it reaches the capture list.

- Real example: with a Scarlett 4i4 (true default input) and a "One Source
  Loopback" (default *output*, 4 input channels), **both** report
  `isDefault: true`.
- miniaudio source: `ma_context_enumerate_devices__coreaudio`
  ([src/miniaudio.h](../src/miniaudio.h) ~line 34719) — the capture branch never
  resets `info.isDefault`.
- **Consequence:** treat `isDefault` as a UI hint only. To capture from the real
  default mic, open a **null device id** (Core Audio resolves the true default),
  never pick the `isDefault == true` entry. See `CaptureDevice.isDefault`.

---

## Limitations (things we don't / can't do yet)

- **macOS only.** iOS/Windows/Linux are not wired up. macOS frameworks are
  linked via the podspec; other platforms need their own build config + backends.
- **Device index is ephemeral.** `CaptureDevice.index` is only valid until the
  next `listInputDevices()` call (it indexes into miniaudio's context-owned
  array). Don't persist it across a refresh.
- **`channels == 0` means "any", not "none".** miniaudio uses 0 as a wildcard
  meaning the device supports all channel counts. The API surfaces this raw;
  callers must interpret it.
- **`isDefault` is unreliable for selection** (see Quirks).

---

## Difficulties (things that were non-obvious to get working)

### macOS native code builds via the podspec, not CMakeLists (Phase 1)
`src/CMakeLists.txt` is for Android/Linux/Windows. On macOS/iOS the C is
compiled through the **podspec**, so that's where miniaudio's system frameworks
must be linked: `CoreFoundation`, `CoreAudio`, `AudioToolbox`, `AudioUnit`.
Without them the build *compiles* but **fails to link** with missing symbols —
even just to call `ma_version_string()`, because `MINIAUDIO_IMPLEMENTATION`
compiles the whole Core Audio backend.

### FFI string marshalling needs `package:ffi`, at runtime (Phase 1)
`dart:ffi` (built-in) gives you `Pointer<Char>`, but converting to a Dart
`String` needs `Utf8` from `package:ffi`. The template ships `ffi` only as a
**dev** dependency — it had to move to a **runtime** dependency since our library
code calls it. Pattern: `ptr.cast<Utf8>().toDartString()`.

### `ma_device_id` doesn't marshal across FFI (Phase 2)
The device id is a fat opaque **union** (256-byte custom field, per-backend
members). It does not cross the FFI boundary cleanly. So devices are kept on the
C side and referred to by **integer index**, with simple accessor functions —
rather than copying structs into Dart.

### Channel count isn't filled in during enumeration (Phase 2)
Plain `ma_context_get_devices` only guarantees `id`, `name`, `isDefault`. The
channel count requires a follow-up `ma_context_get_device_info` call per device.
`mc_input_device_channels` does this on demand.

### Integration tests must run on the device, from `example/` (Phase 1)
Plain `flutter test` runs on a headless host VM with **no native library
loaded**, so FFI calls can't be exercised. Use `integration_test` and run it
from the `example/` app on a real target:
`cd example && flutter test integration_test -d macos`.

---

## Lessons learned (principles to carry forward)

- **"Default device" = null id, not a flag.** The OS resolves the real default
  at open time; enumeration flags are hints.
- **Test the invariants the library actually guarantees**, not assumed ones. The
  "exactly one default" assumption was wrong and the platform never promised it.
- **Vendoring a single header pins the version by file contents** — fully
  reproducible offline builds, no submodule/fetch machinery. Right call for a
  package others build.
- **Capture knowledge at the point of use.** Quirks live as doc comments on the
  exact field/function they affect *and* here, so they're seen, not buried.

---

## Harmless noise (so it's not mistaken for a problem)

- `Failed to foreground app; open returned 1` during integration tests — the
  test harness can't bring the macOS window to front. Tests still run and pass.
- miniaudio WAV-decoder narrowing warning at `miniaudio.h:~80532`
  (`ma_uint64` → `ma_uint32`) — upstream code, not ours, harmless.
