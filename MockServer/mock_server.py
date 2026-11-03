#!/usr/bin/env python3
"""Mock KonomiTV server for the iOS/iPadOS client.

Python 3 standard library only. Serves a small subset of the real KonomiTV
HTTP API (``/api/...``) from JSON fixtures and local media files so the app and
UI tests can run without a real KonomiTV backend.

Usage:
    python3 MockServer/mock_server.py --port 7010
"""

from __future__ import annotations

import argparse
import base64
import copy
import json
import os
import select
import socket
import threading
import time
from datetime import datetime, timedelta, timezone
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import parse_qs, quote, urlsplit

BASE_DIR = os.path.dirname(os.path.abspath(__file__))
FIXTURE_DIR = os.path.join(BASE_DIR, "fixtures")
MEDIA_DIR = os.path.join(BASE_DIR, "media")
HLS_DIR = os.path.join(MEDIA_DIR, "hls")
SAMPLE_TS_PATH = os.path.join(MEDIA_DIR, "sample.ts")

# 疑似ライブストリームの実時間長 (sample.ts は約 12 秒)
LIVE_DURATION_SECONDS = 12.0
# 録画ビデオの HLS は 6 本のセグメント (各 2 秒) を 10 回繰り返して 120 秒にする。
# バックグラウンド再生や PiP を観察できる長さを確保するため。
HLS_SEGMENT_COUNT = 6
HLS_PLAYLIST_REPEATS = 10
# MPEG-TS パケット (188 バイト) x 64 ずつ送る
TS_PACKET_SIZE = 188
STREAM_CHUNK_SIZE = TS_PACKET_SIZE * 64

JST = timezone(timedelta(hours=9))

BASE_QUALITIES = ("1080p-60fps", "1080p", "720p", "480p", "360p", "240p")
VALID_VIDEO_QUALITIES = set(BASE_QUALITIES) | {q + "-hevc" for q in BASE_QUALITIES}
VALID_LIVE_QUALITIES = VALID_VIDEO_QUALITIES | {"original"}

# 1x1 のダミー画像 (PNG / WebP)
PNG_BYTES = base64.b64decode(
    "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8BQDwAEhQGAhKmMIQAAAABJRU5ErkJggg=="
)
WEBP_BYTES = base64.b64decode(
    "UklGRiQAAABXRUJQVlA4IBgAAAAwAQCdASoBAAEAAwA0JaQAA3AA/vuUAAA="
)

MOCK_ACCESS_TOKEN = "mock-access-token"


# ---------------------------------------------------------------------------
# 状態
# ---------------------------------------------------------------------------

class MockServerState:
    """Shared, thread-safe state for keep-alive and live connection counters."""

    def __init__(self) -> None:
        self.lock = threading.Lock()
        self.keepalive: dict[str, int] = {}
        self.live_active = 0
        self.live_total = 0

    def record_keepalive(self, video_id: str) -> None:
        with self.lock:
            self.keepalive[video_id] = self.keepalive.get(video_id, 0) + 1

    def live_connected(self) -> None:
        with self.lock:
            self.live_active += 1
            self.live_total += 1

    def live_disconnected(self) -> None:
        with self.lock:
            if self.live_active > 0:
                self.live_active -= 1

    def snapshot(self) -> dict:
        with self.lock:
            return {
                "keepalive": dict(self.keepalive),
                "live_active": self.live_active,
                "live_total": self.live_total,
            }


# ---------------------------------------------------------------------------
# フィクスチャ読み込み
# ---------------------------------------------------------------------------

def _load_json(name: str):
    with open(os.path.join(FIXTURE_DIR, name), "r", encoding="utf-8") as f:
        return json.load(f)


def load_fixtures() -> dict:
    version = _load_json("version.json")
    channels = _load_json("channels.json")
    user = _load_json("user.json")
    page1 = _load_json("videos_page1.json")
    page2 = _load_json("videos_page2.json")

    videos = list(page1.get("recorded_programs", [])) + list(
        page2.get("recorded_programs", [])
    )
    total = page1.get("total", len(videos))

    media_playlist = ""
    playlist_path = os.path.join(HLS_DIR, "playlist.m3u8")
    if os.path.exists(playlist_path):
        with open(playlist_path, "r", encoding="utf-8") as f:
            media_playlist = f.read()

    sample_ts = b""
    if os.path.exists(SAMPLE_TS_PATH):
        with open(SAMPLE_TS_PATH, "rb") as f:
            sample_ts = f.read()

    return {
        "version": version,
        "channels": channels,
        "user": user,
        "videos": videos,
        "videos_total": total,
        "media_playlist": media_playlist,
        "sample_ts": sample_ts,
    }


def now_jst() -> datetime:
    return datetime.now(JST)


def isoformat(dt: datetime) -> str:
    return dt.isoformat(timespec="seconds")


def _program(channel: dict, suffix: str, start: datetime, end: datetime,
             event_id: int, title: str, description: str,
             genres: list[dict]) -> dict:
    return {
        "id": f"{channel['display_channel_id']}-{suffix}",
        "channel_id": channel["id"],
        "network_id": channel["network_id"],
        "service_id": channel["service_id"],
        "event_id": event_id,
        "title": title,
        "description": description,
        "detail": {},
        "start_time": isoformat(start),
        "end_time": isoformat(end),
        "duration": (end - start).total_seconds(),
        "is_free": True,
        "genres": genres,
        "video_type": None,
        "video_codec": "H.264",
        "video_resolution": "1080p",
        "primary_audio_type": "2/0モード(ステレオ)",
        "primary_audio_language": "日本語",
        "primary_audio_sampling_rate": "48kHz",
        "secondary_audio_type": None,
        "secondary_audio_language": None,
        "secondary_audio_sampling_rate": None,
    }


def build_channels(channels: dict) -> dict:
    """Return a copy of channels with present/following programs relative to now."""
    result = copy.deepcopy(channels)
    now = now_jst()
    present_start = now - timedelta(minutes=45)
    present_end = now + timedelta(minutes=15)
    following_start = present_end
    following_end = following_start + timedelta(minutes=60)

    for channel_type, channel_list in result.items():
        for index, channel in enumerate(channel_list):
            title_present = f"{channel['name']} ニュース・情報"
            title_following = f"{channel['name']} アニメ劇場"
            if index % 2 == 1:
                title_present, title_following = title_following, title_present
            channel["program_present"] = _program(
                channel,
                "present",
                present_start,
                present_end,
                9000 + index,
                title_present,
                "放送中の番組です。",
                [{"major": "ニュース／報道", "middle": "定時・総合"}],
            )
            channel["program_following"] = _program(
                channel,
                "following",
                following_start,
                following_end,
                9100 + index,
                title_following,
                "このあと放送予定の番組です。",
                [{"major": "アニメ／特撮", "middle": "国内アニメ"}],
            )
    return result


# ---------------------------------------------------------------------------
# HTTP ハンドラ
# ---------------------------------------------------------------------------

class MockHandler(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.0"
    server_version = "KonomiTVMock/1.0"
    sys_version = ""

    # -- ログ (stdout へ) --------------------------------------------------

    def log_message(self, fmt: str, *args) -> None:
        try:
            print(f"[mock] {self.address_string()} {fmt % args}", flush=True)
        except Exception:
            pass

    # -- レスポンスヘルパ --------------------------------------------------

    def _send_json(self, obj, status: int = 200) -> None:
        body = json.dumps(obj, ensure_ascii=False).encode("utf-8")
        self.send_response(status)
        self.send_header("Content-Type", "application/json; charset=utf-8")
        self.send_header("Content-Length", str(len(body)))
        self.send_header("Cache-Control", "no-store")
        self.end_headers()
        if self.command != "HEAD":
            self.wfile.write(body)

    def _send_bytes(self, body: bytes, content_type: str,
                    status: int = 200, cache: str = "no-store") -> None:
        self.send_response(status)
        self.send_header("Content-Type", content_type)
        self.send_header("Content-Length", str(len(body)))
        self.send_header("Cache-Control", cache)
        self.end_headers()
        if self.command != "HEAD":
            self.wfile.write(body)

    def _not_found(self) -> None:
        self._send_json({"detail": "Not Found"}, 404)

    def _unprocessable(self, detail: str = "Specified quality was not found") -> None:
        self._send_json({"detail": detail}, 422)

    # -- リクエストディスパッチ --------------------------------------------

    def do_GET(self) -> None:  # noqa: N802 (http.server API)
        try:
            self._dispatch_get()
        except (BrokenPipeError, ConnectionResetError):
            pass

    def do_HEAD(self) -> None:  # noqa: N802
        try:
            self._dispatch_get()
        except (BrokenPipeError, ConnectionResetError):
            pass

    def do_PUT(self) -> None:  # noqa: N802
        try:
            self._dispatch_put()
        except (BrokenPipeError, ConnectionResetError):
            pass

    def do_POST(self) -> None:  # noqa: N802
        try:
            self._dispatch_post()
        except (BrokenPipeError, ConnectionResetError):
            pass

    def _query(self) -> dict:
        return parse_qs(urlsplit(self.path).query, keep_blank_values=True)

    def _dispatch_get(self) -> None:
        split = urlsplit(self.path)
        path = split.path
        query = self._query()
        fixtures = self.server.fixtures  # type: ignore[attr-defined]
        state = self.server.state  # type: ignore[attr-defined]

        if path == "/__mock/stats":
            self._send_json(state.snapshot())
            return

        if not path.startswith("/api"):
            self._not_found()
            return

        parts = [p for p in path[len("/api"):].split("/") if p]
        if not parts:
            self._not_found()
            return

        if parts == ["version"]:
            self._send_json(fixtures["version"])
            return

        if parts == ["channels"]:
            self._send_json(build_channels(fixtures["channels"]))
            return

        if len(parts) == 3 and parts[0] == "channels" and parts[2] == "logo":
            self._serve_channel_logo(parts[1], fixtures)
            return

        if parts[0] == "videos":
            self._handle_videos(parts, query, fixtures)
            return

        if parts[0] == "streams" and len(parts) >= 2:
            if parts[1] == "video":
                self._handle_video_stream(parts, query, state, fixtures)
                return
            if parts[1] == "live":
                self._handle_live_stream(parts, state, fixtures)
                return

        if parts == ["users", "me"]:
            self._handle_users_me(fixtures)
            return

        self._not_found()

    def _dispatch_put(self) -> None:
        split = urlsplit(self.path)
        parts = [p for p in split.path[len("/api"):].split("/") if p] \
            if split.path.startswith("/api") else []
        query = self._query()
        state = self.server.state  # type: ignore[attr-defined]
        fixtures = self.server.fixtures  # type: ignore[attr-defined]

        if (len(parts) == 5 and parts[0] == "streams" and parts[1] == "video"
                and parts[4] == "keep-alive"):
            video_id, quality = parts[2], parts[3]
            if not self._video_exists(video_id, fixtures):
                self._not_found()
                return
            if not self._valid_quality(quality, allow_original=False):
                self._unprocessable()
                return
            if "session_id" not in query:
                self._send_json({"detail": "session_id is required"}, 422)
                return
            state.record_keepalive(str(video_id))
            self.send_response(204)
            self.send_header("Content-Length", "0")
            self.end_headers()
            return

        self._not_found()

    def _dispatch_post(self) -> None:
        split = urlsplit(self.path)
        parts = [p for p in split.path[len("/api"):].split("/") if p] \
            if split.path.startswith("/api") else []
        fixtures = self.server.fixtures  # type: ignore[attr-defined]

        if parts == ["users", "token"]:
            length = int(self.headers.get("Content-Length") or 0)
            raw = self.rfile.read(length) if length > 0 else b""
            form = parse_qs(raw.decode("utf-8", "replace"), keep_blank_values=True)
            username = (form.get("username") or [""])[0]
            password = (form.get("password") or [""])[0]
            if username == "test" and password == "test":
                self._send_json(
                    {"access_token": MOCK_ACCESS_TOKEN, "token_type": "bearer"}
                )
            else:
                self._send_json(
                    {"detail": "ユーザー名またはパスワードが正しくありません。"}, 401
                )
            return

        self._not_found()

    # -- 各エンドポイント --------------------------------------------------

    def _serve_channel_logo(self, channel_id: str, fixtures: dict) -> None:
        channels = fixtures["channels"]
        for channel_list in channels.values():
            for channel in channel_list:
                if channel["id"] == channel_id or channel["display_channel_id"] == channel_id:
                    self._send_bytes(PNG_BYTES, "image/png", cache="max-age=3600")
                    return
        self._not_found()

    @staticmethod
    def _video_exists(video_id: str, fixtures: dict) -> bool:
        try:
            wanted = int(video_id)
        except (TypeError, ValueError):
            return False
        return any(p.get("id") == wanted for p in fixtures["videos"])

    @staticmethod
    def _valid_quality(quality: str, allow_original: bool) -> bool:
        if quality == "original":
            return allow_original
        return quality in VALID_VIDEO_QUALITIES

    def _handle_videos(self, parts: list[str], query: dict, fixtures: dict) -> None:
        videos = fixtures["videos"]
        total = fixtures["videos_total"]

        # /videos/search?query=...
        if len(parts) == 2 and parts[1] == "search":
            search_query = (query.get("query") or [""])[0]
            needle = search_query.casefold()
            filtered = [p for p in videos if needle in str(p.get("title", "")).casefold()]
            page = self._page_param(query)
            self._send_json(self._paginate(filtered, len(filtered), page))
            return

        # /videos/{video_id}/thumbnail
        if len(parts) == 3 and parts[2] == "thumbnail":
            if not self._video_exists(parts[1], fixtures):
                self._not_found()
                return
            self._send_bytes(WEBP_BYTES, "image/webp", cache="max-age=3600")
            return

        # /videos/{video_id}
        if len(parts) == 2:
            try:
                wanted = int(parts[1])
            except (TypeError, ValueError):
                self._not_found()
                return
            for program in videos:
                if program.get("id") == wanted:
                    self._send_json(program)
                    return
            self._not_found()
            return

        # /videos?order=desc&page=N
        if len(parts) == 1:
            page = self._page_param(query)
            self._send_json(self._paginate(videos, total, page))
            return

        self._not_found()

    @staticmethod
    def _page_param(query: dict) -> int:
        raw = (query.get("page") or ["1"])[0]
        try:
            page = int(raw)
        except (TypeError, ValueError):
            return 1
        return page if page >= 1 else 1

    @staticmethod
    def _paginate(videos: list[dict], total: int, page: int,
                  per_page: int = 30) -> dict:
        start = (page - 1) * per_page
        end = start + per_page
        return {"total": total, "recorded_programs": videos[start:end]}

    def _handle_video_stream(self, parts: list[str], query: dict,
                             state: MockServerState, fixtures: dict) -> None:
        # /streams/video/{video_id}/{quality}/{playlist|segment|keep-alive}
        if len(parts) != 5 or parts[0] != "streams" or parts[1] != "video":
            self._not_found()
            return

        video_id, quality, action = parts[2], parts[3], parts[4]

        if not self._video_exists(video_id, fixtures):
            self._not_found()
            return
        if not self._valid_quality(quality, allow_original=False):
            self._unprocessable()
            return

        if action == "playlist":
            session_id = (query.get("session_id") or [""])[0]
            playlist_type = (query.get("type") or ["primary-audio"])[0]
            if playlist_type == "master":
                body = self._build_master_playlist(session_id, quality)
            elif playlist_type in ("primary-audio", "secondary-audio"):
                body = self._build_media_playlist(session_id, fixtures)
            else:
                self._send_json({"detail": "Invalid playlist type"}, 422)
                return
            self._send_bytes(body.encode("utf-8"), "application/vnd.apple.mpegurl")
            return

        if action == "segment":
            sequence_raw = (query.get("sequence") or [""])[0]
            try:
                sequence = int(sequence_raw)
            except (TypeError, ValueError):
                self._send_json({"detail": "sequence is required"}, 422)
                return
            if "session_id" not in query:
                self._send_json({"detail": "session_id is required"}, 422)
                return
            # プレイリストは 0…59 のシーケンスを持ち、実ファイルは 0…5 を
            # 繰り返し使う (6 セグメント x 10 回 = 120 秒)。
            if sequence < 0 or sequence >= HLS_SEGMENT_COUNT * HLS_PLAYLIST_REPEATS:
                self._not_found()
                return
            segment_path = os.path.join(
                HLS_DIR, f"segment{sequence % HLS_SEGMENT_COUNT}.ts"
            )
            if not os.path.exists(segment_path):
                self._not_found()
                return
            with open(segment_path, "rb") as f:
                body = f.read()
            self._send_bytes(body, "video/mp2t")
            return

        if action == "keep-alive":
            if "session_id" not in query:
                self._send_json({"detail": "session_id is required"}, 422)
                return
            state.record_keepalive(str(video_id))
            self.send_response(204)
            self.send_header("Content-Length", "0")
            self.end_headers()
            return

        self._not_found()

    @staticmethod
    def _build_master_playlist(session_id: str, quality: str) -> str:
        # 実サーバーと同じく CODECS / RESOLUTION は宣言しない
        bandwidth = 8_000_000 if quality.startswith("1080p") else 4_000_000
        return (
            "#EXTM3U\n"
            "#EXT-X-VERSION:3\n"
            "#EXT-X-STREAM-INF:BANDWIDTH=%d\n"
            "playlist?session_id=%s&type=primary-audio\n"
        ) % (bandwidth, quote(session_id, safe=""))

    @staticmethod
    def _source_playlist_entries(fixtures: dict) -> list[str]:
        """EXTINF lines of the fixture playlist (one per source segment)."""
        entries: list[str] = []
        pending = "#EXTINF:2.000000,"
        for line in (fixtures["media_playlist"] or "").splitlines():
            stripped = line.strip()
            if stripped.startswith("#EXTINF"):
                pending = stripped
            elif stripped.startswith("segment") and stripped.endswith(".ts"):
                entries.append(pending)
                pending = "#EXTINF:2.000000,"
        return entries

    @classmethod
    def _build_media_playlist(cls, session_id: str, fixtures: dict) -> str:
        """Build a 120 s VOD playlist by repeating the source segments.

        6 本のセグメント (各 2 秒) を 10 回繰り返し、繰り返しの境目に
        #EXT-X-DISCONTINUITY を挿入する。録画ビデオの再生時間を
        バックグラウンド再生・PiP を観察できる長さにするため。
        """
        entries = cls._source_playlist_entries(fixtures)
        if not entries:
            entries = ["#EXTINF:2.000000,"]

        escaped_session = quote(session_id, safe="")
        lines = [
            "#EXTM3U",
            "#EXT-X-VERSION:3",
            "#EXT-X-TARGETDURATION:2",
            "#EXT-X-MEDIA-SEQUENCE:0",
            "#EXT-X-PLAYLIST-TYPE:VOD",
        ]
        for sequence in range(len(entries) * HLS_PLAYLIST_REPEATS):
            if sequence > 0 and sequence % len(entries) == 0:
                lines.append("#EXT-X-DISCONTINUITY")
            lines.append(entries[sequence % len(entries)])
            lines.append(
                f"segment?session_id={escaped_session}&sequence={sequence}"
            )
        lines.append("#EXT-X-ENDLIST")
        return "\n".join(lines) + "\n"

    def _handle_live_stream(self, parts: list[str], state: MockServerState,
                            fixtures: dict) -> None:
        # /streams/live/{display_channel_id}/{quality}/mpegts
        if len(parts) != 5 or parts[4] != "mpegts":
            self._not_found()
            return
        display_channel_id, quality = parts[2], parts[3]

        channels = fixtures["channels"]
        known = any(
            c["display_channel_id"] == display_channel_id or c["id"] == display_channel_id
            for channel_list in channels.values()
            for c in channel_list
        )
        if not known:
            self._not_found()
            return
        if quality not in VALID_LIVE_QUALITIES:
            self._unprocessable()
            return

        sample = fixtures["sample_ts"]
        if not sample:
            self._send_json({"detail": "Live media is not available"}, 503)
            return

        self.send_response(200)
        self.send_header("Content-Type", "video/mp2t")
        self.send_header("Cache-Control", "no-store")
        self.send_header("Connection", "close")
        self.end_headers()

        state.live_connected()
        try:
            self._stream_sample_loop(sample)
        except (BrokenPipeError, ConnectionResetError, OSError):
            pass
        finally:
            state.live_disconnected()

    def _client_disconnected(self) -> bool:
        """Best-effort detection of a closed client socket (FIN or RST)."""
        try:
            readable, _, _ = select.select([self.connection], [], [], 0)
            if not readable:
                return False
            return self.connection.recv(1, socket.MSG_PEEK) == b""
        except (BlockingIOError, InterruptedError):
            return False
        except OSError:
            return True

    def _stream_sample_loop(self, sample: bytes) -> None:
        bytes_per_second = max(len(sample) / LIVE_DURATION_SECONDS, 1.0)
        offset = 0
        started = time.monotonic()
        bytes_sent = 0
        while True:
            if self._client_disconnected():
                return
            chunk = sample[offset:offset + STREAM_CHUNK_SIZE]
            if not chunk:
                offset = 0
                continue
            offset += len(chunk)
            self.wfile.write(chunk)
            self.wfile.flush()
            bytes_sent += len(chunk)
            # 実時間に合わせてペーシング (累積時間でドリフトを抑える)
            target = started + bytes_sent / bytes_per_second
            delay = target - time.monotonic()
            if delay > 0:
                time.sleep(delay)

    def _handle_users_me(self, fixtures: dict) -> None:
        authorization = self.headers.get("Authorization") or ""
        token = ""
        if authorization.lower().startswith("bearer "):
            token = authorization[len("bearer "):].strip()
        if token != MOCK_ACCESS_TOKEN:
            self.send_response(401)
            self.send_header("Content-Type", "application/json; charset=utf-8")
            body = json.dumps({"detail": "Unauthorized"}, ensure_ascii=False).encode("utf-8")
            self.send_header("Content-Length", str(len(body)))
            self.end_headers()
            self.wfile.write(body)
            return
        self._send_json(fixtures["user"])


# ---------------------------------------------------------------------------
# サーバ
# ---------------------------------------------------------------------------

class MockHTTPServer(ThreadingHTTPServer):
    daemon_threads = True
    allow_reuse_address = True


def create_server(host: str = "0.0.0.0", port: int = 7010) -> MockHTTPServer:
    """Create (but do not start) a mock server bound to host:port."""
    server = MockHTTPServer((host, port), MockHandler)
    server.fixtures = load_fixtures()  # type: ignore[attr-defined]
    server.state = MockServerState()  # type: ignore[attr-defined]
    return server


def main(argv=None) -> int:
    parser = argparse.ArgumentParser(description="Mock KonomiTV server")
    parser.add_argument("--port", type=int, default=7010, help="listen port (default: 7010)")
    parser.add_argument("--host", default="0.0.0.0", help="listen host (default: 0.0.0.0)")
    args = parser.parse_args(argv)

    server = create_server(args.host, args.port)
    host, port = server.server_address[:2]
    print(f"Mock KonomiTV server listening on http://{host}:{port} (API: /api)", flush=True)
    try:
        server.serve_forever()
    except KeyboardInterrupt:
        print("Mock KonomiTV server stopped.", flush=True)
    finally:
        server.server_close()
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
