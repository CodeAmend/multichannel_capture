// Anchor ring interpolation — pure, testable core of timed capture (Phase 5).
//
// Extracted from multichannel_capture.c so the numerically load-bearing math can be
// unit-tested WITHOUT a device or miniaudio (see test/mc_interp_test.c) — in
// particular the extrapolation branch (a read landing past the newest anchor),
// which normal draining only hits nondeterministically. No globals, no atomics: the
// caller snapshots the ring/sequence and hands them in; concurrency lives in the
// caller (multichannel_capture.c).

#ifndef MC_ANCHOR_H
#define MC_ANCHOR_H

#include <stdint.h>

// One anchor: the raw host time at which the frame at cumulative WRITTEN index
// `frameIndex` entered the capture callback.
typedef struct {
  uint64_t frameIndex;
  uint64_t hostTime;
} mc_anchor;

// Interpolate the host time of delivered frame `R` over an anchor snapshot.
//
// `anchors` is a circular buffer of `cap` slots; `seq` is the total number of
// anchors ever written (newest lives at (seq-1) % cap). Anchor `frameIndex` is
// strictly increasing with sequence. Returns 1 and writes `*out` on success, or 0
// if `seq == 0` (no anchors yet).
//
//   - R bracketed by two anchors      -> interpolate on their measured slope.
//   - R at/after the newest anchor     -> extrapolate on the last segment's slope.
//   - only one anchor available        -> flat (that anchor's host time).
//
// Using the measured local slope (never a nominal rate) keeps this free of any
// timebase math — raw host units in, raw host units out.
static inline int mc_interp(const mc_anchor *anchors, uint64_t cap, uint64_t seq,
                            uint64_t R, uint64_t *out) {
  if (seq == 0) {
    return 0;
  }
  uint64_t n = (seq < cap) ? seq : cap;
  uint64_t newest = seq - 1;
  uint64_t oldest = seq - n;

  // a0 = newest anchor with frameIndex <= R (the base of the line). frameIndex is
  // strictly increasing with sequence, so scan backward from newest.
  uint64_t a0 = oldest;
  for (uint64_t i = newest;; i--) {
    if (anchors[i % cap].frameIndex <= R) {
      a0 = i;
      break;
    }
    if (i == oldest) {
      a0 = oldest;
      break;
    }
  }

  // Slope from a0 and a neighbor: successor if a0 is bracketed (interpolate), else
  // the predecessor (extrapolate forward with the last measured rate).
  uint64_t sA, sB;
  if (a0 < newest) {
    sA = a0;
    sB = a0 + 1;
  } else if (a0 > oldest) {
    sA = a0 - 1;
    sB = a0;
  } else {
    sA = a0;
    sB = a0;
  }

  mc_anchor base = anchors[a0 % cap];
  mc_anchor A = anchors[sA % cap];
  mc_anchor B = anchors[sB % cap];

  uint64_t host;
  if (sB != sA && B.frameIndex != A.frameIndex) {
    double slope =
        (double)(B.hostTime - A.hostTime) / (double)(B.frameIndex - A.frameIndex);
    double h = (double)base.hostTime + slope * ((double)R - (double)base.frameIndex);
    host = (h <= 0.0) ? 0 : (uint64_t)(h + 0.5);
  } else {
    host = base.hostTime;  // single anchor: flat.
  }
  *out = host;
  return 1;
}

#endif  // MC_ANCHOR_H
