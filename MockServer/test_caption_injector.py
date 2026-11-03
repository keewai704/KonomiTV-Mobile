#!/usr/bin/env python3
"""Tests for the ARIB caption injector used by the mock server."""

from __future__ import annotations

import os
import unittest

import caption_injector


def load_sample() -> bytes:
    path = os.path.join(
        os.path.dirname(os.path.abspath(__file__)), "media", "sample.ts"
    )
    with open(path, "rb") as f:
        return f.read()


class CaptionInjectorTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls) -> None:
        cls.source = load_sample()
        cls.injected = caption_injector.inject_captions(cls.source)

    def test_every_packet_stays_synchronised(self) -> None:
        self.assertEqual(len(self.injected) % caption_injector.TS_PACKET_SIZE, 0)
        for offset in range(0, len(self.injected), caption_injector.TS_PACKET_SIZE):
            self.assertEqual(self.injected[offset], 0x47, offset)

    def test_every_pmt_advertises_the_caption_stream(self) -> None:
        pmt_pid = caption_injector._pat_pmt_pid(self.injected)
        pmts = [
            caption_injector._section_from_payload(caption_injector._packet_payload(packet))
            for packet in caption_injector._iter_packets(self.injected)
            if caption_injector._packet_pid(packet) == pmt_pid and packet[1] & 0x40
        ]
        self.assertGreater(len(pmts), 1)
        for section in pmts:
            self.assertTrue(caption_injector._pmt_has_caption(section))

    def test_pmt_advertises_caption_pid_with_valid_crc(self) -> None:
        self.assertEqual(caption_injector.caption_pid_in_pmt(self.injected), 0x0130)

        pmt_pid = caption_injector._pat_pmt_pid(self.injected)
        section = caption_injector._pmt_section(self.injected, pmt_pid)
        self.assertIsNotNone(section)
        self.assertEqual(section[0], 0x02)
        self.assertEqual(
            caption_injector.mpeg2_crc32(section[:-4]),
            int.from_bytes(section[-4:], "big"),
        )
        # stream_type 0x06 + stream_identifier_descriptor component_tag 0x30
        self.assertIn(bytes((0x06, 0xE1, 0x30, 0xF0, 0x04, 0x52, 0x01, 0x30)), section)

    def test_caption_pes_count_and_timing(self) -> None:
        payloads = caption_injector.caption_pes_packets(self.injected)
        self.assertEqual(len(payloads), len(caption_injector.DEFAULT_CAPTIONS))

        first_video_pts = caption_injector.first_video_pts(self.injected)
        self.assertIsNotNone(first_video_pts)
        expected = [
            (first_video_pts + round(offset * 90_000)) & ((1 << 33) - 1)
            for offset, _ in caption_injector.DEFAULT_CAPTIONS
        ]
        self.assertEqual(caption_injector.caption_pts_in_pes(self.injected), expected)

    def test_caption_payload_is_a_valid_statement(self) -> None:
        payload = caption_injector.caption_data_payloads(self.injected)[0]
        self.assertEqual(payload[0], 0x80)  # caption data_identifier
        self.assertEqual(payload[1], 0xFF)  # private_stream_id
        self.assertEqual(payload[2] & 0x0F, 0)  # PES_data_packet_header_length
        self.assertEqual((payload[3] & 0xFC) >> 2, 1)  # statement, language 1

        data_group_size = (payload[6] << 8) | payload[7]
        self.assertEqual(len(payload), 8 + data_group_size)

        # The statement body contains the EUC-JP JIS bytes of テスト字幕 with
        # the high bit stripped (GL, G0 = Kanji).
        encoded = bytes(byte - 0x80 for byte in "テスト字幕".encode("euc_jp"))
        self.assertIn(encoded, payload)
        self.assertEqual(payload[8] & 0xC0, 0x00)  # TMD 0
        self.assertIn(bytes((0x1F, 0x20)), payload)  # unit separator + statement

    def test_injection_is_idempotent(self) -> None:
        self.assertEqual(caption_injector.inject_captions(self.injected), self.injected)

    def test_media_without_pmt_is_unchanged(self) -> None:
        self.assertEqual(caption_injector.inject_captions(b"not a transport stream"), b"not a transport stream")


if __name__ == "__main__":
    unittest.main()
