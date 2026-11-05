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
        magic, _, time_list_len, dictionary_len, window_len, data_size, buffer_size, code_list_len = (
            struct.unpack_from("<8sHHHHIII", data, 0)
        )
        # 実放送の書庫と同じ 8 バイト (ASCII の "Pssc" + 0x0D 0x0A 0x9A 0x0A)。
        # 公式の読み取りはこの 8 バイトだけビッグエンディアンで読む。
        self.assertEqual(magic, b"Pssc\r\n\x9a\n")
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
        # The second chunk carries the first one's dictionary on.
        sections = dbm.iter_sections(first + second)
        self.assertEqual(
            [pid for pid, _ in sections],
            [0x0000, 0x1000, 0x0011, 0x0120, 0x0012, 0x0012, 0x0014, 0x0120, 0x0120],
        )
        # 番組情報 (EIT[p/f]) はチャンネルの現在/次の番組から作る
        eits = [section for pid, section in sections if pid == 0x0012]
        self.assertIn(dbm.arib_text("テスト放送 ニュース・情報"), eits[0])
        self.assertIn(dbm.arib_text("テスト放送 アニメ劇場"), eits[1])

    def test_stream_reuses_the_previous_dictionary(self) -> None:
        stream = dbm.iter_psi_archived_data(
            sample_channel(), include_data_component=True, interval=0
        )
        chunks = [next(stream) for _ in range(4)]
        # The second PAT / PMT / SDT / DII chunk only refers to the first one's
        # dictionary (IDs from 4096) and carries no section data.
        third = chunks[2]
        dictionary_len, window_len, data_size = struct.unpack_from("<HHI", third, 12)
        self.assertEqual(data_size, 0)
        self.assertGreater(window_len, dictionary_len)
        references = struct.unpack_from(f"<{dictionary_len}H", third, 32 + 2 * 4)
        self.assertTrue(all(value >= 4096 for value in references))

        # 1 周期は 2 チャンク: PAT / PMT / SDT / DII (データ放送) と
        # EIT[p/f] × 2 / TOT / DDB × 2 (モジュールのブロック)
        cycle = [0x0000, 0x1000, 0x0011, 0x0120, 0x0012, 0x0012, 0x0014, 0x0120, 0x0120]
        sections = dbm.iter_sections(b"".join(chunks))
        self.assertEqual([pid for pid, _ in sections], cycle * 2)
        self.assertEqual(sections[:len(cycle)], sections[len(cycle):])

    def test_reused_entries_keep_their_sections(self) -> None:
        encoder = dbm.PSIArchiveEncoder()
        a, b, c = (0x0000, b"\x00" * 16), (0x0011, b"\x42" * 20), (0x0014, b"\x73" * 9)
        data = (
            encoder.encode([a, b], 1767236400.0)
            + encoder.encode([c], 1767236401.0)
            # b is now carried at window index 2, a at index 1
            + encoder.encode([b, a, c], 1767236402.0)
        )
        packets = dbm.decode_psi_archived_data(data)
        payloads = [bytes(chunk[5:5 + 20]) for _, _, chunk in packets]
        self.assertEqual([pid for _, pid, _ in packets], [0x0000, 0x0011, 0x0014, 0x0011, 0x0000, 0x0014])
        self.assertEqual(payloads[3], b"\x42" * 20)
        self.assertEqual(payloads[4][:16], b"\x00" * 16)

    def test_data_carousel_sections(self) -> None:
        dii, ddbs = dbm.data_carousel_sections()
        self.assertEqual(dii[0], 0x3B)
        self.assertEqual(dbm.crc32_mpeg(dii), 0)
        for ddb in ddbs:
            self.assertEqual(ddb[0], 0x3C)
            self.assertEqual(dbm.crc32_mpeg(ddb), 0)
            # DDB のセクション長は DSF 転送ブロック (4066) + ヘッダ + CRC
            self.assertLessEqual(len(ddb), 3 + 0xFFF)

        # DII はモジュール 1 本 (component 0x40 / module 0x0000) を指し、
        # そのモジュールは startup.bml を 1 ファイル持つ
        self.assertIn(struct.pack(">H", dbm.ENTRY_MODULE_ID), dii)
        self.assertIn(struct.pack(">H", 1), dii)  # numberOfModules
        module = dbm.build_module([
            ("startup.bml", "application/x-arib-bml", b"<html></html>"),
        ])
        self.assertIn(b"Content-Location: startup.bml", module)
        self.assertIn(b"multipart/mixed", module)
        # 起動文書は EUC-JP (A プロファイルの BML) で、複数の DDB ブロックに
        # 分かれる大きさを持つ
        document = dbm.bml_startup_document()
        self.assertTrue(document.startswith(b"<?xml"))
        self.assertGreater(len(document), dbm.DSMCC_BLOCK_SIZE)
        document.decode("euc-jp")

    def test_stream_without_data_component(self) -> None:
        stream = dbm.iter_psi_archived_data(
            sample_channel(), include_data_component=False, interval=0
        )
        sections = dbm.iter_sections(next(stream))
        pmt = next(section for pid, section in sections if pid == 0x1000)
        self.assertNotIn(bytes([0xFD]), pmt)


if __name__ == "__main__":
    unittest.main()
