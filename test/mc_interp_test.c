// Unit test for the pure anchor interpolation (src/mc_anchor.h).
//
// Deterministically exercises every branch — bracketed interpolation, the
// newest-anchor boundary, EXTRAPOLATION past the newest anchor (the branch normal
// draining only hits by luck), single-anchor flat, empty, and ring wrap-around.
// No device, no miniaudio, no framework.
//
// Build & run:
//   clang -Wall -Wextra -o /tmp/mc_interp_test test/mc_interp_test.c && /tmp/mc_interp_test

#include "../src/mc_anchor.h"

#include <assert.h>
#include <stdio.h>

int main(void) {
  const uint64_t CAP = 4;
  mc_anchor a[4];
  uint64_t out;

  // Empty ring: no anchors yet.
  assert(mc_interp(a, CAP, 0, 0, &out) == 0);

  // Single anchor -> flat, even for reads past it.
  a[0] = (mc_anchor){.frameIndex = 0, .hostTime = 1000};
  assert(mc_interp(a, CAP, 1, 0, &out) == 1 && out == 1000);
  assert(mc_interp(a, CAP, 1, 50, &out) == 1 && out == 1000);

  // Two anchors, slope 10 host-units/frame: (0->1000), (100->2000).
  a[1] = (mc_anchor){.frameIndex = 100, .hostTime = 2000};
  // Bracketed interpolation at R=50 -> 1500.
  assert(mc_interp(a, CAP, 2, 50, &out) == 1 && out == 1500);
  // Exactly at the newest anchor -> 2000.
  assert(mc_interp(a, CAP, 2, 100, &out) == 1 && out == 2000);
  // EXTRAPOLATION past newest with the last slope: 2000 + 10*50 = 2500.
  assert(mc_interp(a, CAP, 2, 150, &out) == 1 && out == 2500);

  // Three anchors with a slope CHANGE; extrapolation must use the LAST segment.
  // (0->1000) [slope 10], (100->2000) [slope 5], (200->2500).
  a[2] = (mc_anchor){.frameIndex = 200, .hostTime = 2500};
  assert(mc_interp(a, CAP, 3, 50, &out) == 1 && out == 1500);   // first segment
  assert(mc_interp(a, CAP, 3, 150, &out) == 1 && out == 2250);  // second segment
  // Extrapolate past newest using the last segment's slope (5), not the first (10):
  // 2500 + 5*50 = 2750.
  assert(mc_interp(a, CAP, 3, 250, &out) == 1 && out == 2750);

  // Wrap-around: seq > CAP, live window is the last CAP anchors via modular index.
  // Fill 6 anchors (i*100 -> 1000 + i*1000); live = seq 2..5 -> frameIndex
  // 200,300,400,500 / host 3000,4000,5000,6000, slope 10.
  for (uint64_t i = 0; i < 6; i++) {
    a[i % CAP] = (mc_anchor){.frameIndex = i * 100, .hostTime = 1000 + i * 1000};
  }
  assert(mc_interp(a, CAP, 6, 350, &out) == 1 && out == 4500);  // bracketed in-window
  assert(mc_interp(a, CAP, 6, 550, &out) == 1 && out == 6500);  // extrapolate in-window

  printf("mc_interp_test: all assertions passed\n");
  return 0;
}
