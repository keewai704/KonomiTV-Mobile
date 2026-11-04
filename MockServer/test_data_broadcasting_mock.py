#!/usr/bin/env python3
"""Tests for the data broadcasting (BML) mock data.

Run from the MockServer directory:
    python3 -m unittest -v test_data_broadcasting_mock
"""

from __future__ import annotations

import struct
import time
import unittest

import data_broadcasting_mock as dbm


def sample_channel() -> dict:
    return {
        "id": "NID32736-SID1024",
        "display_channel_id": "gr011",
        "network_id": 32736,
        "service_id": 1024,
        "name": "テスト放送",
        "program_present": {
            "event_id": 9000,
            "title": "テスト放送 ニュース・情報",
            "description": "放送中の番組です。",
            "start_time": "2026-01-01T12:00:00+09:00",
            "duration": 3600,
        },
        "program_following": {
            "event_id": 9100,
            "title": "テスト放送 アニメ劇場",
            "description": "このあと放送予定の番組です。",
            "start_time": "2026-01-01T13:00:00+09:00",
            "duration": 1800,
        },
    }


class SectionTestCase(unittest.TestCase):
    def test_crc32_of_a_section_is_zero(self) -> None:
        section = dbm.build_pat(1024, 0x1000)
        self.assertEqual(dbm.crc32_mpeg(section), 0)

    def test_pat_points_at_the_pmt(self) -> None:
        section = dbm.build_pat(1024, 0x1000)
        self.assertEqual(section[0], 0x00)
        self.assertEqual(struct.unpack_from(">H", section, 8)[0], 1024)
        self.assertEqual(struct.unpack_from(">H", section, 10)[0] & 0x1FFF, 0x1000)

    def test_pmt_advertises_the_data_component(self) -> None:
        with_data = dbm.build_pmt(1024, data_pid=dbm.DATA_COMPONENT_PID)
        without_data = dbm.build_pmt(1024)
        self.assertEqual(with_data[0], 0x02)
        # データ符号化方式記述子 (タグ 0xFD) の有無
        self.assertIn(bytes([0xFD, 0x0A]), with_data)
        self.assertNotIn(bytes([0xFD]), without_data)
        self.assertGreater(len(with_data), len(without_data))
        # データ放送のコンポーネント PID
        self.assertIn(
            struct.pack(">H", 0xE000 | dbm.DATA_COMPONENT_PID),
            with_data,
        )
        self.assertEqual(dbm.crc32_mpeg(with_data), 0)

    def test_eit_present_and_following(self) -> None:
        event = {
            "event_id": 1,
            "start_time": 1767236400,
            "duration": 3600,
            "name": "モックの番組",
            "text": "データ放送のテストです。",
        }
        sections = dbm.build_eit_present_following(
            service_id=1024,
            original_network_id=32736,
            present=event,
            following={**event, "event_id": 2},
        )
        self.assertEqual(len(sections), 2)
        for index, section in enumerate(sections):
            self.assertEqual(section[0], 0x4E)
            self.assertEqual(dbm.crc32_mpeg(section), 0)
            self.assertEqual(struct.unpack_from(">H", section, 3)[0], 1024)
            self.assertEqual(section[6], index)  # section_number
            self.assertEqual(struct.unpack_from(">H", section, 8)[0], 1)  # transport_stream_id
            self.assertEqual(struct.unpack_from(">H", section, 10)[0], 32736)
        # 番組名は ARIB の文字列で入る
        self.assertIn(dbm.arib_text("モックの番組"), sections[0])

    def test_tot_has_the_current_time(self) -> None:
        now = 1767236400.0
        section = dbm.build_tot(now)
        self.assertEqual(section[0], 0x73)
        self.assertEqual(dbm.crc32_mpeg(section), 0)
        # MJD (2026-01-01) と BCD 時刻 (12:00:00 JST)
        self.assertEqual(struct.unpack_from(">H", section, 3)[0], 61041)
        self.assertEqual(section[5:8], bytes([0x12, 0x00, 0x00]))


class PSIArchivedDataTestCase(unittest.TestCase):
    def sections(self) -> list[tuple[int, bytes]]:
        return dbm.build_sections(sample_channel(), include_data_component=True, current_time=1767236400.0)

    def test_encode_decode_round_trip(self) -> None:
        sections = self.sections()
        data = dbm.encode_psi_archived_data(sections, 1767236400.0)
        self.assertEqual(dbm.iter_sections(data), sections)
        for _, section in dbm.iter_sections(data):
            self.assertEqual(dbm.crc32_mpeg(section), 0)

    def test_magic_and_header(self) -> None:
        data = dbm.encode_psi_archived_data(self.sections(), 1767236400.0)
        magic1, magic2, _, time_list_len, dictionary_len, window_len, data_size, buffer_size, code_list_len = (
            struct.unpack_from("<IIHHHHIII", data, 0)
        )
        self.assertEqual(magic1, 0x50737363)
        self.assertEqual(magic2, 0x0D0A9A0A)
        self.assertEqual(time_list_len, 2)
        self.assertEqual(dictionary_len, len(self.sections()))
        self.assertEqual(window_len, dictionary_len)
        self.assertLessEqual(data_size, buffer_size)
        self.assertEqual(code_list_len, dictionary_len)

    def test_partial_chunk_yields_nothing(self) -> None:
        data = dbm.encode_psi_archived_data(self.sections(), 1767236400.0)
        self.assertEqual(dbm.iter_sections(data[:-5]), [])

    def test_two_chunks_are_both_read(self) -> None:
        sections = self.sections()
        chunk = dbm.encode_psi_archived_data(sections, 1767236400.0)
        self.assertEqual(dbm.iter_sections(chunk + chunk), sections + sections)

    def test_stream_emits_both_chunks(self) -> None:
        stream = dbm.iter_psi_archived_data(
            sample_channel(), include_data_component=True, interval=0
        )
        first = next(stream)
        second = next(stream)
        sections = dbm.iter_sections(first) + dbm.iter_sections(second)
        self.assertEqual(
            [pid for pid, _ in sections],
            [0x0000, 0x1000, 0x0011, 0x0012, 0x0012, 0x0014],
        )
        # 番組情報 (EIT[p/f]) はチャンネルの現在/次の番組から作る
        self.assertIn(dbm.arib_text("テスト放送 ニュース・情報"), sections[3][1])
        self.assertIn(dbm.arib_text("テスト放送 アニメ劇場"), sections[4][1])

    def test_stream_without_data_component(self) -> None:
        stream = dbm.iter_psi_archived_data(
            sample_channel(), include_data_component=False, interval=0
        )
        sections = dbm.iter_sections(next(stream))
        pmt = next(section for pid, section in sections if pid == 0x1000)
        self.assertNotIn(bytes([0xFD]), pmt)


if __name__ == "__main__":
    unittest.main()
