"""Offline save stream (KonomiTV 0.15) for the mock KonomiTV server.

Implements `GET /api/streams/video/{video_id}/{quality}/offline-stream`:

* `KTVODLP\n`
* u32 BE metadata length, metadata JSON (`video_id`, `file_hash`, `quality`,
  `duration_seconds`)
* u32 BE sequence, u32 BE duration (ms), u32 BE length, segment bytes — repeated
* u32 BE `0xFFFFFFFF`, u32 BE segment count

The segments are the same fixture files the recorded-video HLS endpoint serves
(`media/hls/segment*.ts` with the ARIB caption stream injected), so an offline
save of the mock plays back exactly like the streamed version.

Test switches (`POST /__mock/config`):

* `{"offline_stream": false}` makes the server behave like KonomiTV v0.14.1:
  the route answers 404 and the app hides the feature.
* `{"offline_stream_truncate": true}` drops the connection after two segments
  without the terminator record, which the app must report as a failed save.
"""

from __future__ import annotations

import json
import os
import struct
import threading
import time

import caption_injector

BASE_DIR = os.path.dirname(os.path.abspath(__file__))
HLS_DIR = os.path.join(BASE_DIR, "media", "hls")

STREAM_MAGIC = b"KTVODLP\n"
# The fixture playlist has six 2 second segments.
HLS_SEGMENT_COUNT = 6
SEGMENT_DURATION_SECONDS = 2.0
# Segments written before the save completes: one pass over the six source
# segments (12 s), so the stream has no timestamp discontinuity.
OFFLINE_SEGMENT_COUNT = 6
# Pause between segments, so the UI can show a progressing save.
SEGMENT_SEND_INTERVAL_SECONDS = 0.6
# The truncation switch stops after this many segments.
TRUNCATED_SEGMENT_COUNT = 2

TERMINATOR_SEQUENCE = 0xFFFFFFFF

_CAPTIONED_SEGMENT_CACHE: dict[int, bytes] = {}
_CACHE_LOCK = threading.Lock()


def segment_bytes(sequence: int) -> bytes:
    """Fixture segment (captions injected), cached per source segment."""
    index = sequence % HLS_SEGMENT_COUNT
    with _CACHE_LOCK:
        cached = _CAPTIONED_SEGMENT_CACHE.get(index)
    if cached is not None:
        return cached
    with open(os.path.join(HLS_DIR, f"segment{index}.ts"), "rb") as f:
        data = caption_injector.inject_captions(f.read())
    with _CACHE_LOCK:
        _CAPTIONED_SEGMENT_CACHE[index] = data
    return data


def build_stream(program: dict, quality: str, segment_count: int,
                 truncate: bool = False) -> tuple[bytes, list[bytes]]:
    """Return (header bytes, segment payloads) of a save stream."""
    recorded_video = program.get("recorded_video") or {}
    metadata = {
        "video_id": program.get("id"),
        "file_hash": recorded_video.get("file_hash") or "",
        "quality": quality,
        "duration_seconds": segment_count * SEGMENT_DURATION_SECONDS,
    }
    encoded = json.dumps(metadata, ensure_ascii=False).encode("utf-8")
    header = STREAM_MAGIC + struct.pack(">I", len(encoded)) + encoded
    send_count = TRUNCATED_SEGMENT_COUNT if truncate else segment_count
    segments = [segment_bytes(sequence) for sequence in range(send_count)]
    return header, segments


def reset(state) -> None:
    """Restore the default offline save behaviour."""
    state.offline_stream = True
    state.offline_stream_truncate = False
    state.offline_stream_count = 0
    state.offline_stream_video_ids = []
    state.last_offline_quality = None


def handle(handler, parts: list[str], query: dict, fixtures: dict, state) -> None:
    """Serve `/api/streams/video/{video_id}/{quality}/offline-stream`."""
    # v0.14.1 にはこのルート自体がない
    if not state.offline_stream:
        handler._not_found()
        return

    video_id_raw, quality = parts[2], parts[3]
    # 実サーバーと同じ順序で検証する: 録画番組 → 画質
    if not handler._video_exists(video_id_raw, fixtures):
        handler._unprocessable("Specified video_id was not found")
        return
    if not handler._valid_quality(quality, allow_original=False):
        handler._unprocessable("Specified quality was not found")
        return

    program = next(
        program for program in fixtures["videos"]
        if program.get("id") == int(video_id_raw)
    )
    recorded_video = program.get("recorded_video") or {}
    if recorded_video.get("status") == "Recording":
        # 追いかけ再生中のファイルは終端とハッシュが変わるため保存できない
        handler._send_json(
            {"detail": "Recording video cannot be saved for offline playback"},
            409,
        )
        return

    state.record_offline_stream(int(video_id_raw), quality)
    stream(handler, program, quality, state)


def stream(handler, program: dict, quality: str, state) -> None:
    """Write the binary save stream to the response body."""
    header, segments = build_stream(
        program,
        quality,
        OFFLINE_SEGMENT_COUNT,
        truncate=state.offline_stream_truncate,
    )
    handler.send_response(200)
    handler.send_header("Content-Type", "application/octet-stream")
    handler.send_header("Cache-Control", "no-store")
    handler.send_header("X-Content-Type-Options", "nosniff")
    handler.end_headers()

    wfile = handler.wfile
    wfile.write(header)
    wfile.flush()

    for sequence, data in enumerate(segments):
        wfile.write(struct.pack(
            ">III",
            sequence,
            int(SEGMENT_DURATION_SECONDS * 1000),
            len(data),
        ))
        wfile.write(data)
        wfile.flush()
        # 進捗表示を観察できるよう、少しずつ送る
        time.sleep(SEGMENT_SEND_INTERVAL_SECONDS)

    if state.offline_stream_truncate:
        # 終端レコードを書かずに接続を閉じ、途中で切れた保存を再現する
        return

    wfile.write(struct.pack(">II", TERMINATOR_SEQUENCE, len(segments)))
    wfile.flush()
