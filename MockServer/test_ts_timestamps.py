"""Unit tests for ts_timestamps (python3 -m unittest discover)."""

from __future__ import annotations

import os
import unittest

import ts_timestamps

MEDIA_DIR = os.path.join(os.path.dirname(os.path.abspath(__file__)), "media")


class ShiftTimestampsTests(unittest.TestCase):
    def setUp(self) -> None:
        with open(os.path.join(MEDIA_DIR, "sample.ts"), "rb") as f:
            self.sample = f.read()

    def test_every_pts_moves_by_the_offset(self) -> None:
        shifted = ts_timestamps.shift_timestamps(self.sample, 12_345)
        before = ts_timestamps.pts_values(self.sample)
        after = ts_timestamps.pts_values(shifted)
        self.assertEqual(len(before), len(after))
        self.assertGreater(len(before), 100)
        for old, new in zip(before, after):
            self.assertEqual((new - old) & ts_timestamps.CLOCK_MASK, 12_345)

    def test_only_timestamps_change(self) -> None:
        shifted = ts_timestamps.shift_timestamps(self.sample, 90_000)
        self.assertEqual(len(shifted), len(self.sample))
        changed = sum(1 for a, b in zip(self.sample, shifted) if a != b)
        # A few bytes per PES header and PCR, nowhere near the payload size.
        self.assertLess(changed, len(self.sample) // 20)
        self.assertEqual(ts_timestamps.shift_timestamps(shifted, -90_000), self.sample)

    def test_zero_offset_returns_the_input(self) -> None:
        self.assertIs(ts_timestamps.shift_timestamps(self.sample, 0), self.sample)

    def test_loop_length_is_the_sample_length(self) -> None:
        ticks = ts_timestamps.loop_length_ticks(self.sample)
        # sample.ts plays for about 12 s.
        self.assertAlmostEqual(ticks / 90_000, 12.0, delta=0.1)
        next_loop = ts_timestamps.shift_timestamps(self.sample, ticks)
        self.assertGreater(
            min(ts_timestamps.pts_values(next_loop)),
            max(ts_timestamps.pts_values(self.sample)) - 90_000,
        )


class ShiftContinuityTests(unittest.TestCase):
    def setUp(self) -> None:
        with open(os.path.join(MEDIA_DIR, "sample.ts"), "rb") as f:
            self.sample = f.read()

    def test_repetitions_continue_the_counters(self) -> None:
        ticks = ts_timestamps.loop_length_ticks(self.sample)
        counts = ts_timestamps.continuity_counts(self.sample)
        joined = b"".join(ts_timestamps.repeat(self.sample, i, ticks, counts) for i in range(3))
        last: dict[int, int] = {}
        for offset in range(0, len(joined), 188):
            pid = ((joined[offset + 1] & 0x1F) << 8) | joined[offset + 2]
            if pid == 0x1FFF or not (joined[offset + 3] >> 4) & 0x01:
                continue
            counter = joined[offset + 3] & 0x0F
            if pid in last:
                self.assertEqual(counter, (last[pid] + 1) % 16, f"PID {pid} at packet {offset // 188}")
            last[pid] = counter

    def test_whole_turns_return_the_input(self) -> None:
        self.assertIs(ts_timestamps.shift_continuity(self.sample, {0: 32, 256: 16}), self.sample)


if __name__ == "__main__":
    unittest.main()
