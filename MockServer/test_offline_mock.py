#!/usr/bin/env python3
"""Tests for the mock offline save stream (stdlib unittest only).

Run from the MockServer directory:
    python3 -m unittest -v test_offline_mock
"""

from __future__ import annotations

import http.client
import json
import struct
import threading
import unittest

import mock_server
import offline_mock


def parse_stream(data: bytes):
    """Split a save stream into (metadata, segments, terminator count)."""
    assert data.startswith(offline_mock.STREAM_MAGIC), data[:16]
    offset = len(offline_mock.STREAM_MAGIC)
    (metadata_length,) = struct.unpack(">I", data[offset:offset + 4])
    offset += 4
    metadata = json.loads(data[offset:offset + metadata_length].decode("utf-8"))
    offset += metadata_length

    segments = []
    terminated = None
    while offset < len(data):
        (sequence,) = struct.unpack(">I", data[offset:offset + 4])
        offset += 4
        if sequence == offline_mock.TERMINATOR_SEQUENCE:
            (terminated,) = struct.unpack(">I", data[offset:offset + 4])
            offset += 4
            break
        duration, length = struct.unpack(">II", data[offset:offset + 8])
        offset += 8
        segments.append((sequence, duration, data[offset:offset + length]))
        offset += length
    return metadata, segments, terminated


class OfflineStreamLayoutTests(unittest.TestCase):
    """Binary layout, using the builder directly (no HTTP)."""

    def setUp(self) -> None:
        self.server = mock_server.create_server("127.0.0.1", 0)
        self.program = self.server.fixtures["videos"][0]

    def tearDown(self) -> None:
        self.server.server_close()

    def test_layout(self) -> None:
        header, payloads = offline_mock.build_stream(self.program, "720p", 8)
        for index, payload in enumerate(payloads):
            header += struct.pack(
                ">III",
                index,
                int(offline_mock.SEGMENT_DURATION_SECONDS * 1000),
                len(payload),
            )
            header += payload
        header += struct.pack(
            ">II", offline_mock.TERMINATOR_SEQUENCE, len(payloads)
        )

        metadata, segments, terminated = parse_stream(header)
        self.assertEqual(metadata["video_id"], self.program["id"])
        self.assertEqual(
            metadata["file_hash"],
            self.program["recorded_video"].get("file_hash", ""),
        )
        self.assertEqual(metadata["quality"], "720p")
        self.assertEqual(
            metadata["duration_seconds"],
            8 * offline_mock.SEGMENT_DURATION_SECONDS,
        )
        self.assertEqual([segment[0] for segment in segments], list(range(8)))
        self.assertEqual(segments[0][1], 2000)
        self.assertEqual(terminated, 8)
        self.assertEqual(segments[0][2], offline_mock.segment_bytes(0))

    def test_segments_reuse_the_hls_mock_segments(self) -> None:
        for sequence in range(offline_mock.OFFLINE_SEGMENT_COUNT):
            self.assertEqual(
                offline_mock.segment_bytes(sequence),
                mock_server.caption_injected_segment(sequence),
                sequence,
            )

    def test_truncated_builder_has_no_terminator(self) -> None:
        header, payloads = offline_mock.build_stream(
            self.program, "720p", 8, truncate=True
        )
        for index, payload in enumerate(payloads):
            header += struct.pack(">III", index, 2000, len(payload)) + payload
        _, segments, terminated = parse_stream(header)
        self.assertEqual(len(segments), offline_mock.TRUNCATED_SEGMENT_COUNT)
        self.assertIsNone(terminated)


class OfflineStreamEndpointTests(unittest.TestCase):
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
        conn = http.client.HTTPConnection(self.host, self.port, timeout=20)
        try:
            hdrs = {"Accept": "*/*"}
            if headers:
                hdrs.update(headers)
            conn.request(method, path, body=body, headers=hdrs)
            response = conn.getresponse()
            return response.status, dict(response.getheaders()), response.read()
        finally:
            conn.close()

    def get_json(self, path: str):
        status, headers, data = self.request("GET", path)
        return status, headers, json.loads(data.decode("utf-8"))

    def config(self, **values) -> None:
        body = json.dumps(values).encode("utf-8")
        status, _, _ = self.request(
            "POST",
            "/__mock/config",
            body=body,
            headers={"Content-Type": "application/json"},
        )
        self.assertEqual(status, 200)

    def stats(self) -> dict:
        status, _, payload = self.get_json("/__mock/stats")
        self.assertEqual(status, 200)
        return payload

    def offline_path(self, video_id=1, quality="720p") -> str:
        return f"/api/streams/video/{video_id}/{quality}/offline-stream"

    def test_endpoint_streams_the_binary_format(self) -> None:
        status, headers, data = self.request("GET", self.offline_path())
        self.assertEqual(status, 200)
        self.assertIn("application/octet-stream", headers.get("Content-Type", ""))
        self.assertEqual(headers.get("X-Content-Type-Options"), "nosniff")

        metadata, segments, terminated = parse_stream(data)
        self.assertEqual(metadata["video_id"], 1)
        self.assertEqual(metadata["quality"], "720p")
        self.assertEqual(len(segments), offline_mock.OFFLINE_SEGMENT_COUNT)
        self.assertEqual(terminated, offline_mock.OFFLINE_SEGMENT_COUNT)

        stats = self.stats()
        self.assertEqual(stats["offline_stream_count"], 1)
        self.assertEqual(stats["offline_stream_video_ids"], [1])
        self.assertEqual(stats["last_offline_quality"], "720p")

    def test_quality_options_are_accepted_and_echoed(self) -> None:
        status, _, data = self.request(
            "GET", self.offline_path(quality="720p-hevc-24fps")
        )
        self.assertEqual(status, 200)
        metadata, _, terminated = parse_stream(data)
        self.assertEqual(metadata["quality"], "720p-hevc-24fps")
        self.assertEqual(terminated, offline_mock.OFFLINE_SEGMENT_COUNT)
        self.assertEqual(self.stats()["last_offline_quality"], "720p-hevc-24fps")

    def test_unknown_video_is_unprocessable(self) -> None:
        status, _, payload = self.get_json(self.offline_path(video_id=9999))
        self.assertEqual(status, 422)
        self.assertIn("detail", payload)

    def test_invalid_quality_is_unprocessable(self) -> None:
        status, _, payload = self.get_json(self.offline_path(quality="2160p"))
        self.assertEqual(status, 422)
        self.assertIn("detail", payload)

    def test_recording_video_conflicts(self) -> None:
        program = self.server.fixtures["videos"][0]
        original = program["recorded_video"].get("status")
        program["recorded_video"]["status"] = "Recording"
        try:
            status, _, payload = self.get_json(self.offline_path())
        finally:
            program["recorded_video"]["status"] = original
        self.assertEqual(status, 409)
        self.assertIn("detail", payload)

    def test_truncation_switch_drops_the_terminator(self) -> None:
        self.config(offline_stream_truncate=True)
        try:
            status, _, data = self.request("GET", self.offline_path())
        finally:
            self.config(offline_stream_truncate=False)
        self.assertEqual(status, 200)
        _, segments, terminated = parse_stream(data)
        self.assertEqual(len(segments), offline_mock.TRUNCATED_SEGMENT_COUNT)
        self.assertIsNone(terminated)

    def test_disabled_switch_answers_404(self) -> None:
        self.config(offline_stream=False)
        try:
            status, _, payload = self.get_json(self.offline_path())
            self.assertEqual(status, 404)
            self.assertEqual(payload.get("detail"), "Not Found")
            self.assertFalse(self.stats()["offline_stream"])
        finally:
            self.config(offline_stream=True)
        self.assertTrue(self.stats()["offline_stream"])

    def test_reset_restores_the_defaults(self) -> None:
        self.config(offline_stream=False, offline_stream_truncate=True)
        status, _, _ = self.request("POST", "/__mock/reset")
        self.assertEqual(status, 200)
        stats = self.stats()
        self.assertTrue(stats["offline_stream"])
        self.assertFalse(stats["offline_stream_truncate"])
        self.assertEqual(stats["offline_stream_count"], 0)
        self.assertEqual(stats["offline_stream_video_ids"], [])


if __name__ == "__main__":
    unittest.main()
