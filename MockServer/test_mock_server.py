#!/usr/bin/env python3
"""Tests for the mock KonomiTV server (stdlib unittest only).

Run from the MockServer directory:
    python3 -m unittest -v
"""

from __future__ import annotations

import base64
import hashlib
import http.client
import json
import os
import socket
import struct
import threading
import time
import unittest
from datetime import datetime, timedelta
from urllib.parse import quote, urljoin

import caption_injector
import captures_mock
import mock_server


class MockServerTestCase(unittest.TestCase):
    @classmethod
    def setUpClass(cls) -> None:
        cls.server = mock_server.create_server("127.0.0.1", 0)
        cls.host, cls.port = cls.server.server_address[:2]
        cls.thread = threading.Thread(target=cls.server.serve_forever, daemon=True)
        cls.thread.start()

    @classmethod
    def tearDownClass(cls) -> None:
        cls.server.shutdown()
        cls.server.server_close()
        cls.thread.join(timeout=5)

    # -- helpers -----------------------------------------------------------

    def request(self, method: str, path: str, body: bytes | None = None,
                headers: dict | None = None):
        conn = http.client.HTTPConnection(self.host, self.port, timeout=10)
        try:
            hdrs = {"Accept": "*/*"}
            if headers:
                hdrs.update(headers)
            conn.request(method, path, body=body, headers=hdrs)
            response = conn.getresponse()
            data = response.read()
            return response.status, dict(response.getheaders()), data
        finally:
            conn.close()

    def get_json(self, path: str, headers: dict | None = None):
        status, response_headers, data = self.request("GET", path, headers=headers)
        return status, response_headers, json.loads(data.decode("utf-8"))

    def stats(self) -> dict:
        status, _, payload = self.get_json("/__mock/stats")
        self.assertEqual(status, 200)
        return payload

    # -- version -----------------------------------------------------------

    def test_version(self) -> None:
        status, headers, payload = self.get_json("/api/version")
        self.assertEqual(status, 200)
        self.assertIn("application/json", headers.get("Content-Type", ""))
        self.assertIn("version", payload)
        self.assertIn("environment", payload)
        self.assertIn("backend", payload)
        self.assertIn("encoder", payload)

    # -- channels ----------------------------------------------------------

    def test_channels_shape_and_relative_programs(self) -> None:
        status, _, payload = self.get_json("/api/channels")
        self.assertEqual(status, 200)
        for key in ("GR", "BS", "CS", "CATV", "SKY", "BS4K"):
            self.assertIn(key, payload)
            self.assertIsInstance(payload[key], list)
        self.assertGreaterEqual(len(payload["GR"]), 3)
        self.assertGreaterEqual(len(payload["BS"]), 2)
        for key in ("CS", "CATV", "SKY", "BS4K"):
            self.assertEqual(payload[key], [])

        self.assertEqual(payload["GR"][0]["display_channel_id"], "gr011")
        self.assertEqual(payload["BS"][0]["display_channel_id"], "bs101")
        self.assertEqual(payload["BS"][1]["display_channel_id"], "bs103")

        channel = payload["GR"][0]
        for field in (
            "id", "display_channel_id", "network_id", "service_id", "remocon_id",
            "channel_number", "type", "name", "is_subchannel", "is_radiochannel",
            "is_watchable", "is_display", "viewer_count",
            "program_present", "program_following",
        ):
            self.assertIn(field, channel)
        self.assertEqual(channel["type"], "GR")

        now = datetime.now(mock_server.JST)
        present = channel["program_present"]
        following = channel["program_following"]
        self.assertIsNotNone(present)
        self.assertIsNotNone(following)

        present_start = datetime.fromisoformat(present["start_time"])
        present_end = datetime.fromisoformat(present["end_time"])
        following_start = datetime.fromisoformat(following["start_time"])
        self.assertLess(present_start, now)
        self.assertGreater(present_end, now)
        self.assertGreaterEqual(following_start, present_end)
        for program in (present, following):
            self.assertTrue(program["start_time"].endswith("+09:00"))
            self.assertTrue(program["end_time"].endswith("+09:00"))
            for field in (
                "id", "channel_id", "network_id", "service_id", "event_id",
                "title", "description", "detail", "start_time", "end_time",
                "duration", "is_free", "genres",
            ):
                self.assertIn(field, program)
            self.assertIsInstance(program["duration"], (int, float))

        # A second request must also return a valid relative program window.
        status, _, payload_again = self.get_json("/api/channels")
        self.assertEqual(status, 200)
        again_start = datetime.fromisoformat(
            payload_again["GR"][0]["program_present"]["start_time"]
        )
        self.assertAlmostEqual(
            (again_start - present_start).total_seconds(), 0, delta=5
        )

    # -- videos ------------------------------------------------------------

    def test_videos_pagination(self) -> None:
        status, _, page1 = self.get_json("/api/videos?order=desc&page=1")
        self.assertEqual(status, 200)
        self.assertEqual(page1["total"], 35)
        self.assertEqual(len(page1["recorded_programs"]), 30)
        self.assertEqual(
            [p["id"] for p in page1["recorded_programs"]], list(range(1, 31))
        )

        status, _, page2 = self.get_json("/api/videos?order=desc&page=2")
        self.assertEqual(status, 200)
        self.assertEqual(page2["total"], 35)
        self.assertEqual(len(page2["recorded_programs"]), 5)
        self.assertEqual(
            [p["id"] for p in page2["recorded_programs"]], list(range(31, 36))
        )

        start_times = [p["start_time"] for p in page1["recorded_programs"]]
        self.assertEqual(start_times, sorted(start_times, reverse=True))

        status, _, page3 = self.get_json("/api/videos?order=desc&page=3")
        self.assertEqual(status, 200)
        self.assertEqual(page3["total"], 35)
        self.assertEqual(page3["recorded_programs"], [])

    def test_videos_search(self) -> None:
        status, _, payload = self.get_json("/api/videos/search?query=%E3%83%8B%E3%83%A5%E3%83%BC%E3%82%B9&order=desc&page=1")
        self.assertEqual(status, 200)
        self.assertGreater(len(payload["recorded_programs"]), 0)
        self.assertLess(payload["total"], 35)
        for program in payload["recorded_programs"]:
            self.assertIn("ニュース", program["title"])

        status, _, anime = self.get_json("/api/videos/search?query=%E3%82%A2%E3%83%8B%E3%83%A1&order=desc&page=1")
        self.assertEqual(status, 200)
        self.assertGreater(len(anime["recorded_programs"]), 0)
        for program in anime["recorded_programs"]:
            self.assertIn("アニメ", program["title"])

        status, _, empty = self.get_json("/api/videos/search?query=zzz-no-match&order=desc&page=1")
        self.assertEqual(status, 200)
        self.assertEqual(empty["total"], 0)
        self.assertEqual(empty["recorded_programs"], [])

    def test_video_detail(self) -> None:
        status, _, page1 = self.get_json("/api/videos?order=desc&page=1")
        first = page1["recorded_programs"][0]

        status, _, detail = self.get_json(f"/api/videos/{first['id']}")
        self.assertEqual(status, 200)
        self.assertEqual(detail["id"], first["id"])
        self.assertEqual(detail["title"], first["title"])
        for field in (
            "id", "title", "description", "start_time", "end_time", "duration",
            "channel", "recorded_video", "created_at", "updated_at",
        ):
            self.assertIn(field, detail)
        video = detail["recorded_video"]
        for field in (
            "id", "status", "file_path", "file_hash", "file_size",
            "file_created_at", "file_modified_at", "duration",
            "container_format", "video_codec", "video_codec_profile",
            "video_scan_type", "video_frame_rate", "video_resolution_width",
            "video_resolution_height", "primary_audio_codec",
            "primary_audio_channel", "primary_audio_sampling_rate",
            "created_at", "updated_at",
        ):
            self.assertIn(field, video)
        self.assertEqual(detail["channel"]["type"], "GR")

    def test_unknown_routes_return_404_json(self) -> None:
        for path in ("/api/nope", "/unknown", "/api/videos/9999"):
            status, headers, payload = self.get_json(path)
            self.assertEqual(status, 404, path)
            self.assertIn("application/json", headers.get("Content-Type", ""))
            self.assertEqual(payload, {"detail": "Not Found"})

    # -- images ------------------------------------------------------------

    def test_channel_logo(self) -> None:
        status, headers, body = self.request("GET", "/api/channels/gr011/logo")
        self.assertEqual(status, 200)
        self.assertEqual(headers.get("Content-Type"), "image/png")
        self.assertTrue(body.startswith(b"\x89PNG"))

    def test_video_thumbnail(self) -> None:
        status, headers, body = self.request("GET", "/api/videos/1/thumbnail")
        self.assertEqual(status, 200)
        self.assertEqual(headers.get("Content-Type"), "image/webp")
        self.assertTrue(body.startswith(b"RIFF"))

    def test_video_tiled_thumbnail(self) -> None:
        status, headers, body = self.request(
            "GET", "/api/videos/1/thumbnail/tiled"
        )
        self.assertEqual(status, 200)
        self.assertEqual(headers.get("Content-Type"), "image/png")
        self.assertTrue(body.startswith(b"\x89PNG"))
        # 960 x 180 (160 x 90 のタイル 6 列 x 2 行) の IHDR
        self.assertEqual(int.from_bytes(body[16:20], "big"), 960)
        self.assertEqual(int.from_bytes(body[20:24], "big"), 180)

        status, _, _ = self.request("GET", "/api/videos/9999/thumbnail/tiled")
        self.assertEqual(status, 404)

    def test_video_detail_has_tile_thumbnail_info(self) -> None:
        status, _, detail = self.get_json("/api/videos/1")
        self.assertEqual(status, 200)
        tile = detail["recorded_video"]["thumbnail_info"]["tile"]
        self.assertEqual(tile["tile_width"], mock_server.TILE_WIDTH)
        self.assertEqual(tile["tile_height"], mock_server.TILE_HEIGHT)
        self.assertEqual(tile["column_count"], mock_server.TILE_COLUMNS)
        self.assertEqual(tile["row_count"], mock_server.TILE_ROWS)
        self.assertEqual(tile["total_tiles"], mock_server.TILE_TOTAL)
        self.assertEqual(tile["interval_sec"], mock_server.TILE_INTERVAL_SEC)

    # -- auth --------------------------------------------------------------

    def test_token_success_and_failure(self) -> None:
        body = b"username=test&password=test"
        status, _, raw = self.request(
            "POST", "/api/users/token", body=body,
            headers={"Content-Type": "application/x-www-form-urlencoded"},
        )
        self.assertEqual(status, 200)
        payload = json.loads(raw.decode("utf-8"))
        self.assertIn("access_token", payload)
        self.assertIn("token_type", payload)

        status, _, raw = self.request(
            "POST", "/api/users/token", body=b"username=wrong&password=wrong",
            headers={"Content-Type": "application/x-www-form-urlencoded"},
        )
        self.assertEqual(status, 401)
        self.assertIn("detail", json.loads(raw.decode("utf-8")))

    def test_users_me_requires_token(self) -> None:
        status, _, _ = self.request("GET", "/api/users/me")
        self.assertEqual(status, 401)

        status, _, payload = self.get_json(
            "/api/users/me", headers={"Authorization": "Bearer mock-access-token"}
        )
        self.assertEqual(status, 200)
        self.assertEqual(payload["name"], "テストユーザー")
        self.assertIn("id", payload)
        self.assertIn("is_admin", payload)

    # -- video HLS ---------------------------------------------------------

    def test_video_hls_master_media_and_segment(self) -> None:
        session_id = "abc12345"
        master_path = f"/api/streams/video/1/720p/playlist?session_id={session_id}&type=master"
        status, headers, body = self.request("GET", master_path)
        self.assertEqual(status, 200)
        self.assertIn("mpegurl", headers.get("Content-Type", ""))
        master = body.decode("utf-8")
        self.assertTrue(master.startswith("#EXTM3U"))
        self.assertIn("#EXT-X-STREAM-INF", master)

        variant = next(
            line for line in master.splitlines()
            if line and not line.startswith("#")
        )
        media_url = urljoin(master_path, variant)
        status, headers, body = self.request("GET", media_url)
        self.assertEqual(status, 200)
        media = body.decode("utf-8")
        self.assertIn("#EXTM3U", media)
        self.assertIn(f"session_id={session_id}", media)
        self.assertIn("segment?", media)

        segment_uri = next(
            line for line in media.splitlines()
            if line and not line.startswith("#")
        )
        segment_url = urljoin(media_url, segment_uri)
        status, headers, data = self.request("GET", segment_url)
        self.assertEqual(status, 200)
        self.assertEqual(headers.get("Content-Type"), "video/mp2t")
        self.assertGreaterEqual(len(data), 188)
        self.assertEqual(data[0], 0x47)

    def test_video_media_playlist_covers_120_seconds(self) -> None:
        session_id = "abc12345"
        playlist_path = (
            f"/api/streams/video/1/720p/playlist?session_id={session_id}"
            "&type=primary-audio"
        )
        status, headers, body = self.request("GET", playlist_path)
        self.assertEqual(status, 200)
        self.assertIn("mpegurl", headers.get("Content-Type", ""))
        media = body.decode("utf-8")

        # 6 セグメント (各 2 秒) x 10 回 = 60 セグメント / 120 秒
        segments = [
            line for line in media.splitlines() if line and not line.startswith("#")
        ]
        self.assertEqual(len(segments), 60)
        self.assertTrue(segments[0].endswith("sequence=0"))
        self.assertTrue(segments[-1].endswith("sequence=59"))
        for sequence, uri in enumerate(segments):
            self.assertEqual(
                uri, f"segment?session_id={session_id}&sequence={sequence}"
            )

        # 繰り返しの境目 (6, 12, ..., 54) にだけ不連続点を置く
        self.assertEqual(media.count("#EXT-X-DISCONTINUITY"), 9)
        lines = media.splitlines()
        first_segment = lines.index(segments[0])
        self.assertTrue(lines[first_segment - 1].startswith("#EXTINF:"))
        for index, line in enumerate(lines):
            if line != "#EXT-X-DISCONTINUITY":
                continue
            self.assertTrue(lines[index + 1].startswith("#EXTINF:"))
            number = int(lines[index + 2].rsplit("sequence=", 1)[1])
            self.assertEqual(number % 6, 0)

        durations = [
            float(line[len("#EXTINF:"):].rstrip(","))
            for line in lines
            if line.startswith("#EXTINF:")
        ]
        self.assertEqual(len(durations), 60)
        self.assertAlmostEqual(sum(durations), 120.0, places=3)

        self.assertIn("#EXT-X-PLAYLIST-TYPE:VOD", media)
        self.assertTrue(media.rstrip().endswith("#EXT-X-ENDLIST"))

        # sequence=59 は segment5.ts を返す
        segment_url = urljoin(playlist_path, segments[-1])
        status, headers, data = self.request("GET", segment_url)
        self.assertEqual(status, 200)
        self.assertEqual(headers.get("Content-Type"), "video/mp2t")
        self.assertEqual(data, mock_server.caption_injected_segment(5))

    def test_video_segment_contains_arib_caption_stream(self) -> None:
        session_id = "abc12345"
        segment_url = (
            f"/api/streams/video/1/720p/segment?session_id={session_id}&sequence=0"
        )
        status, headers, data = self.request("GET", segment_url)
        self.assertEqual(status, 200)
        self.assertEqual(headers.get("Content-Type"), "video/mp2t")

        self.assertEqual(caption_injector.caption_pid_in_pmt(data), 0x0130)
        payloads = caption_injector.caption_data_payloads(data)
        self.assertEqual(len(payloads), len(caption_injector.DEFAULT_CAPTIONS))
        for payload in payloads:
            # ARIB caption PES payload starts at data_identifier 0x80.
            self.assertEqual(payload[0], 0x80)
            self.assertEqual(payload[1], 0xFF)
            self.assertEqual(payload[2] & 0x0F, 0)
            self.assertEqual((payload[3] & 0xFC) >> 2, 1)  # statement, language 1

        first_video_pts = caption_injector.first_video_pts(data)
        self.assertIsNotNone(first_video_pts)
        caption_pts = caption_injector.caption_pts_in_pes(data)
        self.assertEqual(
            caption_pts,
            [
                (first_video_pts + round(offset * 90_000)) & ((1 << 33) - 1)
                for offset, _ in caption_injector.DEFAULT_CAPTIONS
            ],
        )

    def test_live_stream_contains_arib_caption_stream(self) -> None:
        conn = http.client.HTTPConnection(self.host, self.port, timeout=10)
        response = None
        try:
            conn.request("GET", "/api/streams/live/gr011/720p/mpegts")
            response = conn.getresponse()
            self.assertEqual(response.status, 200)
            self.assertEqual(response.getheader("Content-Type"), "video/mp2t")
            # The live stream is endless; read enough for the captions at
            # 0.2 s and 1.2 s (about 2.7 s of media at the mock's pacing).
            data = response.read(188 * 600)
        finally:
            if response is not None:
                response.close()
            conn.close()

        self.assertEqual(data[0], 0x47)
        self.assertEqual(caption_injector.caption_pid_in_pmt(data), 0x0130)
        self.assertGreaterEqual(len(caption_injector.caption_pes_packets(data)), 2)

        # Let the server observe the closed connection before the next test.
        deadline = time.monotonic() + 3.0
        while time.monotonic() < deadline:
            if self.stats()["live_active"] == 0:
                break
            time.sleep(0.05)

    def test_invalid_quality_for_video_stream(self) -> None:
        status, _, payload = self.get_json(
            "/api/streams/video/1/original/playlist?session_id=abc&type=master"
        )
        self.assertEqual(status, 422)
        self.assertIn("detail", payload)

    def test_keepalive_and_stats(self) -> None:
        status, _, _ = self.request("GET", "/__mock/stats")
        self.assertEqual(status, 200)
        before = self.stats()["keepalive"].get("1", 0)

        status, _, body = self.request(
            "PUT", "/api/streams/video/1/720p/keep-alive?session_id=abc12345"
        )
        self.assertEqual(status, 204)
        self.assertEqual(body, b"")

        after = self.stats()["keepalive"].get("1", 0)
        self.assertEqual(after, before + 1)

    # -- live stream -------------------------------------------------------

    def test_live_stream_streams_and_tracks_connections(self) -> None:
        status_before = self.stats()
        self.assertEqual(status_before["live_active"], 0)

        conn = http.client.HTTPConnection(self.host, self.port, timeout=3)
        response = None
        try:
            started = time.monotonic()
            conn.request("GET", "/api/streams/live/gr011/1080p/mpegts")
            response = conn.getresponse()
            self.assertEqual(response.status, 200)
            self.assertEqual(response.getheader("Content-Type"), "video/mp2t")
            data = response.read(188 * 100)
            elapsed = time.monotonic() - started
        finally:
            # HTTPResponse keeps the socket file descriptor alive, so close it
            # explicitly before the connection for the server to see the FIN.
            if response is not None:
                response.close()
            conn.close()

        self.assertLess(elapsed, 3.0)
        self.assertGreaterEqual(len(data), 188 * 100)
        self.assertEqual(data[0], 0x47)

        # Stats must show the connection while it is open, then drop to 0.
        deadline = time.monotonic() + 3.0
        active = None
        while time.monotonic() < deadline:
            active = self.stats()["live_active"]
            if active == 0:
                break
            time.sleep(0.1)
        self.assertEqual(active, 0)

        total_after = self.stats()["live_total"]
        self.assertGreaterEqual(total_after, status_before["live_total"] + 1)


# ---------------------------------------------------------------------------
# ストリーミング (拡張画質 / master プレイリスト / ライブイベント SSE)
# ---------------------------------------------------------------------------

class MockServerStreamingTestCase(unittest.TestCase):
    """Streaming endpoint tests (fresh server per class)."""

    @classmethod
    def setUpClass(cls) -> None:
        cls.server = mock_server.create_server("127.0.0.1", 0)
        cls.host, cls.port = cls.server.server_address[:2]
        cls.thread = threading.Thread(target=cls.server.serve_forever, daemon=True)
        cls.thread.start()

    @classmethod
    def tearDownClass(cls) -> None:
        cls.server.shutdown()
        cls.server.server_close()
        cls.thread.join(timeout=5)

    def request(self, method: str, path: str, body: bytes | None = None,
                headers: dict | None = None):
        conn = http.client.HTTPConnection(self.host, self.port, timeout=10)
        try:
            hdrs = {"Accept": "*/*"}
            if headers:
                hdrs.update(headers)
            conn.request(method, path, body=body, headers=hdrs)
            response = conn.getresponse()
            data = response.read()
            return response.status, dict(response.getheaders()), data
        finally:
            conn.close()

    def get_json(self, path: str, headers: dict | None = None):
        status, response_headers, data = self.request("GET", path, headers=headers)
        return status, response_headers, json.loads(data.decode("utf-8"))

    def stats(self) -> dict:
        status, _, payload = self.get_json("/__mock/stats")
        self.assertEqual(status, 200)
        return payload

    # -- 拡張画質 ----------------------------------------------------------

    def test_live_accepts_extended_quality_names(self) -> None:
        for quality in (
            "810p", "540p", "810p-hevc", "540p-hevc-24fps",
            "1080p-60fps-hevc", "720p-hevc-10bit-24fps", "original",
        ):
            conn = http.client.HTTPConnection(self.host, self.port, timeout=5)
            response = None
            try:
                conn.request("GET", f"/api/streams/live/gr011/{quality}/mpegts")
                response = conn.getresponse()
                self.assertEqual(response.status, 200, quality)
                self.assertEqual(response.getheader("Content-Type"), "video/mp2t")
                data = response.read(188)
                self.assertEqual(len(data), 188, quality)
                self.assertEqual(data[0], 0x47, quality)
            finally:
                if response is not None:
                    response.close()
                conn.close()
            self.assertEqual(self.stats()["last_live_quality"], quality)

    def test_live_rejects_unknown_quality(self) -> None:
        for quality in ("2160p", "810p-hevc-30fps", "1080p-24fps-hevc"):
            status, _, payload = self.get_json(
                f"/api/streams/live/gr011/{quality}/mpegts"
            )
            self.assertEqual(status, 422, quality)
            self.assertIn("detail", payload)

    def test_video_accepts_extended_quality_names(self) -> None:
        for quality in ("810p", "540p-hevc", "810p-hevc-24fps", "1080p-60fps-hevc"):
            status, headers, body = self.request(
                "GET",
                f"/api/streams/video/1/{quality}/playlist?session_id=sid&type=master",
            )
            self.assertEqual(status, 200, quality)
            self.assertIn("mpegurl", headers.get("Content-Type", ""))
            self.assertTrue(body.decode("utf-8").startswith("#EXTM3U"), quality)
            self.assertEqual(self.stats()["last_video_quality"], quality)

    # -- master プレイリスト ------------------------------------------------

    def test_video_master_playlist_has_audio_group(self) -> None:
        session_id = "abc12345"
        path = (
            f"/api/streams/video/1/810p-hevc-24fps/playlist"
            f"?session_id={session_id}&type=master"
        )
        status, headers, body = self.request("GET", path)
        self.assertEqual(status, 200)
        self.assertIn("mpegurl", headers.get("Content-Type", ""))
        master = body.decode("utf-8")
        lines = master.splitlines()

        self.assertEqual(lines[0], "#EXTM3U")
        self.assertIn("#EXT-X-VERSION:6", lines)

        media_lines = [line for line in lines if line.startswith("#EXT-X-MEDIA:")]
        self.assertEqual(len(media_lines), 2)
        self.assertIn('NAME="主音声"', media_lines[0])
        self.assertIn("DEFAULT=YES", media_lines[0])
        self.assertNotIn("URI=", media_lines[0])
        self.assertIn('NAME="副音声"', media_lines[1])
        self.assertIn("DEFAULT=NO", media_lines[1])
        self.assertIn(
            f'URI="playlist?session_id={session_id}&type=secondary-audio"',
            media_lines[1],
        )

        stream_inf = next(line for line in lines if line.startswith("#EXT-X-STREAM-INF:"))
        self.assertIn('AUDIO="audio"', stream_inf)
        bandwidth = int(stream_inf.split("BANDWIDTH=")[1].split(",")[0])
        # 810p-hevc: 3700K 映像 + 192K 音声 x2 に 10% の多重化オーバーヘッド
        self.assertEqual(bandwidth, round((3700 * 1000 + 192 * 1000 * 2) * 1.1))

        variant = next(line for line in lines if line and not line.startswith("#"))
        self.assertEqual(variant, f"playlist?session_id={session_id}&type=primary-audio")

        stats = self.stats()
        self.assertEqual(stats["last_video_quality"], "810p-hevc-24fps")
        self.assertEqual(stats["last_video_playlist_type"], "master")

    def test_video_audio_media_playlists(self) -> None:
        session_id = "abc12345"
        for playlist_type in ("primary-audio", "secondary-audio"):
            path = (
                f"/api/streams/video/1/720p/playlist"
                f"?session_id={session_id}&type={playlist_type}"
            )
            status, headers, body = self.request("GET", path)
            self.assertEqual(status, 200, playlist_type)
            self.assertIn("mpegurl", headers.get("Content-Type", ""))
            media = body.decode("utf-8")
            self.assertIn("#EXTM3U", media)
            self.assertIn(f"session_id={session_id}", media)
            self.assertIn("segment?", media)
            # Media playlist requests are recorded separately; the master
            # playlist marker stays for the playback-type check.
            self.assertEqual(
                self.stats()["last_video_media_playlist_type"], playlist_type
            )

            segment_uri = next(
                line for line in media.splitlines()
                if line and not line.startswith("#")
            )
            segment_url = urljoin(path, segment_uri)
            status, headers, data = self.request("GET", segment_url)
            self.assertEqual(status, 200, playlist_type)
            self.assertEqual(headers.get("Content-Type"), "video/mp2t")
            self.assertEqual(data[0], 0x47)

    def test_video_playlist_rejects_invalid_type(self) -> None:
        status, _, payload = self.get_json(
            "/api/streams/video/1/720p/playlist?session_id=sid&type=tertiary-audio"
        )
        self.assertEqual(status, 422)
        self.assertIn("detail", payload)

    # -- ライブイベント (SSE) ----------------------------------------------

    def _read_sse_events(self, response, count: int) -> list[dict]:
        """Read `count` complete SSE events from an open response."""
        events: list[dict] = []
        current: dict = {}
        while len(events) < count:
            raw = response.fp.readline()
            if not raw:
                break
            line = raw.decode("utf-8").rstrip("\r\n")
            if line == "":
                if current:
                    events.append(current)
                    current = {}
                continue
            if line.startswith(":"):
                continue
            field, _, value = line.partition(":")
            if value.startswith(" "):
                value = value[1:]
            if field == "event":
                current["event"] = value
            elif field == "data":
                current["data"] = current.get("data", "") + value
        return events

    def test_live_events_streams_standby_then_onair(self) -> None:
        conn = http.client.HTTPConnection(self.host, self.port, timeout=10)
        response = None
        try:
            conn.request("GET", "/api/streams/live/gr011/1080p/events")
            response = conn.getresponse()
            self.assertEqual(response.status, 200)
            self.assertIn(
                "text/event-stream", response.getheader("Content-Type", "")
            )
            events = self._read_sse_events(response, 2)
        finally:
            if response is not None:
                response.close()
            conn.close()

        self.assertEqual(len(events), 2)
        self.assertEqual(events[0]["event"], "initial_update")
        self.assertEqual(events[1]["event"], "status_update")

        first = json.loads(events[0]["data"])
        second = json.loads(events[1]["data"])
        self.assertEqual(first["status"], "Standby")
        self.assertIn("エンコードタスク", first["detail"])
        self.assertEqual(second["status"], "ONAir")
        self.assertEqual(second["detail"], "ライブストリームは ONAir です。")
        for payload in (first, second):
            for field in ("status", "detail", "started_at", "updated_at", "client_count"):
                self.assertIn(field, payload)
            self.assertIsInstance(payload["started_at"], (int, float))
            self.assertIsInstance(payload["updated_at"], (int, float))
            self.assertIsInstance(payload["client_count"], int)
            self.assertGreaterEqual(payload["client_count"], 1)
        self.assertGreaterEqual(second["updated_at"], first["updated_at"])

        self.assertEqual(self.stats()["last_live_quality"], "1080p")

        # 切断後は視聴者数が 0 に戻る
        deadline = time.monotonic() + 3.0
        active = None
        while time.monotonic() < deadline:
            active = self.stats()["live_active"]
            if active == 0:
                break
            time.sleep(0.1)
        self.assertEqual(active, 0)

    def test_live_events_keeps_sending_clients_updates(self) -> None:
        conn = http.client.HTTPConnection(self.host, self.port, timeout=10)
        response = None
        try:
            conn.request("GET", "/api/streams/live/bs101/540p-hevc/events")
            response = conn.getresponse()
            self.assertEqual(response.status, 200)
            events = self._read_sse_events(response, 3)
        finally:
            if response is not None:
                response.close()
            conn.close()

        self.assertEqual(
            [event["event"] for event in events],
            ["initial_update", "status_update", "clients_update"],
        )
        clients = json.loads(events[2]["data"])
        self.assertEqual(clients["status"], "ONAir")
        self.assertGreaterEqual(clients["client_count"], 1)
        self.assertEqual(self.stats()["last_live_quality"], "540p-hevc")

    def test_live_events_rejects_unknown_channel_and_quality(self) -> None:
        status, _, payload = self.get_json("/api/streams/live/zz999/1080p/events")
        self.assertEqual(status, 404)
        self.assertIn("detail", payload)

        status, _, payload = self.get_json("/api/streams/live/gr011/2160p/events")
        self.assertEqual(status, 422)
        self.assertIn("detail", payload)


# ---------------------------------------------------------------------------
# 追加エンドポイント (シリーズ / 番組表 / 番組検索 / クライアント設定 / ダウンロード)
# ---------------------------------------------------------------------------

ADMIN_HEADERS = {"Authorization": "Bearer mock-access-token"}


class MockServerExtensionTestCase(unittest.TestCase):
    """Non-destructive tests for the newer endpoints (fresh server per class)."""

    @classmethod
    def setUpClass(cls) -> None:
        cls.server = mock_server.create_server("127.0.0.1", 0)
        cls.host, cls.port = cls.server.server_address[:2]
        cls.thread = threading.Thread(target=cls.server.serve_forever, daemon=True)
        cls.thread.start()

    @classmethod
    def tearDownClass(cls) -> None:
        cls.server.shutdown()
        cls.server.server_close()
        cls.thread.join(timeout=5)

    def request(self, method: str, path: str, body: bytes | None = None,
                headers: dict | None = None):
        conn = http.client.HTTPConnection(self.host, self.port, timeout=10)
        try:
            hdrs = {"Accept": "*/*"}
            if headers:
                hdrs.update(headers)
            conn.request(method, path, body=body, headers=hdrs)
            response = conn.getresponse()
            data = response.read()
            return response.status, dict(response.getheaders()), data
        finally:
            conn.close()

    def get_json(self, path: str, headers: dict | None = None):
        status, response_headers, data = self.request("GET", path, headers=headers)
        return status, response_headers, json.loads(data.decode("utf-8"))

    def post_json(self, path: str, payload, headers: dict | None = None):
        status, response_headers, data = self.request(
            "POST", path,
            body=json.dumps(payload).encode("utf-8"),
            headers={"Content-Type": "application/json", **(headers or {})},
        )
        return status, response_headers, json.loads(data.decode("utf-8"))

    # -- series ------------------------------------------------------------

    def test_series_list_and_pagination(self) -> None:
        status, _, payload = self.get_json("/api/series?order=desc&page=1")
        self.assertEqual(status, 200)
        self.assertEqual(payload["total"], 3)
        self.assertEqual(len(payload["series_list"]), 3)
        self.assertEqual(
            [entry["id"] for entry in payload["series_list"]], [1, 2, 3]
        )

        status, _, ascending = self.get_json("/api/series?order=asc&page=1")
        self.assertEqual(status, 200)
        self.assertEqual([entry["id"] for entry in ascending["series_list"]], [3, 2, 1])

        status, _, empty = self.get_json("/api/series?order=desc&page=2")
        self.assertEqual(status, 200)
        self.assertEqual(empty["total"], 3)
        self.assertEqual(empty["series_list"], [])

        entry = payload["series_list"][0]
        for field in ("id", "title", "description", "genres",
                      "broadcast_periods", "created_at", "updated_at"):
            self.assertIn(field, entry)
        period = entry["broadcast_periods"][0]
        for field in ("channel", "start_date", "end_date", "recorded_programs"):
            self.assertIn(field, period)
        self.assertEqual(period["channel"]["type"], "GR")
        self.assertTrue(period["start_date"].count("-") == 2)
        self.assertGreaterEqual(len(period["recorded_programs"]), 3)

    def test_series_search(self) -> None:
        query = quote("フリーレン")
        status, _, payload = self.get_json(f"/api/series/search?query={query}&order=desc&page=1")
        self.assertEqual(status, 200)
        self.assertEqual(payload["total"], 1)
        self.assertEqual(payload["series_list"][0]["id"], 2)

        status, _, empty = self.get_json("/api/series/search?query=zzz-no-match")
        self.assertEqual(status, 200)
        self.assertEqual(empty["total"], 0)
        self.assertEqual(empty["series_list"], [])

        # 空クエリは全件取得と同じ
        status, _, all_series = self.get_json("/api/series/search?query=")
        self.assertEqual(status, 200)
        self.assertEqual(all_series["total"], 3)

    def test_series_detail(self) -> None:
        status, _, payload = self.get_json("/api/series/1")
        self.assertEqual(status, 200)
        self.assertEqual(payload["id"], 1)
        self.assertEqual(payload["title"], "アニメ 鬼滅の刃")
        self.assertEqual(len(payload["broadcast_periods"]), 1)
        self.assertTrue(payload["genres"])

        status, _, payload = self.get_json("/api/series/999")
        self.assertEqual(status, 422)
        self.assertIn("detail", payload)

    def test_series_is_linked_from_recorded_programs(self) -> None:
        status, _, series = self.get_json("/api/series/1")
        self.assertEqual(status, 200)
        recorded_ids = [
            program["id"]
            for period in series["broadcast_periods"]
            for program in period["recorded_programs"]
        ]
        self.assertGreaterEqual(len(recorded_ids), 3)

        for video_id in recorded_ids:
            status, _, program = self.get_json(f"/api/videos/{video_id}")
            self.assertEqual(status, 200)
            self.assertEqual(program["series_id"], 1)
            self.assertEqual(program["series_title"], "アニメ 鬼滅の刃")
            self.assertIsNotNone(program["series_broadcast_period_id"])
            self.assertIsNotNone(program["episode_number"])

        # シリーズに属さない録画番組は series_id が null のまま
        status, _, unrelated = self.get_json("/api/videos/1")
        self.assertEqual(status, 200)
        self.assertIsNone(unrelated["series_id"])

    # -- videos: order and ids --------------------------------------------

    def test_videos_order_asc(self) -> None:
        status, _, payload = self.get_json("/api/videos?order=asc&page=1")
        self.assertEqual(status, 200)
        self.assertEqual(payload["total"], 35)
        self.assertEqual(
            [program["id"] for program in payload["recorded_programs"]],
            list(range(35, 5, -1)),
        )
        start_times = [program["start_time"] for program in payload["recorded_programs"]]
        self.assertEqual(start_times, sorted(start_times))

    def test_videos_ids_preserve_requested_order(self) -> None:
        status, _, payload = self.get_json("/api/videos?ids=5&ids=1&ids=4&order=ids&page=1")
        self.assertEqual(status, 200)
        self.assertEqual(payload["total"], 3)
        self.assertEqual(
            [program["id"] for program in payload["recorded_programs"]], [5, 1, 4]
        )

        # 存在しない ID は無視されるが total には数えない
        status, _, payload = self.get_json("/api/videos?ids=2&ids=9999&order=ids&page=1")
        self.assertEqual(status, 200)
        self.assertEqual(payload["total"], 1)
        self.assertEqual([program["id"] for program in payload["recorded_programs"]], [2])

        # order=ids 以外なら通常のソート順 (開始時刻の新しい順) になる
        status, _, payload = self.get_json("/api/videos?ids=5&ids=1&ids=4&order=desc&page=1")
        self.assertEqual(status, 200)
        self.assertEqual(
            [program["id"] for program in payload["recorded_programs"]], [1, 4, 5]
        )

    def test_videos_ids_paging(self) -> None:
        ids = "&".join(f"ids={index}" for index in range(1, 36))
        status, _, payload = self.get_json(f"/api/videos?{ids}&order=ids&page=1")
        self.assertEqual(status, 200)
        self.assertEqual(payload["total"], 35)
        self.assertEqual(len(payload["recorded_programs"]), 30)
        self.assertEqual(payload["recorded_programs"][0]["id"], 1)

        status, _, payload = self.get_json(f"/api/videos?{ids}&order=ids&page=2")
        self.assertEqual(status, 200)
        self.assertEqual([program["id"] for program in payload["recorded_programs"]], list(range(31, 36)))

    # -- videos: download / reanalyze / regenerate ------------------------

    def test_video_download(self) -> None:
        status, headers, body = self.request("GET", "/api/videos/1/download")
        self.assertEqual(status, 200)
        self.assertIn("video/mp2t", headers.get("Content-Type", ""))
        disposition = headers.get("Content-Disposition", "")
        self.assertTrue(disposition.startswith("attachment;"))
        self.assertIn('filename="program1.m2ts"', disposition)
        self.assertGreater(len(body), 0)

        status, _, payload = self.get_json("/api/videos/9999/download")
        self.assertEqual(status, 422)
        self.assertIn("detail", payload)

    def test_video_reanalyze_requires_admin_token(self) -> None:
        status, _, _ = self.request("POST", "/api/videos/1/reanalyze")
        self.assertEqual(status, 401)

        status, _, body = self.request(
            "POST", "/api/videos/1/reanalyze", headers=ADMIN_HEADERS
        )
        self.assertEqual(status, 204)
        self.assertEqual(body, b"")

        status, _, body = self.request(
            "POST", "/api/videos/9999/reanalyze", headers=ADMIN_HEADERS
        )
        self.assertEqual(status, 422)
        self.assertIn("detail", json.loads(body.decode("utf-8")))

    def test_video_thumbnail_regenerate(self) -> None:
        status, _, _ = self.request("POST", "/api/videos/1/thumbnail/regenerate")
        self.assertEqual(status, 401)

        status, _, body = self.request(
            "POST", "/api/videos/1/thumbnail/regenerate", headers=ADMIN_HEADERS
        )
        self.assertEqual(status, 204)
        self.assertEqual(body, b"")

        status, _, body = self.request(
            "POST", "/api/videos/9999/thumbnail/regenerate", headers=ADMIN_HEADERS
        )
        self.assertEqual(status, 422)
        self.assertIn("detail", json.loads(body.decode("utf-8")))

    # -- programs ----------------------------------------------------------

    def test_programs_search(self) -> None:
        status, _, payload = self.post_json(
            "/api/programs/search", {"keyword": "ショッピング", "is_enabled": True}
        )
        self.assertEqual(status, 200)
        self.assertGreater(payload["total"], 0)
        self.assertEqual(len(payload["programs"]), payload["total"])
        for program in payload["programs"]:
            self.assertTrue(
                any(genre["middle"] == "ショッピング・通販" for genre in program["genres"])
            )
            for field in (
                "id", "channel_id", "network_id", "service_id", "event_id",
                "title", "description", "detail", "start_time", "end_time",
                "duration", "is_free", "genres",
            ):
                self.assertIn(field, program)

        status, _, empty = self.post_json("/api/programs/search", {"keyword": "zzz-no-match"})
        self.assertEqual(status, 200)
        self.assertEqual(empty["total"], 0)
        self.assertEqual(empty["programs"], [])

        # 除外キーワード
        status, _, excluded = self.post_json(
            "/api/programs/search", {"keyword": "ショッピング", "exclude_keyword": "BS"}
        )
        self.assertEqual(status, 200)
        for program in excluded["programs"]:
            self.assertNotIn("BS", program["title"])
        self.assertLess(excluded["total"], payload["total"])

        # ジャンル絞り込み
        status, _, genre_filtered = self.post_json(
            "/api/programs/search",
            {"keyword": "", "genre_ranges": [{"major": "ドラマ", "middle": "国内ドラマ"}]},
        )
        self.assertEqual(status, 200)
        self.assertGreater(genre_filtered["total"], 0)
        for program in genre_filtered["programs"]:
            self.assertTrue(
                any(genre["middle"] == "国内ドラマ" for genre in program["genres"])
            )

    def test_programs_search_accepts_get(self) -> None:
        status, _, payload = self.get_json(
            "/api/programs/search?query=" + quote("ショッピング")
        )
        self.assertEqual(status, 200)
        self.assertGreater(payload["total"], 0)

    def test_programs_timetable(self) -> None:
        status, _, payload = self.get_json("/api/programs/timetable")
        self.assertEqual(status, 200)
        self.assertIn("channels", payload)
        self.assertIn("date_range", payload)
        self.assertIn("earliest", payload["date_range"])
        self.assertIn("latest", payload["date_range"])
        self.assertEqual(len(payload["channels"]), 7)

        served_genres = set()
        for entry in payload["channels"]:
            self.assertIn("channel", entry)
            self.assertIn("programs", entry)
            self.assertIn("subchannels", entry)
            self.assertGreaterEqual(len(entry["programs"]), 12)
            self.assertEqual(entry["channel"]["type"], entry["channel"]["type"].upper())
            for program in entry["programs"]:
                self.assertIn("reservation", program)
                self.assertEqual(program["channel_id"], entry["channel"]["id"])
                for genre in program["genres"]:
                    served_genres.add(genre["middle"])

        self.assertIn("ショッピング・通販", served_genres)
        self.assertIn("国内アニメ", served_genres)
        self.assertIn("定時・総合", served_genres)

    def test_programs_timetable_channel_type_and_pinned(self) -> None:
        status, _, payload = self.get_json("/api/programs/timetable?channel_type=BS")
        self.assertEqual(status, 200)
        self.assertEqual(len(payload["channels"]), 3)
        for entry in payload["channels"]:
            self.assertEqual(entry["channel"]["type"], "BS")

        status, _, payload = self.get_json(
            "/api/programs/timetable?pinned_channel_ids=bs101,gr011"
        )
        self.assertEqual(status, 200)
        self.assertEqual(
            [entry["channel"]["display_channel_id"] for entry in payload["channels"]],
            ["bs101", "gr011"],
        )

        status, _, payload = self.get_json(
            "/api/programs/timetable?start_time=2026-11-02T00:00:00%2B09:00"
            "&end_time=2026-11-02T06:00:00%2B09:00"
        )
        self.assertEqual(status, 200)
        for entry in payload["channels"]:
            self.assertTrue(entry["programs"])
            for program in entry["programs"]:
                self.assertTrue(program["start_time"].startswith("2026-11-02"))
                self.assertLess(program["start_time"], "2026-11-02T06:00:00")

    # -- client settings ---------------------------------------------------

    def test_client_settings_requires_token(self) -> None:
        status, _, _ = self.request("GET", "/api/settings/client")
        self.assertEqual(status, 401)

    def test_client_settings_defaults_match_web_client(self) -> None:
        status, _, payload = self.get_json("/api/settings/client", headers=ADMIN_HEADERS)
        self.assertEqual(status, 200)
        # Web クライアント (SettingsStore.ts) のデフォルト値
        self.assertEqual(payload["last_synced_at"], 0)
        self.assertEqual(payload["pinned_channel_ids"], [])
        self.assertEqual(payload["mylist"], [])
        self.assertEqual(payload["watched_history"], [])
        self.assertEqual(payload["video_watched_history_max_count"], 50)
        self.assertIs(payload["tv_channel_sort_by_jikkyo_force"], False)
        self.assertIs(payload["use_28hour_clock"], False)
        self.assertIs(payload["timetable_dim_shopping_programs"], True)
        self.assertEqual(payload["timetable_channel_width"], "Normal")
        self.assertEqual(payload["panel_display_state"], "RestorePreviousState")
        for key in mock_server.SYNCED_CLIENT_SETTING_KEYS:
            self.assertIn(key, payload)


# ---------------------------------------------------------------------------
# 破壊的な操作 (録画削除 / クライアント設定の更新) は専用のサーバーで検証する
# ---------------------------------------------------------------------------

class MockServerMutationTestCase(unittest.TestCase):
    """Destructive endpoint tests (fresh server per class)."""

    @classmethod
    def setUpClass(cls) -> None:
        cls.server = mock_server.create_server("127.0.0.1", 0)
        cls.host, cls.port = cls.server.server_address[:2]
        cls.thread = threading.Thread(target=cls.server.serve_forever, daemon=True)
        cls.thread.start()

    @classmethod
    def tearDownClass(cls) -> None:
        cls.server.shutdown()
        cls.server.server_close()
        cls.thread.join(timeout=5)

    def request(self, method: str, path: str, body: bytes | None = None,
                headers: dict | None = None):
        conn = http.client.HTTPConnection(self.host, self.port, timeout=10)
        try:
            hdrs = {"Accept": "*/*"}
            if headers:
                hdrs.update(headers)
            conn.request(method, path, body=body, headers=hdrs)
            response = conn.getresponse()
            data = response.read()
            return response.status, dict(response.getheaders()), data
        finally:
            conn.close()

    def get_json(self, path: str, headers: dict | None = None):
        status, response_headers, data = self.request("GET", path, headers=headers)
        return status, response_headers, json.loads(data.decode("utf-8"))

    def put_json(self, path: str, payload, headers: dict | None = None):
        status, response_headers, data = self.request(
            "PUT", path,
            body=json.dumps(payload).encode("utf-8"),
            headers={"Content-Type": "application/json", **(headers or {})},
        )
        return status, response_headers, data

    def stats(self) -> dict:
        status, _, payload = self.get_json("/__mock/stats")
        self.assertEqual(status, 200)
        return payload

    def test_client_settings_put_and_unknown_keys(self) -> None:
        status, _, data = self.request(
            "GET", "/api/settings/client", headers=ADMIN_HEADERS
        )
        self.assertEqual(status, 200)
        settings = json.loads(data.decode("utf-8"))
        settings["last_synced_at"] = 1700000000.5
        settings["pinned_channel_ids"] = ["gr011", "bs101"]
        settings["mylist"] = [{"type": "RecordedProgram", "id": 1, "created_at": 1700000000}]
        settings["watched_history"] = [{
            "video_id": 1,
            "last_playback_position": 12.5,
            "created_at": 1700000000,
            "updated_at": 1700000001,
        }]
        settings["video_watched_history_max_count"] = 10
        settings["unknown_client_key"] = {"nested": [1, 2, 3]}
        settings["future_key"] = "keep-me"

        before = self.stats()["settings_put_count"]
        status, _, body = self.put_json(
            "/api/settings/client", settings, headers=ADMIN_HEADERS
        )
        self.assertEqual(status, 204)
        self.assertEqual(body, b"")
        self.assertEqual(self.stats()["settings_put_count"], before + 1)

        status, _, payload = self.get_json("/api/settings/client", headers=ADMIN_HEADERS)
        self.assertEqual(status, 200)
        self.assertEqual(payload["last_synced_at"], 1700000000.5)
        self.assertEqual(payload["pinned_channel_ids"], ["gr011", "bs101"])
        self.assertEqual(payload["mylist"][0]["id"], 1)
        self.assertEqual(payload["watched_history"][0]["last_playback_position"], 12.5)
        self.assertEqual(payload["video_watched_history_max_count"], 10)
        self.assertEqual(payload["unknown_client_key"], {"nested": [1, 2, 3]})
        self.assertEqual(payload["future_key"], "keep-me")

    def test_client_settings_put_requires_token(self) -> None:
        status, _, _ = self.put_json("/api/settings/client", {"last_synced_at": 1})
        self.assertEqual(status, 401)

    def test_client_settings_put_rejects_outdated_settings(self) -> None:
        status, _, payload = self.get_json("/api/settings/client", headers=ADMIN_HEADERS)
        current = payload["last_synced_at"]
        payload["last_synced_at"] = max(0, current - 100)
        status, _, body = self.put_json(
            "/api/settings/client", payload, headers=ADMIN_HEADERS
        )
        self.assertEqual(status, 422)
        self.assertIn("outdated", json.loads(body.decode("utf-8"))["detail"])

    def test_client_settings_put_requires_last_synced_at(self) -> None:
        status, _, body = self.put_json(
            "/api/settings/client", {"mylist": []}, headers=ADMIN_HEADERS
        )
        self.assertEqual(status, 422)
        self.assertIn("last_synced_at", json.loads(body.decode("utf-8"))["detail"])

    def test_delete_video_requires_admin_and_removes_it(self) -> None:
        status, _, _ = self.request("DELETE", "/api/videos/35")
        self.assertEqual(status, 401)

        before = self.stats()
        status, _, body = self.request(
            "DELETE", "/api/videos/35", headers=ADMIN_HEADERS
        )
        self.assertEqual(status, 204)
        self.assertEqual(body, b"")

        # 録画番組はプロセスの生存期間中は戻らない
        status, _, _ = self.get_json("/api/videos/35")
        self.assertEqual(status, 404)
        status, _, payload = self.get_json("/api/videos?order=desc&page=1")
        self.assertEqual(payload["total"], 34)
        self.assertNotIn(35, [program["id"] for program in payload["recorded_programs"]])

        # 二度目の削除は 422
        status, _, payload = self.get_json(
            "/api/videos/35", headers=ADMIN_HEADERS
        )
        self.assertEqual(status, 404)
        status, _, body = self.request(
            "DELETE", "/api/videos/35", headers=ADMIN_HEADERS
        )
        self.assertEqual(status, 422)

        after = self.stats()
        self.assertEqual(after["video_delete_count"], before["video_delete_count"] + 1)
        self.assertIn(35, after["deleted_video_ids"])


    # -- テスト用: リセット -------------------------------------------------

    def test_mock_reset_restores_initial_state(self) -> None:
        # 設定を更新し、録画番組を削除した状態を作る
        status, _, data = self.request(
            "GET", "/api/settings/client", headers=ADMIN_HEADERS
        )
        self.assertEqual(status, 200)
        settings = json.loads(data.decode("utf-8"))
        settings["last_synced_at"] = 1800000000.0
        settings["mylist"] = [{"type": "RecordedProgram", "id": 3, "created_at": 1800000000}]
        status, _, _ = self.put_json(
            "/api/settings/client", settings, headers=ADMIN_HEADERS
        )
        self.assertEqual(status, 204)

        status, _, _ = self.request(
            "DELETE", "/api/videos/34", headers=ADMIN_HEADERS
        )
        self.assertEqual(status, 204)
        status, _, _ = self.get_json("/api/videos/34")
        self.assertEqual(status, 404)

        before = self.stats()
        self.assertGreaterEqual(before["settings_put_count"], 1)
        self.assertIn(34, before["deleted_video_ids"])

        # リセットするとフィクスチャ・設定・カウンターが初期状態に戻る
        status, _, body = self.request("POST", "/__mock/reset")
        self.assertEqual(status, 200)
        self.assertEqual(json.loads(body.decode("utf-8")), {"status": "ok"})

        after = self.stats()
        self.assertEqual(after["settings_put_count"], 0)
        self.assertEqual(after["video_delete_count"], 0)
        self.assertEqual(after["deleted_video_ids"], [])
        self.assertEqual(after["keepalive"], {})
        self.assertEqual(after["live_total"], 0)

        status, _, payload = self.get_json("/api/settings/client", headers=ADMIN_HEADERS)
        self.assertEqual(status, 200)
        self.assertEqual(payload["last_synced_at"], 0)
        self.assertEqual(payload["mylist"], [])

        status, _, program = self.get_json("/api/videos/34")
        self.assertEqual(status, 200)
        self.assertEqual(program["id"], 34)

        # リセット後も通常の API は動き続ける
        status, _, payload = self.get_json("/api/videos?order=desc&page=1")
        self.assertEqual(status, 200)
        self.assertEqual(payload["total"], 35)


# ---------------------------------------------------------------------------
# ニコニコ実況 (WebSocket) / ニコニコ OAuth
# ---------------------------------------------------------------------------

class WebSocketTestClient:
    """Tiny RFC 6455 client (stdlib only) used by the jikkyo tests.

    Client frames must be masked, so every frame written here is.
    """

    OPCODE_CONTINUATION = 0x0
    OPCODE_TEXT = 0x1
    OPCODE_CLOSE = 0x8
    OPCODE_PING = 0x9
    OPCODE_PONG = 0xA

    def __init__(self, host: str, port: int, path: str, timeout: float = 10.0) -> None:
        self.sock = socket.create_connection((host, port), timeout=timeout)
        self.buffer = b""
        key = base64.b64encode(os.urandom(16)).decode("ascii")
        request = (
            "GET " + path + " HTTP/1.1\r\n"
            "Host: " + host + ":" + str(port) + "\r\n"
            "Upgrade: websocket\r\n"
            "Connection: Upgrade\r\n"
            "Sec-WebSocket-Key: " + key + "\r\n"
            "Sec-WebSocket-Version: 13\r\n"
            "\r\n"
        )
        self.sock.sendall(request.encode("ascii"))

        head = self._read_until(b"\r\n\r\n").decode("latin-1")
        status_line = head.split("\r\n")[0]
        self.status = int(status_line.split(" ")[1])
        expected = base64.b64encode(
            hashlib.sha1((key + mock_server.WS_GUID).encode("ascii")).digest()
        ).decode("ascii")
        if "Sec-WebSocket-Accept: " + expected not in head:
            raise RuntimeError("invalid Sec-WebSocket-Accept: " + head)

    # -- low level ---------------------------------------------------------

    def _read_until(self, marker: bytes) -> bytes:
        while marker not in self.buffer:
            chunk = self.sock.recv(4096)
            if not chunk:
                raise RuntimeError("connection closed during the handshake")
            self.buffer += chunk
        head, _, self.buffer = self.buffer.partition(marker)
        return head

    def _read_exact(self, size: int) -> bytes:
        while len(self.buffer) < size:
            chunk = self.sock.recv(4096)
            if not chunk:
                raise RuntimeError("connection closed")
            self.buffer += chunk
        data, self.buffer = self.buffer[:size], self.buffer[size:]
        return data

    def _send_frame(self, opcode: int, payload: bytes = b"") -> None:
        frame = bytearray([0x80 | opcode])
        length = len(payload)
        if length < 126:
            frame.append(0x80 | length)
        elif length < 65536:
            frame.append(0x80 | 126)
            frame.extend(struct.pack(">H", length))
        else:
            frame.append(0x80 | 127)
            frame.extend(struct.pack(">Q", length))
        mask = os.urandom(4)
        frame.extend(mask)
        frame.extend(bytes(byte ^ mask[index % 4] for index, byte in enumerate(payload)))
        self.sock.sendall(bytes(frame))

    def send_text(self, text: str) -> None:
        self._send_frame(self.OPCODE_TEXT, text.encode("utf-8"))

    def send_json(self, payload) -> None:
        self.send_text(json.dumps(payload, ensure_ascii=False))

    def recv_frame(self):
        header = self._read_exact(2)
        first, second = header[0], header[1]
        opcode = first & 0x0F
        length = second & 0x7F
        if length == 126:
            length = struct.unpack(">H", self._read_exact(2))[0]
        elif length == 127:
            length = struct.unpack(">Q", self._read_exact(8))[0]
        payload = self._read_exact(length) if length else b""
        return opcode, payload

    def recv_text(self, limit: int = 200):
        """Next text payload, or None once the server closed the connection."""
        for _ in range(limit):
            opcode, payload = self.recv_frame()
            if opcode == self.OPCODE_PING:
                # 実クライアントと同じく pong を返す
                self._send_frame(self.OPCODE_PONG, payload)
                continue
            if opcode == self.OPCODE_PONG:
                continue
            if opcode == self.OPCODE_CLOSE:
                return None
            return payload.decode("utf-8")
        raise RuntimeError("no text frame received")

    def recv_json(self, limit: int = 200):
        text = self.recv_text(limit)
        if text is None:
            return None
        return json.loads(text)

    def recv_until(self, predicate, limit: int = 60):
        for _ in range(limit):
            payload = self.recv_json()
            if payload is None:
                return None
            if predicate(payload):
                return payload
        return None

    def close(self) -> None:
        try:
            self._send_frame(self.OPCODE_CLOSE, struct.pack(">H", 1000))
        except OSError:
            pass
        try:
            self.sock.close()
        except OSError:
            pass


class JikkyoMockTestCase(unittest.TestCase):
    """ニコニコ実況のモック (REST / WebSocket / Niconico OAuth)."""

    @classmethod
    def setUpClass(cls) -> None:
        cls.server = mock_server.create_server("127.0.0.1", 0)
        cls.host, cls.port = cls.server.server_address[:2]
        cls.thread = threading.Thread(target=cls.server.serve_forever, daemon=True)
        cls.thread.start()

    @classmethod
    def tearDownClass(cls) -> None:
        cls.server.shutdown()
        cls.server.server_close()
        cls.thread.join(timeout=5)

    # -- helpers -----------------------------------------------------------

    def request(self, method: str, path: str, body: bytes | None = None,
                headers: dict | None = None):
        conn = http.client.HTTPConnection(self.host, self.port, timeout=10)
        try:
            hdrs = {"Accept": "*/*"}
            if headers:
                hdrs.update(headers)
            conn.request(method, path, body=body, headers=hdrs)
            response = conn.getresponse()
            data = response.read()
            return response.status, dict(response.getheaders()), data
        finally:
            conn.close()

    def get_json(self, path: str, headers: dict | None = None):
        status, response_headers, data = self.request("GET", path, headers=headers)
        return status, response_headers, json.loads(data.decode("utf-8"))

    def stats(self) -> dict:
        status, _, payload = self.get_json("/__mock/stats")
        self.assertEqual(status, 200)
        return payload

    def reset(self) -> None:
        status, _, _ = self.request("POST", "/__mock/reset")
        self.assertEqual(status, 200)

    def connect(self, path: str) -> WebSocketTestClient:
        return WebSocketTestClient(self.host, self.port, path)

    # -- REST --------------------------------------------------------------

    def test_channel_jikkyo_returns_mock_websocket_urls(self) -> None:
        status, _, payload = self.get_json("/api/channels/gr011/jikkyo")
        self.assertEqual(status, 200)
        for field in (
            "watch_session_url", "nicolive_watch_session_url",
            "nicolive_watch_session_error", "comment_session_url",
            "is_nxjikkyo_exclusive",
        ):
            self.assertIn(field, payload)

        base = "ws://127.0.0.1:" + str(self.port)
        self.assertEqual(
            payload["watch_session_url"], base + "/__mock/jikkyo/watch/gr011"
        )
        self.assertEqual(
            payload["comment_session_url"], base + "/__mock/jikkyo/comment/gr011"
        )
        self.assertIsNone(payload["nicolive_watch_session_url"])
        self.assertIsNone(payload["nicolive_watch_session_error"])
        self.assertFalse(payload["is_nxjikkyo_exclusive"])

        # 通常の id (NID32736-SID1024) でも引ける
        status, _, by_id = self.get_json("/api/channels/NID32736-SID1024/jikkyo")
        self.assertEqual(status, 200)
        self.assertIn("/__mock/jikkyo/watch/", by_id["watch_session_url"])

        status, _, _ = self.request("GET", "/api/channels/zz999/jikkyo")
        self.assertEqual(status, 422)

    def test_video_jikkyo_past_log(self) -> None:
        status, _, payload = self.get_json("/api/videos/1/jikkyo")
        self.assertEqual(status, 200)
        self.assertTrue(payload["is_success"])
        self.assertEqual(payload["detail"], "Success")
        comments = payload["comments"]
        self.assertEqual(len(comments), mock_server.JIKKYO_PAST_COMMENT_COUNT)

        status, _, program = self.get_json("/api/videos/1")
        duration = program["recorded_video"]["duration"]

        times = []
        for comment in comments:
            self.assertIn(comment["type"], ("top", "right", "bottom"))
            self.assertIn(comment["size"], ("big", "medium", "small"))
            self.assertRegex(comment["color"], r"^#[0-9A-F]{6}$")
            self.assertTrue(comment["text"])
            self.assertTrue(comment["author"])
            self.assertGreater(comment["time"], 0)
            self.assertLess(comment["time"], duration)
            times.append(comment["time"])
        self.assertEqual(times, sorted(times))

        # 色付き・上固定・大きいコメントが混ざっている
        self.assertIn("top", {c["type"] for c in comments})
        self.assertIn("right", {c["type"] for c in comments})
        self.assertIn("big", {c["size"] for c in comments})
        self.assertIn("#F02840", {c["color"] for c in comments})
        # 露骨な表現 (組み込みのミュート対象) も 1 件は入っている
        self.assertTrue(any("エッチ" in c["text"] for c in comments))

        status, _, _ = self.request("GET", "/api/videos/9999/jikkyo")
        self.assertEqual(status, 404)

    # -- WebSocket ---------------------------------------------------------

    def test_watch_session_start_watching(self) -> None:
        client = self.connect("/__mock/jikkyo/watch/gr011")
        try:
            self.assertEqual(client.status, 101)
            client.send_json({"type": "startWatching", "data": {"reconnect": False}})

            seat = client.recv_json()
            self.assertIsNotNone(seat)
            self.assertEqual(seat["type"], "seat")
            self.assertEqual(
                seat["data"]["keepIntervalSec"],
                mock_server.JIKKYO_SEAT_KEEP_INTERVAL_SEC,
            )

            room = client.recv_json()
            self.assertIsNotNone(room)
            self.assertEqual(room["type"], "room")
            data = room["data"]
            self.assertEqual(data["threadId"], "mock-thread-gr011")
            self.assertEqual(data["yourPostKey"], mock_server.JIKKYO_MOCK_USER_KEY)
            # コメントセッションの URL がモックサーバー自身を指している
            self.assertEqual(
                data["messageServer"]["uri"],
                "ws://127.0.0.1:" + str(self.port) + "/__mock/jikkyo/comment/gr011",
            )
            # vposBaseTime は ISO 8601 (+09:00)
            self.assertTrue(data["vposBaseTime"].endswith("+09:00"))

            # keepSeat を送ってもセッションが切れない
            client.send_json({"type": "keepSeat"})
            client.send_json({"type": "pong"})

            # The server handles the frames on its own thread: wait for it.
            deadline = time.monotonic() + 5
            stats = self.stats()
            while stats["jikkyo_keep_seat_count"] < 1 and time.monotonic() < deadline:
                time.sleep(0.05)
                stats = self.stats()
            self.assertGreaterEqual(stats["jikkyo_watch_total"], 1)
            self.assertGreaterEqual(stats["jikkyo_watch_active"], 1)
            self.assertGreaterEqual(stats["jikkyo_keep_seat_count"], 1)
        finally:
            client.close()

    def test_comment_session_streams_comments(self) -> None:
        client = self.connect("/__mock/jikkyo/comment/gr011")
        try:
            self.assertEqual(client.status, 101)
            # クライアントはスレッドリクエストを送らないとコメントを受け取れない
            client.send_text(json.dumps([
                {"ping": {"content": "rs:0"}},
                {"ping": {"content": "ps:0"}},
                {
                    "thread": {
                        "version": "20061206",
                        "thread": "mock-thread-gr011",
                        "threadkey": "nicolive:mock-user",
                        "user_id": "",
                        "res_from": -100,
                    }
                },
                {"ping": {"content": "pf:0"}},
                {"ping": {"content": "rf:0"}},
            ]))

            thread = client.recv_json()
            self.assertIsNotNone(thread)
            self.assertEqual(thread["thread"]["resultcode"], 0)
            self.assertEqual(thread["thread"]["thread"], "mock-thread-gr011")

            # 接続直後に過去コメントがまとめて送られてくる
            history = []
            while True:
                message = client.recv_json()
                self.assertIsNotNone(message)
                if message.get("ping", {}).get("content") == "rf:0":
                    break
                self.assertIn("chat", message)
                history.append(message["chat"])
            self.assertEqual(len(history), mock_server.JIKKYO_INITIAL_COMMENT_COUNT)

            for chat in history:
                for field in (
                    "no", "thread", "vpos", "date", "mail", "user_id",
                    "content", "anonymity", "yourpost",
                ):
                    self.assertIn(field, chat)

            mails = {chat["mail"] for chat in history}
            self.assertTrue(any("big" in mail for mail in mails))
            self.assertTrue(any("ue" in mail for mail in mails))
            self.assertTrue(any(chat["content"] == "エッチな話をしよう" for chat in history))

            # rf:0 のあとは 1 秒ごとに新着コメントが流れ続ける
            live = client.recv_json()
            self.assertIsNotNone(live)
            self.assertIn("chat", live)
            self.assertGreater(live["chat"]["no"], history[-1]["no"])
            self.assertEqual(live["chat"]["thread"], "mock-thread-gr011")

            stats = self.stats()
            self.assertGreaterEqual(stats["jikkyo_comment_total"], 1)
            self.assertGreaterEqual(stats["jikkyo_comment_active"], 1)
        finally:
            client.close()

    def test_posted_comment_is_broadcast_to_comment_session(self) -> None:
        comment_client = self.connect("/__mock/jikkyo/comment/gr011")
        watch_client = self.connect("/__mock/jikkyo/watch/gr011")
        try:
            comment_client.send_json([{"thread": {"version": "20061206", "thread": "", "user_id": "", "res_from": -100}}])
            thread = comment_client.recv_json()
            self.assertEqual(thread["thread"]["resultcode"], 0)
            # rf:0 まで読み飛ばす (その後は新着コメントが流れてくる)
            while True:
                message = comment_client.recv_json()
                self.assertIsNotNone(message)
                if message.get("ping", {}).get("content") == "rf:0":
                    break

            watch_client.send_json({"type": "startWatching", "data": {"reconnect": False}})
            self.assertEqual(watch_client.recv_json()["type"], "seat")
            self.assertEqual(watch_client.recv_json()["type"], "room")

            watch_client.send_json({
                "type": "postComment",
                "data": {
                    "text": "モックへの投稿テスト",
                    "color": "red",
                    "position": "naka",
                    "size": "medium",
                    "vpos": 1234,
                    "isAnonymous": True,
                },
            })

            result = watch_client.recv_until(
                lambda payload: payload.get("type") == "postCommentResult"
            )
            self.assertIsNotNone(result)
            self.assertEqual(result["data"]["chat"]["content"], "モックへの投稿テスト")
            self.assertEqual(result["data"]["chat"]["yourpost"], 1)

            # 同じチャンネルのコメントセッションにも流れてくる
            broadcast = comment_client.recv_until(
                lambda payload: payload.get("chat", {}).get("content") == "モックへの投稿テスト"
            )
            self.assertIsNotNone(broadcast)
            self.assertEqual(broadcast["chat"]["user_id"], mock_server.JIKKYO_MOCK_USER_KEY)
            self.assertEqual(broadcast["chat"]["yourpost"], 1)
            self.assertEqual(broadcast["chat"]["mail"], "184 naka medium red")

            stats = self.stats()
            self.assertIn("モックへの投稿テスト", stats["jikkyo_posted_comments"])
        finally:
            watch_client.close()
            comment_client.close()

    def test_jikkyo_stats_and_reset(self) -> None:
        client = self.connect("/__mock/jikkyo/watch/bs101")
        try:
            client.send_json({"type": "startWatching", "data": {"reconnect": False}})
            self.assertEqual(client.recv_json()["type"], "seat")
            self.assertEqual(client.recv_json()["type"], "room")
        finally:
            client.close()

        stats = self.stats()
        for field in (
            "jikkyo_watch_active", "jikkyo_watch_total",
            "jikkyo_comment_active", "jikkyo_comment_total",
            "jikkyo_keep_seat_count", "jikkyo_posted_comments",
            "niconico_authorize_count", "niconico_link_count", "niconico_unlink_count",
        ):
            self.assertIn(field, stats)
        self.assertGreaterEqual(stats["jikkyo_watch_total"], 1)

        self.reset()
        reset_stats = self.stats()
        self.assertEqual(reset_stats["jikkyo_watch_total"], 0)
        self.assertEqual(reset_stats["jikkyo_comment_total"], 0)
        self.assertEqual(reset_stats["jikkyo_posted_comments"], [])
        self.assertEqual(reset_stats["niconico_authorize_count"], 0)
        self.assertEqual(reset_stats["niconico_link_count"], 0)
        self.assertEqual(reset_stats["niconico_unlink_count"], 0)

        # リセット後もエンドポイントは動き続ける
        status, _, payload = self.get_json("/api/channels/gr011/jikkyo")
        self.assertEqual(status, 200)
        self.assertIn("/__mock/jikkyo/watch/gr011", payload["watch_session_url"])

    # -- Niconico OAuth ----------------------------------------------------

    def test_niconico_oauth_link_and_unlink(self) -> None:
        admin_headers = {"Authorization": "Bearer " + mock_server.MOCK_ACCESS_TOKEN}

        status, _, me = self.get_json("/api/users/me", headers=admin_headers)
        self.assertEqual(status, 200)
        self.assertIsNone(me["niconico_user_id"])

        status, _, _ = self.request("GET", "/api/niconico/auth")
        self.assertEqual(status, 401)

        status, _, payload = self.get_json("/api/niconico/auth", headers=admin_headers)
        self.assertEqual(status, 200)
        self.assertIn("authorization_url", payload)
        auth_url = payload["authorization_url"]
        self.assertTrue(auth_url.startswith("http://127.0.0.1:" + str(self.port)))
        self.assertIn("/__mock/niconico/authorize?", auth_url)
        self.assertIn("state=", auth_url)

        # 認可ページはすぐにサーバーのコールバックへリダイレクトする
        path = auth_url.split("://", 1)[1]
        path = path[path.index("/"):]
        status, headers, _ = self.request("GET", path)
        self.assertEqual(status, 302)
        location = headers.get("Location", "")
        self.assertTrue(location.startswith("/api/niconico/callback?"))
        self.assertIn("client=" + quote("http://127.0.0.1:" + str(self.port) + "/", safe=""), location)
        self.assertIn("user_access_token=" + mock_server.MOCK_ACCESS_TOKEN, location)
        self.assertIn("code=", location)

        # コールバックでニコニコアカウントが紐づく
        status, headers, body = self.request("GET", location)
        self.assertEqual(status, 200)
        self.assertIn("text/html", headers.get("Content-Type", ""))
        html = body.decode("utf-8")
        self.assertIn("/settings/jikkyo", html)
        self.assertIn("Success", html)

        status, _, me = self.get_json("/api/users/me", headers=admin_headers)
        self.assertEqual(me["niconico_user_id"], mock_server.MOCK_NICONICO_USER_ID)
        self.assertEqual(me["niconico_user_name"], mock_server.MOCK_NICONICO_USER_NAME)
        self.assertIs(me["niconico_user_premium"], mock_server.MOCK_NICONICO_USER_PREMIUM)

        stats = self.stats()
        self.assertGreaterEqual(stats["niconico_authorize_count"], 1)
        self.assertGreaterEqual(stats["niconico_link_count"], 1)

        # 連携解除 (実サーバーと同じく DELETE のみ)
        status, _, _ = self.request("DELETE", "/api/niconico/logout")
        self.assertEqual(status, 401)
        status, _, _ = self.request("DELETE", "/api/niconico/logout", headers=admin_headers)
        self.assertEqual(status, 204)
        status, _, me = self.get_json("/api/users/me", headers=admin_headers)
        self.assertIsNone(me["niconico_user_id"])
        self.assertIsNone(me["niconico_user_name"])
        self.assertIsNone(me["niconico_user_premium"])
        self.assertGreaterEqual(self.stats()["niconico_unlink_count"], 1)

    def test_niconico_callback_rejects_bad_token(self) -> None:
        status, _, body = self.request(
            "GET",
            "/api/niconico/callback?client=" + quote("http://127.0.0.1:" + str(self.port) + "/", safe="")
            + "&user_access_token=invalid&code=mock-authorization-code",
        )
        self.assertEqual(status, 401)
        self.assertIn("Unauthorized", body.decode("utf-8"))
        # ユーザーは連携されないまま
        status, _, me = self.get_json(
            "/api/users/me",
            headers={"Authorization": "Bearer " + mock_server.MOCK_ACCESS_TOKEN},
        )
        self.assertIsNone(me["niconico_user_id"])

    def test_niconico_authorize_can_deny(self) -> None:
        admin_headers = {"Authorization": "Bearer " + mock_server.MOCK_ACCESS_TOKEN}
        status, _, payload = self.get_json("/api/niconico/auth", headers=admin_headers)
        self.assertEqual(status, 200)
        auth_url = payload["authorization_url"]
        path = auth_url.split("://", 1)[1]
        path = path[path.index("/"):]
        status, headers, _ = self.request("GET", path + "&deny=1")
        self.assertEqual(status, 302)
        location = headers.get("Location", "")
        self.assertIn("error=access_denied", location)

        status, _, _ = self.request("GET", location)
        self.assertEqual(status, 401)
        status, _, me = self.get_json("/api/users/me", headers=admin_headers)
        self.assertIsNone(me["niconico_user_id"])


    # -- キャプチャ ---------------------------------------------------------

    def capture_auth(self) -> dict:
        return {"Authorization": "Bearer " + mock_server.MOCK_ACCESS_TOKEN}

    def multipart_capture_body(
        self,
        filename: str,
        data: bytes,
        boundary: str = "MOCKBOUNDARY",
        file_modified_at: int | None = None,
    ) -> tuple[bytes, str]:
        parts = [
            b"--" + boundary.encode() + b"\r\n",
            (
                'Content-Disposition: form-data; name="image"; filename="'
                + filename
                + '"\r\n'
            ).encode(),
            b"Content-Type: image/png\r\n",
            b"\r\n",
            data,
            b"\r\n",
        ]
        if file_modified_at is not None:
            parts.extend(
                [
                    b"--" + boundary.encode() + b"\r\n",
                    b'Content-Disposition: form-data; name="file_modified_at"\r\n',
                    b"\r\n",
                    str(file_modified_at).encode(),
                    b"\r\n",
                ]
            )
        parts.append(b"--" + boundary.encode() + b"--\r\n")
        return b"".join(parts), "multipart/form-data; boundary=" + boundary

    def test_captures_list_and_keyset_pagination(self) -> None:
        self.reset()
        status, _, payload = self.get_json("/api/captures?order=CapturedAtDesc&limit=3")
        self.assertEqual(status, 200)
        self.assertEqual(len(payload["captures"]), 3)
        self.assertIsNotNone(payload["next_cursor"])
        self.assertIsInstance(payload["programs"], list)
        first_ids = [capture["id"] for capture in payload["captures"]]
        for field in (
            "id", "file_hash", "file_size", "captured_at", "broadcast_at",
            "image_width", "image_height", "metadata_status",
            "playback_position", "caption_text", "is_caption_composited",
            "is_comment_composited", "capture_program_id", "is_favorite",
            "tag_ids",
        ):
            self.assertIn(field, payload["captures"][0])
        # 匿名ではお気に入りとタグの状態は返らない
        self.assertIsNone(payload["captures"][0]["is_favorite"])
        self.assertIsNone(payload["captures"][0]["tag_ids"])

        status, _, page2 = self.get_json(
            "/api/captures?order=CapturedAtDesc&limit=3&cursor="
            + quote(payload["next_cursor"], safe="")
        )
        self.assertEqual(status, 200)
        second_ids = [capture["id"] for capture in page2["captures"]]
        self.assertFalse(set(first_ids) & set(second_ids))

    def test_captures_filters_and_anonymous_auth_rules(self) -> None:
        self.reset()
        status, _, payload = self.get_json("/api/captures?has_caption_text=true&order=CapturedAtAsc")
        self.assertEqual(status, 200)
        self.assertTrue(payload["captures"])
        self.assertTrue(all(c["caption_text"] for c in payload["captures"]))

        status, _, payload = self.get_json("/api/captures?is_caption_composited=false")
        self.assertEqual(status, 200)
        self.assertTrue(all(c["is_caption_composited"] is False for c in payload["captures"]))

        status, _, payload = self.get_json("/api/captures?query=" + quote("ニュース"))
        self.assertEqual(status, 200)
        self.assertTrue(payload["captures"])

        status, _, payload = self.get_json("/api/captures?query_targets=CaptionText&query=" + quote("政府"))
        self.assertEqual(status, 200)
        self.assertEqual([c["id"] for c in payload["captures"]], [2])

        status, _, _ = self.get_json("/api/captures?is_favorite=true")
        self.assertEqual(status, 401)
        status, _, _ = self.get_json("/api/captures?tag_ids=1")
        self.assertEqual(status, 401)

        status, _, _ = self.get_json("/api/captures?network_id=32736")
        self.assertEqual(status, 422)

        status, _, payload = self.get_json(
            "/api/captures?network_id=32736&service_id=1024&event_id=10001"
            "&start_time=" + quote("2026-11-03T20:00:00+09:00", safe="")
        )
        self.assertEqual(status, 200)
        self.assertTrue(payload["captures"])
        self.assertTrue(all(c["capture_program_id"] == 1 for c in payload["captures"]))

        status, _, payload = self.get_json("/api/captures?channel_ids=bs101")
        self.assertEqual(status, 200)
        self.assertTrue(payload["captures"])
        self.assertTrue(all(c["capture_program_id"] == 3 for c in payload["captures"]))

        status, _, payload = self.get_json("/api/captures?date=2026-11-02")
        self.assertEqual(status, 200)
        self.assertTrue(payload["captures"])
        self.assertTrue(all(c["captured_at"].startswith("2026-11-02") for c in payload["captures"]))
        status, _, payload = self.get_json("/api/captures?order=BroadcastAtDesc")
        self.assertEqual(status, 200)
        self.assertTrue(all(c["broadcast_at"] is not None for c in payload["captures"]))

    def test_captures_sections(self) -> None:
        self.reset()
        status, _, payload = self.get_json("/api/captures/sections?axis=CapturedAt")
        self.assertEqual(status, 200)
        self.assertEqual(payload["total"], sum(s["count"] for s in payload["sections"]))
        self.assertEqual(
            [s["date"] for s in payload["sections"]],
            sorted((s["date"] for s in payload["sections"]), reverse=True),
        )
        self.assertIn("2026-11-03", [s["date"] for s in payload["sections"]])

        status, _, payload = self.get_json("/api/captures/sections?axis=BroadcastAt")
        self.assertEqual(status, 200)
        self.assertGreaterEqual(payload["total"], 1)

    def test_captures_channels(self) -> None:
        self.reset()
        status, _, payload = self.get_json("/api/captures/channels")
        self.assertEqual(status, 200)
        self.assertIsInstance(payload, list)
        ids = {channel["display_channel_id"] for channel in payload}
        self.assertIn("gr011", ids)
        self.assertIn("bs101", ids)
        for channel in payload:
            self.assertEqual(set(channel), {"id", "display_channel_id", "name", "type"})

    def test_captures_program_albums(self) -> None:
        self.reset()
        status, _, payload = self.get_json("/api/captures/programs?limit=2")
        self.assertEqual(status, 200)
        self.assertEqual(len(payload["programs"]), 2)
        self.assertIsNotNone(payload["next_cursor"])
        album = payload["programs"][0]
        for field in ("capture_count", "cover_capture", "title", "channel", "recorded_program_ids"):
            self.assertIn(field, album)
        self.assertGreaterEqual(album["capture_count"], 1)

        status, _, payload = self.get_json("/api/captures/programs?query=" + quote("ニュース7"))
        self.assertEqual(status, 200)
        self.assertTrue(payload["programs"])
        self.assertTrue(all("ニュース7" in album["title"] for album in payload["programs"]))

        status, _, payload = self.get_json("/api/captures/programs?has_recorded_program=true")
        self.assertEqual(status, 200)
        for album in payload["programs"]:
            self.assertTrue(album["recorded_program_ids"])

        status, _, payload = self.get_json("/api/captures/programs/1")
        self.assertEqual(status, 200)
        self.assertEqual(payload["id"], 1)
        self.assertGreaterEqual(payload["capture_count"], 1)
        status, _, _ = self.get_json("/api/captures/programs/9999")
        self.assertEqual(status, 404)

    def test_capture_detail_and_image(self) -> None:
        self.reset()
        status, _, payload = self.get_json("/api/captures/1")
        self.assertEqual(status, 200)
        self.assertEqual(payload["id"], 1)
        self.assertIsNotNone(payload["program"])
        self.assertEqual(payload["files"][0]["status"], "Available")

        image_path = (
            "/api/captures/1/image?hash=" + payload["file_hash"]
        )
        status, headers, body = self.request("GET", image_path)
        self.assertEqual(status, 200)
        self.assertEqual(headers.get("Content-Type"), "image/png")
        self.assertTrue(body.startswith(b"\x89PNG\r\n\x1a\n"))
        self.assertEqual(headers.get("ETag"), '"' + payload["file_hash"] + '"')

        status, _, _ = self.request("GET", "/api/captures/1/image?hash=" + "0" * 64)
        self.assertEqual(status, 404)
        status, _, _ = self.get_json("/api/captures/9999")
        self.assertEqual(status, 404)

    def test_capture_tags_crud_and_auth(self) -> None:
        self.reset()
        status, _, _ = self.get_json("/api/captures/tags")
        self.assertEqual(status, 401)

        status, _, tags = self.get_json("/api/captures/tags", headers=self.capture_auth())
        self.assertEqual(status, 200)
        self.assertEqual([tag["name"] for tag in tags], sorted(tag["name"] for tag in tags))
        self.assertGreaterEqual(tags[0]["capture_count"], 1)

        status, _, body = self.request(
            "POST",
            "/api/captures/tags",
            body=json.dumps({"name": " 新タグ "}).encode(),
            headers={**self.capture_auth(), "Content-Type": "application/json"},
        )
        self.assertEqual(status, 201)
        created = json.loads(body)
        self.assertEqual(created["name"], "新タグ")
        self.assertEqual(created["capture_count"], 0)

        status, _, body = self.request(
            "POST",
            "/api/captures/tags",
            body=json.dumps({"name": "新タグ"}).encode(),
            headers={**self.capture_auth(), "Content-Type": "application/json"},
        )
        self.assertEqual(status, 422)

        status, _, body = self.request(
            "PUT",
            "/api/captures/tags/" + str(created["id"]),
            body=json.dumps({"name": "改名タグ"}).encode(),
            headers={**self.capture_auth(), "Content-Type": "application/json"},
        )
        self.assertEqual(status, 200)
        self.assertEqual(json.loads(body)["name"], "改名タグ")

        status, _, _ = self.request(
            "DELETE",
            "/api/captures/tags/" + str(created["id"]),
            headers=self.capture_auth(),
        )
        self.assertEqual(status, 204)
        status, _, _ = self.request(
            "PUT",
            "/api/captures/tags/" + str(created["id"]),
            body=json.dumps({"name": "x"}).encode(),
            headers={**self.capture_auth(), "Content-Type": "application/json"},
        )
        self.assertEqual(status, 404)

    def test_capture_favorites_and_tag_items(self) -> None:
        self.reset()
        status, _, _ = self.request(
            "POST",
            "/api/captures/favorites",
            body=json.dumps({"capture_ids": [2]}).encode(),
            headers={"Content-Type": "application/json"},
        )
        self.assertEqual(status, 401)

        status, _, payload = self.get_json(
            "/api/captures/2",
            headers=self.capture_auth(),
        )
        self.assertEqual(status, 200)
        self.assertFalse(payload["is_favorite"])

        status, _, _ = self.request(
            "POST",
            "/api/captures/favorites",
            body=json.dumps({"capture_ids": [2, 3]}).encode(),
            headers={**self.capture_auth(), "Content-Type": "application/json"},
        )
        self.assertEqual(status, 204)
        status, _, payload = self.get_json("/api/captures/2", headers=self.capture_auth())
        self.assertTrue(payload["is_favorite"])
        status, _, listing = self.get_json(
            "/api/captures?is_favorite=true", headers=self.capture_auth()
        )
        self.assertEqual(status, 200)
        self.assertIn(2, [c["id"] for c in listing["captures"]])
        self.assertTrue(all(c["is_favorite"] for c in listing["captures"]))

        status, _, _ = self.request(
            "DELETE",
            "/api/captures/favorites",
            body=json.dumps({"capture_ids": [2, 3]}).encode(),
            headers={**self.capture_auth(), "Content-Type": "application/json"},
        )
        self.assertEqual(status, 204)
        status, _, payload = self.get_json("/api/captures/2", headers=self.capture_auth())
        self.assertFalse(payload["is_favorite"])

        # タグ付け (タグ 2 は 1, 5, 9 に付いている)
        status, _, payload = self.get_json("/api/captures/2", headers=self.capture_auth())
        self.assertNotIn(2, payload["tag_ids"])
        status, _, _ = self.request(
            "POST",
            "/api/captures/tags/2/items",
            body=json.dumps({"capture_ids": [2]}).encode(),
            headers={**self.capture_auth(), "Content-Type": "application/json"},
        )
        self.assertEqual(status, 204)
        status, _, payload = self.get_json("/api/captures/2", headers=self.capture_auth())
        self.assertIn(2, payload["tag_ids"])
        status, _, tag_list = self.get_json("/api/captures/tags", headers=self.capture_auth())
        tag2 = next(tag for tag in tag_list if tag["id"] == 2)
        self.assertGreaterEqual(tag2["capture_count"], 1)

        status, _, _ = self.request(
            "DELETE",
            "/api/captures/tags/2/items",
            body=json.dumps({"capture_ids": [2]}).encode(),
            headers={**self.capture_auth(), "Content-Type": "application/json"},
        )
        self.assertEqual(status, 204)
        status, _, payload = self.get_json("/api/captures/2", headers=self.capture_auth())
        self.assertNotIn(2, payload["tag_ids"])

        # 存在しないキャプチャ ID は変更前に 404
        status, _, _ = self.request(
            "POST",
            "/api/captures/favorites",
            body=json.dumps({"capture_ids": [9999]}).encode(),
            headers={**self.capture_auth(), "Content-Type": "application/json"},
        )
        self.assertEqual(status, 404)

    def test_capture_delete_requires_admin(self) -> None:
        self.reset()
        status, _, _ = self.request(
            "DELETE",
            "/api/captures",
            body=json.dumps({"capture_ids": [1]}).encode(),
            headers={"Content-Type": "application/json"},
        )
        self.assertEqual(status, 401)

        status, _, body = self.request(
            "DELETE",
            "/api/captures",
            body=json.dumps({"capture_ids": [1, 9999]}).encode(),
            headers={**self.capture_auth(), "Content-Type": "application/json"},
        )
        self.assertEqual(status, 200)
        result = json.loads(body)
        self.assertEqual(result["deleted_capture_ids"], [1])
        self.assertEqual(result["failed_capture_ids"], [9999])
        status, _, _ = self.get_json("/api/captures/1")
        self.assertEqual(status, 404)

    def test_capture_upload_round_trip(self) -> None:
        self.reset()
        image = captures_mock.build_capture_png(77)
        body, content_type = self.multipart_capture_body(
            "Capture_20261103-220000.png",
            image,
            file_modified_at=1793710800000,
        )
        status, _, response_body = self.request(
            "POST",
            "/api/captures",
            body=body,
            headers={"Content-Type": content_type},
        )
        self.assertEqual(status, 201)
        uploaded = json.loads(response_body)
        self.assertIsNone(uploaded["broadcast_at"])
        self.assertEqual(uploaded["metadata_status"], "NoMetadata")
        self.assertEqual(uploaded["image_width"], 160)
        self.assertEqual(uploaded["image_height"], 90)
        self.assertEqual(uploaded["file_size"], len(image))

        # 一覧に現れる
        status, _, listing = self.get_json("/api/captures?order=CapturedAtDesc&limit=200")
        self.assertEqual(status, 200)
        self.assertIn(uploaded["id"], [c["id"] for c in listing["captures"]])

        # 画像も取得できる
        status, headers, served = self.request(
            "GET", f"/api/captures/{uploaded['id']}/image?hash={uploaded['file_hash']}"
        )
        self.assertEqual(status, 200)
        self.assertEqual(served, image)
        self.assertEqual(headers.get("Content-Type"), "image/png")

        stats = self.stats()
        self.assertGreaterEqual(stats["capture_upload_count"], 1)
        last = stats["last_capture_upload"]
        self.assertEqual(last["filename"], "Capture_20261103-220000.png")
        self.assertEqual(last["size"], len(image))
        self.assertIn("image", last["fields"])
        self.assertEqual(last["fields"]["image"][0]["filename"], "Capture_20261103-220000.png")
        self.assertIn("file_modified_at", last["fields"])

        # 同じ内容は保存せず、既存のキャプチャを返す
        status, _, response_body = self.request(
            "POST",
            "/api/captures",
            body=body,
            headers={"Content-Type": content_type},
        )
        self.assertEqual(status, 201)
        self.assertEqual(json.loads(response_body)["id"], uploaded["id"])

    def test_capture_upload_validation(self) -> None:
        self.reset()
        image = captures_mock.build_capture_png(5)
        body, content_type = self.multipart_capture_body("invalid.txt", image)
        status, _, _ = self.request(
            "POST", "/api/captures", body=body,
            headers={"Content-Type": content_type},
        )
        self.assertEqual(status, 422)

        body, content_type = self.multipart_capture_body("Capture.png", b"not an image")
        status, _, _ = self.request(
            "POST", "/api/captures", body=body,
            headers={"Content-Type": content_type},
        )
        self.assertEqual(status, 422)

        body, content_type = self.multipart_capture_body("../Capture.png", image)
        status, _, _ = self.request(
            "POST", "/api/captures", body=body,
            headers={"Content-Type": content_type},
        )
        self.assertEqual(status, 422)


    # -- キャプチャの EXIF ---------------------------------------------------

    def build_exif_jpeg(
        self,
        metadata: dict,
        datetime_text: str = "2026:11:04 00:36:57",
    ) -> bytes:
        """ミニマムな JPEG に、手で組み立てた EXIF (XPComment + DateTimeOriginal) を付ける。"""
        comment = (json.dumps(metadata, ensure_ascii=False) + "\x00").encode("utf-16-le")
        datetime_bytes = (datetime_text + "\x00").encode("ascii")

        ifd0_offset = 8
        ifd0_size = 2 + 3 * 12 + 4
        exif_offset = ifd0_offset + ifd0_size
        exif_size = 2 + 12 + 4
        datetime_offset = exif_offset + exif_size
        comment_offset = datetime_offset + len(datetime_bytes)
        digitized_offset = comment_offset + len(comment)

        ifd0_entries = (
            struct.pack("<HHI", 306, 2, len(datetime_bytes))
            + struct.pack("<I", datetime_offset)
            + struct.pack("<HHI", 34665, 4, 1)
            + struct.pack("<I", exif_offset)
            + struct.pack("<HHI", 40092, 1, len(comment))
            + struct.pack("<I", comment_offset)
        )
        ifd0 = struct.pack("<H", 3) + ifd0_entries + struct.pack("<I", 0)
        exif_entries = (
            struct.pack("<HHI", 36867, 2, len(datetime_bytes))
            + struct.pack("<I", digitized_offset)
        )
        exif_ifd = struct.pack("<H", 1) + exif_entries + struct.pack("<I", 0)

        tiff = (
            b"II"
            + struct.pack("<H", 42)
            + struct.pack("<I", ifd0_offset)
            + ifd0
            + exif_ifd
            + datetime_bytes
            + comment
            + datetime_bytes
        )
        payload = b"Exif\x00\x00" + tiff
        app1 = b"\xff\xe1" + struct.pack(">H", len(payload) + 2) + payload
        sos = b"\xff\xda\x00\x08\x01\x01\x00\x00\x3f\x00"
        return b"\xff\xd8" + app1 + sos + b"\x12\x34\x56\x78" + b"\xff\xd9"

    def capture_exif_metadata(self, event_id: int = 10001) -> dict:
        return {
            "captured_at": "2026-11-04T00:36:57+09:00",
            "captured_playback_position": 2217.0,
            "network_id": 32736,
            "service_id": 1024,
            "event_id": event_id,
            "title": "ニュース7",
            "description": "今日のニュース",
            "start_time": "2026-11-03T23:40:00+09:00",
            "end_time": None,
            "duration": None,
            "caption_text": "今日のニュースです",
            "is_caption_composited": True,
            "is_comment_composited": False,
        }

    def test_capture_upload_reads_exif_metadata(self) -> None:
        self.reset()
        image = self.build_exif_jpeg(self.capture_exif_metadata())
        body, content_type = self.multipart_capture_body("Capture_20261104-003657.jpg", image)
        status, _, response_body = self.request(
            "POST",
            "/api/captures",
            body=body,
            headers={"Content-Type": content_type},
        )
        self.assertEqual(status, 201)
        uploaded = json.loads(response_body)
        self.assertEqual(uploaded["metadata_status"], "Parsed")
        self.assertEqual(uploaded["capture_program_id"], 1)
        self.assertEqual(uploaded["caption_text"], "今日のニュースです")
        self.assertAlmostEqual(uploaded["playback_position"], 2217.0)
        self.assertTrue(uploaded["is_caption_composited"])
        self.assertFalse(uploaded["is_comment_composited"])
        # EXIF の撮影日時がそのままキャプチャ日時になる
        self.assertTrue(uploaded["captured_at"].startswith("2026-11-04T00:36:57"))
        self.assertEqual(uploaded["broadcast_at"], "2026-11-03T20:00:00+09:00")

        # 番組が引ける
        status, _, detail = self.get_json(f"/api/captures/{uploaded['id']}")
        self.assertEqual(status, 200)
        self.assertEqual(detail["program"]["title"], "ニュース7")

        stats = self.stats()
        self.assertGreaterEqual(len(stats["capture_uploads"]), 1)
        last = stats["capture_uploads"][-1]
        self.assertEqual(last["filename"], "Capture_20261104-003657.jpg")
        self.assertEqual(last["date_time_original"], "2026:11:04 00:36:57")
        self.assertEqual(last["metadata"]["title"], "ニュース7")
        self.assertEqual(last["metadata"]["network_id"], 32736)
        self.assertIsNone(last["metadata"]["end_time"])
        self.assertIsNone(stats["last_capture_upload"]["metadata"]["duration"])

    def test_capture_upload_without_matching_program_keeps_metadata(self) -> None:
        self.reset()
        image = self.build_exif_jpeg(self.capture_exif_metadata(event_id=9999))
        body, content_type = self.multipart_capture_body("Capture.jpg", image)
        status, _, response_body = self.request(
            "POST",
            "/api/captures",
            body=body,
            headers={"Content-Type": content_type},
        )
        self.assertEqual(status, 201)
        uploaded = json.loads(response_body)
        self.assertEqual(uploaded["metadata_status"], "Parsed")
        self.assertIsNone(uploaded["capture_program_id"])
        self.assertIsNone(uploaded["broadcast_at"])
        stats = self.stats()
        self.assertEqual(stats["last_capture_upload"]["metadata"]["event_id"], 9999)

    def test_capture_upload_without_exif_is_no_metadata(self) -> None:
        self.reset()
        image = captures_mock.build_capture_png(31)
        body, content_type = self.multipart_capture_body("Capture.png", image)
        status, _, response_body = self.request(
            "POST",
            "/api/captures",
            body=body,
            headers={"Content-Type": content_type},
        )
        self.assertEqual(status, 201)
        uploaded = json.loads(response_body)
        self.assertEqual(uploaded["metadata_status"], "NoMetadata")
        stats = self.stats()
        self.assertIsNone(stats["last_capture_upload"]["metadata"])
        self.assertIsNone(stats["last_capture_upload"]["date_time_original"])

    def test_capture_favorite_counters(self) -> None:
        self.reset()
        status, _, _ = self.request(
            "POST",
            "/api/captures/favorites",
            body=json.dumps({"capture_ids": [1, 2]}).encode(),
            headers={**self.capture_auth(), "Content-Type": "application/json"},
        )
        self.assertEqual(status, 204)
        self.assertEqual(self.stats()["capture_favorite_add_count"], 2)
        status, _, _ = self.request(
            "DELETE",
            "/api/captures/favorites",
            body=json.dumps({"capture_ids": [1]}).encode(),
            headers={**self.capture_auth(), "Content-Type": "application/json"},
        )
        self.assertEqual(status, 204)
        self.assertEqual(self.stats()["capture_favorite_remove_count"], 1)

    def test_captures_library_toggle_matches_v0141(self) -> None:
        self.reset()
        try:
            status, _, config = self.request(
                "POST",
                "/__mock/config",
                body=json.dumps({"captures_library": False}).encode(),
                headers={"Content-Type": "application/json"},
            )
            self.assertEqual(status, 200)
            self.assertEqual(json.loads(config)["captures_library"], False)

            for path in (
                "/api/captures",
                "/api/captures/sections",
                "/api/captures/channels",
                "/api/captures/programs",
                "/api/captures/tags",
                "/api/captures/1",
                "/api/captures/1/image?hash=" + "0" * 64,
            ):
                status, _, _ = self.request("GET", path)
                self.assertEqual(status, 404, path)

            image = captures_mock.build_capture_png(9)
            body, content_type = self.multipart_capture_body("Capture.png", image)
            status, _, response_body = self.request(
                "POST", "/api/captures", body=body,
                headers={"Content-Type": content_type},
            )
            self.assertEqual(status, 204)
            self.assertEqual(response_body, b"")
            stats = self.stats()
            self.assertFalse(stats["captures_library"])
            self.assertGreaterEqual(stats["capture_upload_count"], 1)
        finally:
            self.reset()
        status, _, _ = self.get_json("/api/captures")
        self.assertEqual(status, 200)
        self.assertTrue(self.stats()["captures_library"])




# ---------------------------------------------------------------------------
# Twitter / Bluesky / アカウント紐付け
# ---------------------------------------------------------------------------

TWITTER_HEADERS = {"Authorization": "Bearer mock-access-token"}


class TwitterMockTestCase(unittest.TestCase):
    """Twitter / Bluesky 連携とアカウント紐付けのモック API。"""

    @classmethod
    def setUpClass(cls) -> None:
        cls.server = mock_server.create_server("127.0.0.1", 0)
        cls.host, cls.port = cls.server.server_address[:2]
        cls.thread = threading.Thread(target=cls.server.serve_forever, daemon=True)
        cls.thread.start()

    @classmethod
    def tearDownClass(cls) -> None:
        cls.server.shutdown()
        cls.server.server_close()
        cls.thread.join(timeout=5)

    def setUp(self) -> None:
        self.reset()

    # -- helpers -----------------------------------------------------------

    def request(self, method: str, path: str, body: bytes | None = None,
                headers: dict | None = None):
        conn = http.client.HTTPConnection(self.host, self.port, timeout=10)
        try:
            hdrs = {"Accept": "*/*"}
            if headers:
                hdrs.update(headers)
            conn.request(method, path, body=body, headers=hdrs)
            response = conn.getresponse()
            data = response.read()
            return response.status, dict(response.getheaders()), data
        finally:
            conn.close()

    def get_json(self, path: str, headers: dict | None = None):
        status, response_headers, data = self.request("GET", path, headers=headers)
        return status, response_headers, json.loads(data.decode("utf-8"))

    def send_json(self, method: str, path: str, payload, headers=None):
        status, response_headers, data = self.request(
            method, path,
            body=json.dumps(payload).encode("utf-8"),
            headers={"Content-Type": "application/json", **(headers or {})},
        )
        payload_out = json.loads(data.decode("utf-8")) if data else None
        return status, response_headers, payload_out

    def stats(self) -> dict:
        status, _, payload = self.get_json("/__mock/stats")
        self.assertEqual(status, 200)
        return payload

    def reset(self) -> None:
        status, _, _ = self.request("POST", "/__mock/reset")
        self.assertEqual(status, 200)

    def multipart(self, fields: dict[str, str],
                  images: list[tuple[str, bytes]]) -> tuple[bytes, str]:
        boundary = "MOCKTWITTERBOUNDARY"
        parts: list[bytes] = []
        for name, value in fields.items():
            parts.extend([
                b"--" + boundary.encode() + b"\r\n",
                f'Content-Disposition: form-data; name="{name}"\r\n\r\n'.encode(),
                value.encode("utf-8"),
                b"\r\n",
            ])
        for filename, data in images:
            parts.extend([
                b"--" + boundary.encode() + b"\r\n",
                (
                    'Content-Disposition: form-data; name="images"; filename="'
                    + filename
                    + '"\r\n'
                ).encode(),
                b"Content-Type: image/jpeg\r\n",
                b"\r\n",
                data,
                b"\r\n",
            ])
        parts.append(b"--" + boundary.encode() + b"--\r\n")
        return b"".join(parts), "multipart/form-data; boundary=" + boundary

    def link_twitter(self, screen_name: str = "konomi_tv") -> None:
        status, _, _ = self.send_json(
            "POST", "/api/twitter/auth",
            {"cookies_txt": "# Netscape HTTP Cookie File\n.x.com\tTRUE\t/\tFALSE\t0\tauth_token\tx"},
            TWITTER_HEADERS,
        )
        self.assertEqual(status, 204)

    def link_bluesky(self, handle: str = "mock.bsky.social") -> None:
        status, _, _ = self.send_json(
            "POST", "/api/bluesky/auth",
            {"handle": handle, "app_password": "app-password"},
            TWITTER_HEADERS,
        )
        self.assertEqual(status, 204)

    # -- Twitter auth / accounts ------------------------------------------

    def test_twitter_auth_links_account_and_users_me_lists_it(self) -> None:
        before = self.stats()["twitter_auth_count"]
        self.link_twitter()

        status, _, user = self.get_json("/api/users/me", headers=TWITTER_HEADERS)
        self.assertEqual(status, 200)
        self.assertEqual(len(user["twitter_accounts"]), 1)
        account = user["twitter_accounts"][0]
        self.assertEqual(account["screen_name"], "konomi_tv")
        self.assertTrue(account["name"])
        self.assertTrue(account["icon_url"].startswith("http://"))
        self.assertIn("created_at", account)
        self.assertIn("updated_at", account)
        self.assertEqual(user["bluesky_accounts"], [])
        self.assertEqual(user["account_links"], [])
        self.assertEqual(self.stats()["twitter_auth_count"], before + 1)

        # Linking the same screen name again updates instead of duplicating.
        self.link_twitter()
        status, _, user = self.get_json("/api/users/me", headers=TWITTER_HEADERS)
        self.assertEqual(len(user["twitter_accounts"]), 1)

    def test_twitter_auth_rejects_bad_cookies(self) -> None:
        status, _, payload = self.send_json(
            "POST", "/api/twitter/auth",
            {"cookies_txt": "not a netscape cookie file"},
            TWITTER_HEADERS,
        )
        self.assertEqual(status, 422)
        self.assertIn("cookies", payload["detail"])

    def test_twitter_auth_requires_login(self) -> None:
        status, _, _ = self.send_json(
            "POST", "/api/twitter/auth", {"cookies_txt": "x.com"}
        )
        self.assertEqual(status, 401)

    def test_twitter_endpoints_require_auth(self) -> None:
        self.link_twitter()
        for method, path in (
            ("GET", "/api/twitter/accounts/konomi_tv/timeline"),
            ("GET", "/api/twitter/accounts/konomi_tv/search?query=%23nhk"),
            ("POST", "/api/twitter/accounts/konomi_tv/keep-alive"),
            ("PUT", "/api/twitter/accounts/konomi_tv/tweets/1/retweet"),
            ("DELETE", "/api/twitter/accounts/konomi_tv/tweets/1/favorite"),
            ("DELETE", "/api/twitter/accounts/konomi_tv"),
        ):
            status, _, _ = self.request(method, path)
            self.assertEqual(status, 401, path)

    def test_keep_alive_and_unlink(self) -> None:
        self.link_twitter()
        before = self.stats()["twitter_keep_alive_count"]
        status, _, body = self.request(
            "POST", "/api/twitter/accounts/konomi_tv/keep-alive",
            headers=TWITTER_HEADERS,
        )
        self.assertEqual(status, 204)
        self.assertEqual(body, b"")
        self.assertEqual(self.stats()["twitter_keep_alive_count"], before + 1)

        status, _, body = self.request(
            "DELETE", "/api/twitter/accounts/konomi_tv", headers=TWITTER_HEADERS
        )
        self.assertEqual(status, 204)
        status, _, user = self.get_json("/api/users/me", headers=TWITTER_HEADERS)
        self.assertEqual(user["twitter_accounts"], [])
        self.assertEqual(self.stats()["twitter_account_delete_count"], 1)

        # The account is gone: the timeline answers 422 like the real server.
        status, _, payload = self.get_json(
            "/api/twitter/accounts/konomi_tv/timeline", headers=TWITTER_HEADERS
        )
        self.assertEqual(status, 422)
        self.assertIn("screen_name", payload["detail"])

    # -- Tweets ------------------------------------------------------------

    def test_post_records_text_and_images(self) -> None:
        self.link_twitter()
        body, content_type = self.multipart(
            {"tweet": "テスト投稿 #nhk"},
            [("capture.jpg", b"\xff\xd8\xff" + b"a" * 100)],
        )
        status, _, payload = self.request(
            "POST", "/api/twitter/accounts/konomi_tv/tweets",
            body=body,
            headers={"Content-Type": content_type, **TWITTER_HEADERS},
        )
        self.assertEqual(status, 200)
        result = json.loads(payload.decode("utf-8"))
        self.assertTrue(result["is_success"])
        self.assertEqual(result["tweet_id"], "1001")
        self.assertIn("tweet_url", result)
        self.assertIsNone(result["post_uri"])

        posted = self.stats()["twitter_posted_tweets"]
        self.assertEqual(len(posted), 1)
        self.assertEqual(posted[0]["text"], "テスト投稿 #nhk")
        self.assertEqual(posted[0]["image_count"], 1)
        self.assertEqual(posted[0]["image_sizes"], [103])
        self.assertIsNone(posted[0]["in_reply_to_status_id"])

    def test_post_rejects_more_than_four_images(self) -> None:
        self.link_twitter()
        images = [(f"capture{index}.jpg", b"\xff\xd8\xff") for index in range(5)]
        body, content_type = self.multipart({"tweet": "画像 5 枚"}, images)
        status, _, payload = self.request(
            "POST", "/api/twitter/accounts/konomi_tv/tweets",
            body=body,
            headers={"Content-Type": content_type, **TWITTER_HEADERS},
        )
        self.assertEqual(status, 422)
        self.assertIn("4", json.loads(payload.decode("utf-8"))["detail"])

    def test_post_forwards_reply_target(self) -> None:
        self.link_twitter()
        body, content_type = self.multipart(
            {"tweet": "リプライ", "in_reply_to_status_id": "999"},
            [],
        )
        status, _, _ = self.request(
            "POST", "/api/twitter/accounts/konomi_tv/tweets",
            body=body,
            headers={"Content-Type": content_type, **TWITTER_HEADERS},
        )
        self.assertEqual(status, 200)
        self.assertEqual(
            self.stats()["twitter_posted_tweets"][-1]["in_reply_to_status_id"],
            "999",
        )

    def test_retweet_and_favorite_toggles_are_counted(self) -> None:
        self.link_twitter()
        for method, path in (
            ("PUT", "/api/twitter/accounts/konomi_tv/tweets/101/retweet"),
            ("DELETE", "/api/twitter/accounts/konomi_tv/tweets/101/retweet"),
            ("PUT", "/api/twitter/accounts/konomi_tv/tweets/102/favorite"),
            ("DELETE", "/api/twitter/accounts/konomi_tv/tweets/102/favorite"),
        ):
            status, _, payload = self.request(method, path, headers=TWITTER_HEADERS)
            self.assertEqual(status, 200, path)
            self.assertTrue(json.loads(payload.decode("utf-8"))["is_success"])

        stats = self.stats()
        self.assertEqual(stats["twitter_retweet_count"], 1)
        self.assertEqual(stats["twitter_unretweet_count"], 1)
        self.assertEqual(stats["twitter_favorite_count"], 1)
        self.assertEqual(stats["twitter_unfavorite_count"], 1)
        self.assertEqual(
            [event["action"] for event in stats["twitter_reaction_events"]],
            ["retweet", "unretweet", "favorite", "unfavorite"],
        )

    def test_timeline_paginates_and_search_filters(self) -> None:
        self.link_twitter()
        status, _, first = self.get_json(
            "/api/twitter/accounts/konomi_tv/timeline", headers=TWITTER_HEADERS
        )
        self.assertEqual(status, 200)
        self.assertTrue(first["is_success"])
        self.assertEqual(len(first["tweets"]), 2)
        self.assertTrue(first["is_cursor_consumed"])
        older = [c for c in first["load_more_cursors"] if c["cursor_type"] == "Older"]
        self.assertEqual(len(older), 1)
        tweet = first["tweets"][0]
        for field in ("source", "id", "created_at", "user", "text",
                      "image_urls", "retweet_count", "retweeted",
                      "favorite_count", "favorited"):
            self.assertIn(field, tweet)
        self.assertTrue(tweet["user"]["icon_url"].startswith("http://"))

        status, _, second = self.get_json(
            "/api/twitter/accounts/konomi_tv/timeline?cursor_id="
            + older[0]["cursor_id"],
            headers=TWITTER_HEADERS,
        )
        self.assertEqual(status, 200)
        self.assertEqual(len(second["tweets"]), 2)
        self.assertNotEqual(
            [item["id"] for item in first["tweets"]],
            [item["id"] for item in second["tweets"]],
        )
        self.assertEqual(second["load_more_cursors"], [])

        # The repost fixture carries the original tweet.
        all_tweets = first["tweets"] + second["tweets"]
        reposts = [item for item in all_tweets if item["retweeted_tweet"]]
        self.assertEqual(len(reposts), 1)
        self.assertTrue(reposts[0]["retweeted_tweet"]["id"])

        status, _, search = self.get_json(
            "/api/twitter/accounts/konomi_tv/search?query=" + quote("#nhk"),
            headers=TWITTER_HEADERS,
        )
        self.assertEqual(status, 200)
        self.assertGreaterEqual(len(search["tweets"]), 1)
        for item in search["tweets"]:
            self.assertIn("nhk", item["text"].lower())

        status, _, empty = self.get_json(
            "/api/twitter/accounts/konomi_tv/search?query=zzz-no-match",
            headers=TWITTER_HEADERS,
        )
        self.assertEqual(status, 200)
        self.assertEqual(empty["tweets"], [])

    def test_tweet_images_are_served(self) -> None:
        status, headers, body = self.request(
            "GET", "/__mock/twitter/image/1.png"
        )
        self.assertEqual(status, 200)
        self.assertIn("image/png", headers.get("Content-Type", ""))
        self.assertTrue(body.startswith(b"\x89PNG\r\n\x1a\n"))

        status, headers, body = self.request("GET", "/__mock/twitter/icon/2.png")
        self.assertEqual(status, 200)
        self.assertTrue(body.startswith(b"\x89PNG\r\n\x1a\n"))

        status, _, _ = self.request("GET", "/__mock/twitter/unknown/1.png")
        self.assertEqual(status, 404)

    # -- Bluesky -----------------------------------------------------------

    def test_bluesky_auth_post_and_reactions(self) -> None:
        self.link_bluesky()
        status, _, user = self.get_json("/api/users/me", headers=TWITTER_HEADERS)
        self.assertEqual(status, 200)
        self.assertEqual(len(user["bluesky_accounts"]), 1)
        account = user["bluesky_accounts"][0]
        self.assertEqual(account["handle"], "mock.bsky.social")
        self.assertTrue(account["did"].startswith("did:plc:"))
        self.assertEqual(self.stats()["bluesky_auth_count"], 1)

        # An invalid login is rejected.
        status, _, _ = self.send_json(
            "POST", "/api/bluesky/auth", {"handle": "", "app_password": ""},
            TWITTER_HEADERS,
        )
        self.assertEqual(status, 422)

        body, content_type = self.multipart(
            {
                "post": "Bluesky の投稿 #nhk",
                "reply_root_uri": "at://did:plc:x/app.bsky.feed.post/1",
                "reply_root_cid": "cid-root",
                "reply_parent_uri": "at://did:plc:x/app.bsky.feed.post/2",
                "reply_parent_cid": "cid-parent",
            },
            [("capture.jpg", b"\xff\xd8\xff")],
        )
        status, _, payload = self.request(
            "POST", "/api/bluesky/accounts/mock.bsky.social/posts",
            body=body,
            headers={"Content-Type": content_type, **TWITTER_HEADERS},
        )
        self.assertEqual(status, 200)
        result = json.loads(payload.decode("utf-8"))
        self.assertTrue(result["is_success"])
        self.assertTrue(result["post_uri"].startswith("at://"))
        self.assertTrue(result["post_cid"])

        posted = self.stats()["bluesky_posted_posts"]
        self.assertEqual(len(posted), 1)
        self.assertEqual(posted[0]["text"], "Bluesky の投稿 #nhk")
        self.assertEqual(posted[0]["image_count"], 1)
        self.assertEqual(
            posted[0]["reply_parent_uri"],
            "at://did:plc:x/app.bsky.feed.post/2",
        )

        # Incomplete reply references are rejected (the StrongRef needs all four).
        body, content_type = self.multipart(
            {"post": "リプライ", "reply_root_uri": "at://root"}, []
        )
        status, _, _ = self.request(
            "POST", "/api/bluesky/accounts/mock.bsky.social/posts",
            body=body,
            headers={"Content-Type": content_type, **TWITTER_HEADERS},
        )
        self.assertEqual(status, 422)

    def test_bluesky_repost_and_like_use_the_at_uri(self) -> None:
        self.link_bluesky()
        post_id = quote("at://did:plc:mock/app.bsky.feed.post/abc", safe="")
        for method, action in (
            ("PUT", "repost"), ("DELETE", "repost"),
            ("PUT", "like"), ("DELETE", "like"),
        ):
            status, _, payload = self.request(
                method,
                f"/api/bluesky/accounts/mock.bsky.social/posts/{post_id}/{action}",
                headers=TWITTER_HEADERS,
            )
            self.assertEqual(status, 200, f"{method} {action}")
            self.assertTrue(json.loads(payload.decode("utf-8"))["is_success"])

        stats = self.stats()
        self.assertEqual(stats["bluesky_repost_count"], 1)
        self.assertEqual(stats["bluesky_unrepost_count"], 1)
        self.assertEqual(stats["bluesky_like_count"], 1)
        self.assertEqual(stats["bluesky_unlike_count"], 1)
        self.assertEqual(
            stats["bluesky_reaction_events"][0]["post_id"],
            "at://did:plc:mock/app.bsky.feed.post/abc",
        )

    def test_bluesky_timeline_and_search(self) -> None:
        self.link_bluesky()
        status, _, timeline = self.get_json(
            "/api/bluesky/accounts/mock.bsky.social/timeline",
            headers=TWITTER_HEADERS,
        )
        self.assertEqual(status, 200)
        self.assertEqual(len(timeline["tweets"]), 2)
        self.assertEqual(timeline["tweets"][0]["source"], "Bluesky")
        self.assertTrue(timeline["tweets"][0]["id"].startswith("at://"))

        status, _, search = self.get_json(
            "/api/bluesky/accounts/mock.bsky.social/search?query=" + quote("#nhk"),
            headers=TWITTER_HEADERS,
        )
        self.assertEqual(status, 200)
        self.assertGreaterEqual(len(search["tweets"]), 1)

    # -- Account links -----------------------------------------------------

    def test_account_links_create_and_delete(self) -> None:
        self.link_twitter()
        self.link_bluesky()
        status, _, user = self.get_json("/api/users/me", headers=TWITTER_HEADERS)
        twitter_id = user["twitter_accounts"][0]["id"]
        bluesky_id = user["bluesky_accounts"][0]["id"]

        status, _, link = self.send_json(
            "POST", "/api/users/me/account-links",
            {"twitter_account_id": twitter_id, "bluesky_account_id": bluesky_id},
            TWITTER_HEADERS,
        )
        self.assertEqual(status, 201)
        self.assertTrue(link["id"])
        self.assertEqual(link["twitter_account"]["screen_name"], "konomi_tv")
        self.assertEqual(link["bluesky_account"]["handle"], "mock.bsky.social")

        status, _, user = self.get_json("/api/users/me", headers=TWITTER_HEADERS)
        self.assertEqual(len(user["account_links"]), 1)

        # A second link for the same accounts is rejected.
        status, _, payload = self.send_json(
            "POST", "/api/users/me/account-links",
            {"twitter_account_id": twitter_id, "bluesky_account_id": bluesky_id},
            TWITTER_HEADERS,
        )
        self.assertEqual(status, 422)
        self.assertIn("already linked", payload["detail"])

        status, _, _ = self.request(
            "DELETE", f"/api/users/me/account-links/{link['id']}",
            headers=TWITTER_HEADERS,
        )
        self.assertEqual(status, 204)
        status, _, user = self.get_json("/api/users/me", headers=TWITTER_HEADERS)
        self.assertEqual(user["account_links"], [])
        # The individual accounts stay linked.
        self.assertEqual(len(user["twitter_accounts"]), 1)
        self.assertEqual(len(user["bluesky_accounts"]), 1)

        status, _, _ = self.request(
            "DELETE", f"/api/users/me/account-links/{link['id']}",
            headers=TWITTER_HEADERS,
        )
        self.assertEqual(status, 422)

        stats = self.stats()
        self.assertEqual(stats["account_link_create_count"], 1)
        self.assertEqual(stats["account_link_delete_count"], 1)

    def test_unlinking_a_bluesky_account_removes_its_links(self) -> None:
        self.link_twitter()
        self.link_bluesky()
        status, _, user = self.get_json("/api/users/me", headers=TWITTER_HEADERS)
        twitter_id = user["twitter_accounts"][0]["id"]
        bluesky_id = user["bluesky_accounts"][0]["id"]
        self.send_json(
            "POST", "/api/users/me/account-links",
            {"twitter_account_id": twitter_id, "bluesky_account_id": bluesky_id},
            TWITTER_HEADERS,
        )
        status, _, _ = self.request(
            "DELETE", "/api/bluesky/accounts/mock.bsky.social",
            headers=TWITTER_HEADERS,
        )
        self.assertEqual(status, 204)
        status, _, user = self.get_json("/api/users/me", headers=TWITTER_HEADERS)
        self.assertEqual(user["account_links"], [])
        self.assertEqual(user["bluesky_accounts"], [])

    def test_reset_clears_twitter_state(self) -> None:
        self.link_twitter()
        self.link_bluesky()
        self.reset()
        status, _, user = self.get_json("/api/users/me", headers=TWITTER_HEADERS)
        self.assertEqual(user["twitter_accounts"], [])
        self.assertEqual(user["bluesky_accounts"], [])
        self.assertEqual(user["account_links"], [])
        self.assertEqual(self.stats()["twitter_posted_tweets"], [])

class ReservationMockTestCase(unittest.TestCase):
    """EDCB recording reservations, keyword conditions and presets."""

    @classmethod
    def setUpClass(cls) -> None:
        cls.server = mock_server.create_server("127.0.0.1", 0)
        cls.host, cls.port = cls.server.server_address[:2]
        cls.thread = threading.Thread(target=cls.server.serve_forever, daemon=True)
        cls.thread.start()

    @classmethod
    def tearDownClass(cls) -> None:
        cls.server.shutdown()
        cls.server.server_close()
        cls.thread.join(timeout=5)

    # -- helpers -----------------------------------------------------------

    def request(self, method: str, path: str, body: bytes | None = None,
                headers: dict | None = None):
        conn = http.client.HTTPConnection(self.host, self.port, timeout=10)
        try:
            hdrs = {"Accept": "*/*"}
            if headers:
                hdrs.update(headers)
            conn.request(method, path, body=body, headers=hdrs)
            response = conn.getresponse()
            data = response.read()
            return response.status, dict(response.getheaders()), data
        finally:
            conn.close()

    def get_json(self, path: str):
        status, _, data = self.request("GET", path)
        self.assertEqual(status, 200)
        return json.loads(data.decode("utf-8"))

    def send_json(self, method: str, path: str, payload):
        status, _, data = self.request(
            method, path,
            body=json.dumps(payload).encode("utf-8"),
            headers={"Content-Type": "application/json"},
        )
        decoded = json.loads(data.decode("utf-8")) if data else None
        return status, decoded

    def reset(self) -> None:
        status, _, _ = self.request("POST", "/__mock/reset")
        self.assertEqual(status, 200)

    def stats(self) -> dict:
        return self.get_json("/__mock/stats")

    def timetable_programs(self) -> list[dict]:
        now = mock_server.now_jst()
        day_start = now.replace(hour=0, minute=0, second=0, microsecond=0)
        start = mock_server.isoformat(day_start)
        end = mock_server.isoformat(day_start + timedelta(days=1))
        payload = self.get_json(
            "/api/programs/timetable?start_time=" + quote(start)
            + "&end_time=" + quote(end)
        )
        return [program for entry in payload["channels"] for program in entry["programs"]]

    # -- tests -------------------------------------------------------------

    def test_reservations_fixture_shape(self) -> None:
        self.reset()
        payload = self.get_json("/api/recording/reservations")
        self.assertGreaterEqual(payload["total"], 4)
        self.assertEqual(payload["total"], len(payload["reservations"]))

        for field in (
            "id", "channel", "program", "is_recording_in_progress",
            "recording_availability", "comment", "scheduled_recording_file_name",
            "estimated_recording_file_size", "record_settings",
        ):
            self.assertIn(field, payload["reservations"][0])

        settings = payload["reservations"][0]["record_settings"]
        for key in (
            "is_enabled", "priority", "recording_folders", "recording_start_margin",
            "recording_end_margin", "recording_mode", "caption_recording_mode",
            "data_broadcasting_recording_mode", "post_recording_mode",
            "post_recording_bat_file_path", "is_event_relay_follow_enabled",
            "is_exact_recording_enabled", "is_oneseg_separate_output_enabled",
            "is_sequential_recording_in_single_file_enabled", "forced_tuner_id",
        ):
            self.assertIn(key, settings)

        # Sorted by program start time, like the server's ReservationsAPI.
        starts = [item["program"]["start_time"] for item in payload["reservations"]]
        self.assertEqual(starts, sorted(starts))

        # The fixture covers the groups the app shows: recording now, (partly)
        # unavailable tuners and a disabled reservation.
        self.assertTrue(any(item["is_recording_in_progress"] for item in payload["reservations"]))
        self.assertTrue(any(
            item["recording_availability"] == "Partial"
            for item in payload["reservations"]
        ))
        self.assertTrue(any(
            item["record_settings"]["is_enabled"] is False
            for item in payload["reservations"]
        ))

        for item in payload["reservations"]:
            self.assertTrue(item["program"]["id"])
            self.assertTrue(item["channel"]["id"])

    def test_reservation_detail(self) -> None:
        self.reset()
        payload = self.get_json("/api/recording/reservations")
        wanted = payload["reservations"][0]
        detail = self.get_json("/api/recording/reservations/" + str(wanted["id"]))
        self.assertEqual(detail["id"], wanted["id"])
        self.assertEqual(detail["program"]["id"], wanted["program"]["id"])

        status, detail = self.send_json(
            "GET", "/api/recording/reservations/9999", {}
        )
        self.assertEqual(status, 422)
        self.assertEqual(detail["detail"], "Specified reservation_id was not found")

    def test_timetable_programs_expose_their_reservation(self) -> None:
        self.reset()
        reservations = self.get_json("/api/recording/reservations")["reservations"]
        reserved_ids = {item["program"]["id"]: item for item in reservations}

        marked = {
            program["id"]: program["reservation"]
            for program in self.timetable_programs()
            if program.get("reservation") is not None
        }
        self.assertTrue(marked, "予約済みの番組に reservation が付かない")
        for program_id, summary in marked.items():
            self.assertIn(program_id, reserved_ids)
            self.assertEqual(summary["id"], reserved_ids[program_id]["id"])
            self.assertIn(summary["status"], ("Reserved", "Recording", "Disabled"))
            self.assertIn(
                summary["recording_availability"], ("Full", "Partial", "Unavailable")
            )

        disabled = [
            summary for summary in marked.values() if summary["status"] == "Disabled"
        ]
        self.assertTrue(disabled, "無効な予約が Disabled にならない")

        # A program without a reservation keeps the key with null.
        unmarked = [
            program for program in self.timetable_programs()
            if program["id"] not in reserved_ids
        ]
        self.assertTrue(unmarked)
        self.assertIsNone(unmarked[0]["reservation"])

    def test_add_change_and_delete_reservation(self) -> None:
        self.reset()
        reserved = {item["program"]["id"] for item in
                    self.get_json("/api/recording/reservations")["reservations"]}
        target = next(
            program for program in self.timetable_programs()
            if program["id"] not in reserved
        )

        settings = {
            "is_enabled": True,
            "priority": 5,
            "recording_folders": [],
            "recording_start_margin": None,
            "recording_end_margin": None,
            "recording_mode": "SpecifiedService",
            "caption_recording_mode": "Default",
            "data_broadcasting_recording_mode": "Default",
            "post_recording_mode": "Default",
            "post_recording_bat_file_path": None,
            "is_event_relay_follow_enabled": True,
            "is_exact_recording_enabled": False,
            "is_oneseg_separate_output_enabled": False,
            "is_sequential_recording_in_single_file_enabled": False,
            "forced_tuner_id": None,
        }

        status, body = self.send_json(
            "POST", "/api/recording/reservations",
            {"program_id": target["id"], "record_settings": settings, "program": None},
        )
        self.assertEqual(status, 201)
        self.assertIn("id", body)

        reservations = self.get_json("/api/recording/reservations")["reservations"]
        added = next(item for item in reservations if item["program"]["id"] == target["id"])
        self.assertEqual(added["record_settings"]["priority"], 5)
        self.assertFalse(added["is_recording_in_progress"])

        stats = self.stats()
        self.assertEqual(stats["reservation_add_count"], 1)
        self.assertEqual(stats["reservation_added_program_ids"], [target["id"]])

        # The same program cannot be reserved twice.
        status, body = self.send_json(
            "POST", "/api/recording/reservations",
            {"program_id": target["id"], "record_settings": settings},
        )
        self.assertEqual(status, 422)
        self.assertEqual(body["detail"], "The same program_id is already reserved")

        # Change the settings (what the detail screen saves).
        new_settings = dict(settings)
        new_settings["is_enabled"] = False
        status, updated = self.send_json(
            "PUT", "/api/recording/reservations/" + str(added["id"]),
            {"record_settings": new_settings},
        )
        self.assertEqual(status, 200)
        self.assertFalse(updated["record_settings"]["is_enabled"])

        stats = self.stats()
        self.assertEqual(stats["reservation_update_count"], 1)
        self.assertEqual(stats["reservation_updated_ids"], [added["id"]])
        self.assertFalse(stats["last_reservation_settings"]["is_enabled"])

        # The timetable now reports the reservation as disabled.
        summary = next(
            program["reservation"] for program in self.timetable_programs()
            if program["id"] == target["id"]
        )
        self.assertEqual(summary["status"], "Disabled")

        status, _, data = self.request(
            "DELETE", "/api/recording/reservations/" + str(added["id"])
        )
        self.assertEqual(status, 204)
        self.assertEqual(data, b"")
        stats = self.stats()
        self.assertEqual(stats["reservation_delete_count"], 1)
        self.assertEqual(stats["reservation_deleted_ids"], [added["id"]])

        remaining = {
            item["program"]["id"]
            for item in self.get_json("/api/recording/reservations")["reservations"]
        }
        self.assertNotIn(target["id"], remaining)

        status, _ = self.send_json(
            "DELETE", "/api/recording/reservations/" + str(added["id"]), {}
        )
        self.assertEqual(status, 422)

    def test_add_reservation_accepts_program_payload(self) -> None:
        self.reset()
        payload = {
            "program_id": "NID32736-SID1024-EID65535",
            "record_settings": {"is_enabled": True, "priority": 3},
            "program": {
                "id": "NID32736-SID1024-EID65535",
                "channel_id": "NID32736-SID1024",
                "network_id": 32736,
                "service_id": 1024,
                "event_id": 65535,
                "title": "放送中の番組",
                "start_time": mock_server.isoformat(mock_server.now_jst()),
                "duration": 1800,
            },
        }
        status, body = self.send_json("POST", "/api/recording/reservations", payload)
        self.assertEqual(status, 201, body)
        reservations = self.get_json("/api/recording/reservations")["reservations"]
        added = next(
            item for item in reservations if item["program"]["id"] == payload["program_id"]
        )
        self.assertEqual(added["program"]["title"], "放送中の番組")

    def test_add_reservation_rejects_unknown_program(self) -> None:
        self.reset()
        status, body = self.send_json(
            "POST", "/api/recording/reservations",
            {"program_id": "NID1-SID1-EID1", "record_settings": {"priority": 3}},
        )
        self.assertEqual(status, 422)
        self.assertEqual(body["detail"], "Specified program was not found")

    def test_recording_presets(self) -> None:
        self.reset()
        payload = self.get_json("/api/recording/presets")
        self.assertIn("global_defaults", payload)
        self.assertGreaterEqual(len(payload["presets"]), 2)
        self.assertEqual(payload["presets"][0]["id"], 0)
        self.assertEqual(
            set(payload["global_defaults"]),
            {
                "recording_start_margin", "recording_end_margin",
                "caption_recording_mode", "data_broadcasting_recording_mode",
                "post_recording_mode",
            },
        )
        for preset in payload["presets"]:
            self.assertIn("name", preset)
            self.assertIn("record_settings", preset)
        self.assertGreaterEqual(self.stats()["reservation_presets_fetch_count"], 1)

    def test_reservation_conditions_crud(self) -> None:
        self.reset()
        payload = self.get_json("/api/recording/conditions")
        self.assertGreaterEqual(payload["total"], 1)
        self.assertEqual(payload["total"], len(payload["reservation_conditions"]))
        condition = payload["reservation_conditions"][0]
        self.assertIn("reservation_count", condition)
        self.assertIn("keyword", condition["program_search_condition"])

        detail = self.get_json("/api/recording/conditions/" + str(condition["id"]))
        self.assertEqual(detail["id"], condition["id"])

        search = {
            "is_enabled": True,
            "keyword": "ドラマ",
            "exclude_keyword": "",
            "note": "",
            "is_title_only": False,
            "is_case_sensitive": False,
            "is_fuzzy_search_enabled": False,
            "is_regex_search_enabled": False,
            "service_ranges": None,
            "genre_ranges": None,
            "is_exclude_genre_ranges": False,
            "date_ranges": None,
            "is_exclude_date_ranges": False,
            "duration_range_min": None,
            "duration_range_max": None,
            "broadcast_type": "All",
            "duplicate_title_check_scope": "None",
            "duplicate_title_check_period_days": 6,
        }
        settings = {"is_enabled": True, "priority": 2}
        status, body = self.send_json(
            "POST", "/api/recording/conditions",
            {"program_search_condition": search, "record_settings": settings},
        )
        self.assertEqual(status, 201)
        created_id = body["id"]

        created = self.get_json("/api/recording/conditions/" + str(created_id))
        self.assertEqual(created["program_search_condition"]["keyword"], "ドラマ")
        self.assertEqual(created["reservation_count"], 0)

        stats = self.stats()
        self.assertEqual(stats["reservation_condition_add_count"], 1)
        self.assertEqual(
            stats["last_reservation_condition"]["program_search_condition"]["keyword"],
            "ドラマ",
        )

        updated_search = dict(search)
        updated_search["keyword"] = "アニメ"
        status, updated = self.send_json(
            "PUT", "/api/recording/conditions/" + str(created_id),
            {"program_search_condition": updated_search, "record_settings": settings},
        )
        self.assertEqual(status, 200)
        self.assertEqual(updated["program_search_condition"]["keyword"], "アニメ")
        self.assertEqual(self.stats()["reservation_condition_update_count"], 1)

        status, _, _ = self.request(
            "DELETE", "/api/recording/conditions/" + str(created_id)
        )
        self.assertEqual(status, 204)
        stats = self.stats()
        self.assertEqual(stats["reservation_condition_delete_count"], 1)
        self.assertEqual(stats["reservation_condition_deleted_ids"], [created_id])

        status, body = self.send_json(
            "GET", "/api/recording/conditions/" + str(created_id), {}
        )
        self.assertEqual(status, 422)
        self.assertEqual(
            body["detail"], "Specified reservation_condition_id was not found"
        )

    def test_reset_restores_reservation_fixtures(self) -> None:
        average = self.get_json("/api/recording/reservations")["total"]
        status, body = self.send_json(
            "POST", "/api/recording/reservations",
            {
                "program_id": "NID32736-SID1024-EID65535",
                "record_settings": {"is_enabled": True, "priority": 3},
                "program": {
                    "id": "NID32736-SID1024-EID65535",
                    "channel_id": "NID32736-SID1024",
                    "network_id": 32736,
                    "service_id": 1024,
                    "event_id": 65535,
                    "title": "放送中の番組",
                    "start_time": mock_server.isoformat(mock_server.now_jst()),
                    "duration": 1800,
                },
            },
        )
        self.assertEqual(status, 201, body)
        self.reset()
        self.assertEqual(self.get_json("/api/recording/reservations")["total"], average)
        self.assertEqual(self.stats()["reservation_add_count"], 0)


class AccountMaintenanceMockTestCase(unittest.TestCase):
    """Accounts, server settings and maintenance (fresh server per class)."""

    @classmethod
    def setUpClass(cls) -> None:
        cls.server = mock_server.create_server("127.0.0.1", 0)
        cls.host, cls.port = cls.server.server_address[:2]
        cls.thread = threading.Thread(target=cls.server.serve_forever, daemon=True)
        cls.thread.start()

    @classmethod
    def tearDownClass(cls) -> None:
        cls.server.shutdown()
        cls.server.server_close()
        cls.thread.join(timeout=5)

    # -- helpers -----------------------------------------------------------

    def request(self, method: str, path: str, body: bytes | None = None,
                headers: dict | None = None):
        conn = http.client.HTTPConnection(self.host, self.port, timeout=10)
        try:
            hdrs = {"Accept": "*/*"}
            if headers:
                hdrs.update(headers)
            conn.request(method, path, body=body, headers=hdrs)
            response = conn.getresponse()
            data = response.read()
            return response.status, dict(response.getheaders()), data
        finally:
            conn.close()

    def get_json(self, path: str, headers: dict | None = None):
        status, response_headers, data = self.request("GET", path, headers=headers)
        return status, response_headers, json.loads(data.decode("utf-8"))

    def send_json(self, method: str, path: str, payload, headers: dict | None = None):
        status, _, data = self.request(
            method, path,
            body=json.dumps(payload).encode("utf-8"),
            headers={"Content-Type": "application/json", **(headers or {})},
        )
        decoded = json.loads(data.decode("utf-8")) if data else None
        return status, decoded

    def reset(self) -> None:
        status, _, _ = self.request("POST", "/__mock/reset")
        self.assertEqual(status, 200)

    def stats(self) -> dict:
        status, _, payload = self.get_json("/__mock/stats")
        self.assertEqual(status, 200)
        return payload

    def login(self, username: str, password: str) -> str:
        body = f"username={quote(username)}&password={quote(password)}".encode("utf-8")
        status, _, data = self.request(
            "POST", "/api/users/token", body=body,
            headers={"Content-Type": "application/x-www-form-urlencoded"},
        )
        self.assertEqual(status, 200, data)
        return json.loads(data.decode("utf-8"))["access_token"]

    @staticmethod
    def admin_headers() -> dict:
        return {"Authorization": "Bearer " + mock_server.MOCK_ACCESS_TOKEN}

    # -- accounts ----------------------------------------------------------

    def test_register_and_login(self) -> None:
        self.reset()
        status, created = self.send_json(
            "POST", "/api/users", {"username": "newbie", "password": "pass1234"}
        )
        self.assertEqual(status, 201, created)
        self.assertEqual(created["name"], "newbie")
        self.assertFalse(created["is_admin"])
        self.assertNotIn("password", created)

        status, duplicated = self.send_json(
            "POST", "/api/users", {"username": "newbie", "password": "pass1234"}
        )
        self.assertEqual(status, 422)
        self.assertEqual(duplicated["detail"], "Specified username is duplicated")

        status, reserved = self.send_json(
            "POST", "/api/users", {"username": "me", "password": "pass1234"}
        )
        self.assertEqual(status, 422)
        self.assertEqual(reserved["detail"], "Specified username is not permitted")

        token = self.login("newbie", "pass1234")
        self.assertNotEqual(token, mock_server.MOCK_ACCESS_TOKEN)
        status, _, me = self.get_json(
            "/api/users/me", headers={"Authorization": "Bearer " + token}
        )
        self.assertEqual(status, 200)
        self.assertEqual(me["name"], "newbie")

        status, wrong = self.send_json(
            "POST", "/api/users", {"username": "newbie", "password": "pass1234"}
        )
        self.assertEqual(status, 422)

        bad_status, _, _ = self.request(
            "POST", "/api/users/token",
            body=b"username=newbie&password=wrong",
            headers={"Content-Type": "application/x-www-form-urlencoded"},
        )
        self.assertEqual(bad_status, 401)

        stats = self.stats()
        self.assertEqual(stats["user_create_count"], 1)
        self.assertEqual(stats["created_usernames"], ["newbie"])

    def test_update_current_account_and_icon(self) -> None:
        self.reset()
        headers = self.admin_headers()

        status, _ = self.send_json(
            "PUT", "/api/users/me", {"username": "renamed"}, headers=headers
        )
        self.assertEqual(status, 204)
        status, _, me = self.get_json("/api/users/me", headers=headers)
        self.assertEqual(me["name"], "renamed")
        self.assertEqual(self.stats()["user_update_count"], 1)

        # 現在のパスワードはログインで検証できる
        self.login("renamed", "test")

        status, _ = self.send_json(
            "PUT", "/api/users/me", {"password": "newpass1"}, headers=headers
        )
        self.assertEqual(status, 204)
        self.login("renamed", "newpass1")

        png = captures_mock.build_capture_png(7, width=32, height=32)
        boundary = "----mockboundary"
        body = (
            f"--{boundary}\r\n"
            'Content-Disposition: form-data; name="image"; filename="icon.png"\r\n'
            "Content-Type: image/png\r\n\r\n"
        ).encode("utf-8") + png + f"\r\n--{boundary}--\r\n".encode("utf-8")
        status, _, _ = self.request(
            "PUT", "/api/users/me/icon", body=body,
            headers={
                **headers,
                "Content-Type": "multipart/form-data; boundary=" + boundary,
            },
        )
        self.assertEqual(status, 204)

        status, response_headers, downloaded = self.request(
            "GET", "/api/users/me/icon", headers=headers
        )
        self.assertEqual(status, 200)
        self.assertIn("image/png", response_headers.get("Content-Type", ""))
        self.assertEqual(downloaded, png)

        stats = self.stats()
        self.assertEqual(stats["user_icon_update_count"], 1)
        self.assertEqual(stats["last_user_icon"]["content_type"], "image/png")
        self.assertEqual(stats["last_user_icon"]["filename"], "icon.png")

        # JPEG 以外は拒否する
        status, _, _ = self.request(
            "PUT", "/api/users/me/icon", body=b"x",
            headers={**headers, "Content-Type": "text/plain"},
        )
        self.assertEqual(status, 422)

    def test_admin_user_management(self) -> None:
        self.reset()
        headers = self.admin_headers()
        status, _, users = self.get_json("/api/users", headers=headers)
        self.assertEqual(status, 200)
        names = [user["name"] for user in users]
        self.assertIn("テストユーザー", names)
        self.assertIn("ビューア", names)
        for user in users:
            self.assertNotIn("password", user)
            self.assertIn("is_admin", user)

        viewer_token = self.login("ビューア", "viewer")
        viewer_headers = {"Authorization": "Bearer " + viewer_token}
        status, _, _ = self.request("GET", "/api/users", headers=viewer_headers)
        self.assertEqual(status, 403)

        # 最後の管理者は剥奪できない
        primary = quote("テストユーザー")
        status, error = self.send_json(
            "PUT", "/api/users/" + primary, {"is_admin": False}, headers=headers
        )
        self.assertEqual(status, 422)
        self.assertIn("no more admins", error["detail"])

        status, _ = self.send_json(
            "PUT", "/api/users/" + quote("ビューア"), {"is_admin": True}, headers=headers
        )
        self.assertEqual(status, 204)

        status, _, _ = self.request(
            "DELETE", "/api/users/" + quote("ビューア"), headers=headers
        )
        self.assertEqual(status, 204)
        status, _, users = self.get_json("/api/users", headers=headers)
        self.assertNotIn("ビューア", [user["name"] for user in users])

        # ビューアを削除したので、また管理者は1人だけになる
        status, error = self.send_json(
            "PUT", "/api/users/" + primary, {"is_admin": False}, headers=headers
        )
        self.assertEqual(status, 422)
        self.assertIn("no more admins", error["detail"])

        stats = self.stats()
        self.assertEqual(stats["user_admin_update_count"], 1)
        self.assertEqual(stats["user_delete_count"], 1)
        self.assertEqual(stats["deleted_usernames"], ["ビューア"])

    def test_delete_own_account(self) -> None:
        self.reset()
        status, _ = self.send_json(
            "POST", "/api/users", {"username": "leaver", "password": "pass1234"}
        )
        self.assertEqual(status, 201)
        token = self.login("leaver", "pass1234")
        headers = {"Authorization": "Bearer " + token}

        status, _, _ = self.request("DELETE", "/api/users/me", headers=headers)
        self.assertEqual(status, 204)
        status, _, _ = self.request("GET", "/api/users/me", headers=headers)
        self.assertEqual(status, 401)
        self.assertEqual(self.stats()["user_delete_count"], 1)

    # -- server settings ---------------------------------------------------

    def test_server_settings_get_and_put(self) -> None:
        self.reset()
        status, _, settings = self.get_json("/api/settings/server")
        self.assertEqual(status, 200)
        self.assertEqual(settings["general"]["backend"], "EDCB")
        self.assertEqual(settings["server"]["port"], 7000)
        self.assertIn("recorded_folders", settings["video"])
        self.assertIn("upload_folders", settings["capture"])

        settings["server"]["port"] = 7100
        settings["video"]["recorded_folders"] = ["/record", "/record2"]
        status, _ = self.send_json(
            "PUT", "/api/settings/server", settings, headers=self.admin_headers()
        )
        self.assertEqual(status, 204)
        status, _, updated = self.get_json("/api/settings/server")
        self.assertEqual(updated["server"]["port"], 7100)
        self.assertEqual(updated["video"]["recorded_folders"], ["/record", "/record2"])

        stats = self.stats()
        self.assertEqual(stats["server_settings_put_count"], 1)
        self.assertEqual(stats["last_server_settings"]["server"]["port"], 7100)

        # 未ログイン (管理者でない) の保存は拒否する
        status, _, _ = self.request(
            "PUT", "/api/settings/server",
            body=json.dumps(settings).encode("utf-8"),
            headers={"Content-Type": "application/json"},
        )
        self.assertEqual(status, 401)

        settings["server"]["port"] = 80
        status, error = self.send_json(
            "PUT", "/api/settings/server", settings, headers=self.admin_headers()
        )
        self.assertEqual(status, 422)
        self.assertIn("port", error["detail"])

    # -- maintenance -------------------------------------------------------

    def test_maintenance_task_run_and_status(self) -> None:
        self.reset()
        headers = self.admin_headers()

        status, _, idle = self.get_json("/api/maintenance/batch-scan/status")
        self.assertEqual(status, 200)
        self.assertFalse(idle["is_running"])

        status, _, _ = self.request(
            "POST", "/api/maintenance/batch-scan/run", headers=headers
        )
        self.assertEqual(status, 204)
        status, _, running = self.get_json("/api/maintenance/batch-scan/status")
        self.assertTrue(running["is_running"])
        self.assertEqual(running["total_count"], 8)

        # 実行中の再実行は 429
        status, error = self.send_json(
            "POST", "/api/maintenance/batch-scan/run", {}
        )
        self.assertEqual(status, 429)
        self.assertIn("already running", error["detail"])

        deadline = time.time() + 10
        finished = None
        while time.time() < deadline:
            status, _, finished = self.get_json("/api/maintenance/batch-scan/status")
            if finished["is_running"] is False:
                break
            time.sleep(0.2)
        self.assertIsNotNone(finished)
        self.assertFalse(finished["is_running"])
        self.assertEqual(finished["processed_count"], 8)
        self.assertEqual(finished["total_count"], 8)

        for task in ("background-analysis", "capture-scan", "database-vacuum"):
            status, _, _ = self.request(
                "POST", f"/api/maintenance/{task}/run", headers=headers
            )
            self.assertEqual(status, 204)
            status, _, _ = self.get_json(f"/api/maintenance/{task}/status")
            self.assertEqual(status, 200)

        status, _, _ = self.request(
            "POST", "/api/maintenance/update-database", headers=headers
        )
        self.assertEqual(status, 204)
        status, _, _ = self.request("POST", "/api/maintenance/restart", headers=headers)
        self.assertEqual(status, 204)
        status, _, _ = self.request("POST", "/api/maintenance/shutdown", headers=headers)
        self.assertEqual(status, 204)

        stats = self.stats()
        self.assertEqual(stats["maintenance_run_counts"]["batch-scan"], 1)
        self.assertEqual(stats["maintenance_update_database_count"], 1)
        self.assertEqual(stats["maintenance_restart_count"], 1)
        self.assertEqual(stats["maintenance_shutdown_count"], 1)

    def test_maintenance_log_stream(self) -> None:
        self.reset()
        conn = http.client.HTTPConnection(self.host, self.port, timeout=10)
        try:
            conn.request(
                "GET", "/api/maintenance/logs/server",
                headers={**self.admin_headers(), "Accept": "text/event-stream"},
            )
            response = conn.getresponse()
            self.assertEqual(response.status, 200)
            self.assertIn("text/event-stream", response.getheader("Content-Type", ""))
            # ストリームは閉じないので、log_update が届くまで少しずつ読む
            data = b""
            deadline = time.time() + 5
            while time.time() < deadline and b"event: log_update" not in data:
                chunk = response.read1(1024)
                if not chunk:
                    break
                data += chunk
        finally:
            conn.close()
        text = data.decode("utf-8", "replace")
        self.assertIn("event: initial_log_update", text)
        self.assertIn("KonomiTV Server (mock) started", text)
        self.assertIn("event: log_update", text)

        status, _, _ = self.request("GET", "/api/maintenance/logs/server")
        self.assertEqual(status, 401)

    def test_program_search_records_condition(self) -> None:
        self.reset()
        status, payload = self.send_json(
            "POST", "/api/programs/search",
            {
                "keyword": "",
                "genre_ranges": [{"major": "ドラマ", "middle": "国内ドラマ"}],
                "broadcast_type": "FreeOnly",
                "duration_range_min": 10,
            },
        )
        self.assertEqual(status, 200)
        self.assertGreater(payload["total"], 0)
        stats = self.stats()
        self.assertEqual(stats["program_search_count"], 1)
        condition = stats["last_program_search_condition"]
        self.assertEqual(
            condition["genre_ranges"], [{"major": "ドラマ", "middle": "国内ドラマ"}]
        )
        self.assertEqual(condition["broadcast_type"], "FreeOnly")
        self.assertEqual(condition["duration_range_min"], 10)

        # 日時条件: 全曜日 0:00〜23:59 は全件、除外指定なら 0 件
        full_week = {
            "start_day_of_week": 0, "start_hour": 0, "start_minute": 0,
            "end_day_of_week": 6, "end_hour": 23, "end_minute": 59,
        }
        status, matched = self.send_json(
            "POST", "/api/programs/search", {"date_ranges": [full_week]}
        )
        self.assertEqual(status, 200)
        self.assertGreater(matched["total"], 0)
        status, excluded = self.send_json(
            "POST", "/api/programs/search",
            {"date_ranges": [full_week], "is_exclude_date_ranges": True},
        )
        self.assertEqual(status, 200)
        self.assertEqual(excluded["total"], 0)


if __name__ == "__main__":
    unittest.main()
