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
from urllib.parse import urljoin

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


if __name__ == "__main__":
    unittest.main()
