#!/usr/bin/env python3
"""Tests for the mock KonomiTV server (stdlib unittest only).

Run from the MockServer directory:
    python3 -m unittest -v
"""

from __future__ import annotations

import http.client
import json
import os
import threading
import time
import unittest
from datetime import datetime
from urllib.parse import quote, urljoin

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
        with open(os.path.join(mock_server.HLS_DIR, "segment5.ts"), "rb") as f:
            expected = f.read()
        self.assertEqual(data, expected)

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


if __name__ == "__main__":
    unittest.main()
