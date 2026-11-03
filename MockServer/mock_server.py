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

# Web クライアント (client/src/stores/SettingsStore.ts の SYNCABLE_SETTINGS_KEYS) が
# サーバーと同期する設定キー。fixtures/settings_client_default.json はこの全キーを持つ。
SYNCED_CLIENT_SETTING_KEYS = [
    "last_synced_at",
    "saved_twitter_hashtags",
    "mylist",
    "watched_history",
    "pinned_channel_ids",
    "timetable_channel_width",
    "timetable_hour_height",
    "timetable_hover_expand",
    "timetable_dim_shopping_programs",
    "timetable_genre_colors",
    "show_player_background_image",
    "use_pure_black_player_background",
    "tv_channel_sort_by_jikkyo_force",
    "tv_channel_up_down_buttons_reverse",
    "tv_channel_selection_requires_alt_key",
    "use_28hour_clock",
    "show_original_broadcast_time_during_playback",
    "panel_display_state",
    "tv_panel_active_tab",
    "video_panel_active_tab",
    "video_watched_history_max_count",
    "caption_font",
    "always_border_caption_text",
    "specify_caption_opacity",
    "caption_opacity",
    "tv_show_superimpose",
    "video_show_superimpose",
    "capture_save_mode",
    "capture_caption_mode",
    "capture_filename_pattern",
    "prefer_posting_to_nicolive",
    "comment_speed_rate",
    "comment_font_size",
    "close_comment_form_after_sending",
    "mute_vulgar_comments",
    "mute_abusive_discriminatory_prejudiced_comments",
    "mute_big_size_comments",
    "mute_fixed_comments",
    "mute_colored_comments",
    "mute_consecutive_same_characters_comments",
    "mute_comment_keywords_normalize_alphanumeric_width_case",
    "muted_comment_keywords",
    "muted_niconico_user_ids",
    "fold_panel_after_sending_tweet",
    "reset_hashtag_when_program_switches",
    "auto_add_watching_channel_hashtag",
    "twitter_reply_thread_mode",
    "bluesky_reply_thread_mode",
    "twitter_active_tab",
    "tweet_hashtag_position",
    "tweet_capture_watermark_position",
]


# ---------------------------------------------------------------------------
# 状態
# ---------------------------------------------------------------------------

class MockServerState:
    """Shared, thread-safe state for counters and the in-memory client settings."""

    def __init__(self, client_settings: dict | None = None) -> None:
        self.lock = threading.Lock()
        self.keepalive: dict[str, int] = {}
        self.live_active = 0
        self.live_total = 0
        self.settings_put_count = 0
        self.video_delete_count = 0
        self.deleted_video_ids: list[int] = []
        # クライアント設定はプロセスが生きている間だけ保持する (実サーバーでは DB に保存される)
        self.client_settings: dict = copy.deepcopy(client_settings or {})

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

    def record_video_delete(self, video_id: int) -> None:
        with self.lock:
            self.video_delete_count += 1
            self.deleted_video_ids.append(video_id)

    def record_settings_put(self, settings: dict) -> None:
        with self.lock:
            self.settings_put_count += 1
            self.client_settings = copy.deepcopy(settings)

    def snapshot(self) -> dict:
        with self.lock:
            return {
                "keepalive": dict(self.keepalive),
                "live_active": self.live_active,
                "live_total": self.live_total,
                "settings_put_count": self.settings_put_count,
                "video_delete_count": self.video_delete_count,
                "deleted_video_ids": list(self.deleted_video_ids),
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
    series_fixture = _load_json("series.json")
    client_settings = _load_json("settings_client_default.json")

    # デフォルト設定は同期対象キーをすべて持っている必要がある
    missing_keys = [
        key for key in SYNCED_CLIENT_SETTING_KEYS if key not in client_settings
    ]
    if missing_keys:
        raise RuntimeError(f"settings_client_default.json is missing keys: {missing_keys}")

    videos = list(page1.get("recorded_programs", [])) + list(
        page2.get("recorded_programs", [])
    )
    total = page1.get("total", len(videos))

    # シリーズ情報を組み立て、紐づく録画番組に series_id / series_title などを付与する
    series = build_series(series_fixture, videos, channels)
    link_series_to_videos(series, videos)

    media_playlist = ""
    playlist_path = os.path.join(HLS_DIR, "playlist.m3u8")
    if os.path.exists(playlist_path):
        with open(playlist_path, "r", encoding="utf-8") as f:
            media_playlist = f.read()

    sample_ts = b""
    if os.path.exists(SAMPLE_TS_PATH):
        with open(SAMPLE_TS_PATH, "rb") as f:
            sample_ts = f.read()

    # 録画ファイルダウンロード API が返すダミーファイル (実ファイルの先頭を少しだけ)
    download_bytes = sample_ts[:TS_PACKET_SIZE * 10] if sample_ts else b"KonomiTV mock recorded file\n"

    return {
        "version": version,
        "channels": channels,
        "user": user,
        "videos": videos,
        "videos_total": total,
        "series": series,
        "client_settings_default": client_settings,
        "media_playlist": media_playlist,
        "sample_ts": sample_ts,
        "download_bytes": download_bytes,
    }


def find_channel(channels: dict, display_channel_id: str) -> dict | None:
    """Look a channel up by its display channel id (ex: gr011)."""
    for channel_list in channels.values():
        for channel in channel_list:
            if channel.get("display_channel_id") == display_channel_id or channel.get("id") == display_channel_id:
                return channel
    return None


def build_series(series_fixture: dict, videos: list[dict], channels: dict) -> list[dict]:
    """Expand the series fixture into the schemas.Series / SeriesList shape.

    Each broadcast period references recorded programs by ID so the fixture stays
    in sync with videos_page1.json / videos_page2.json.
    """
    videos_by_id = {video.get("id"): video for video in videos}
    result: list[dict] = []
    for entry in series_fixture.get("series", []):
        periods: list[dict] = []
        for index, period in enumerate(entry.get("broadcast_periods", [])):
            channel = find_channel(channels, period.get("channel_display_id", ""))
            if channel is None:
                continue
            recorded_programs = [
                copy.deepcopy(videos_by_id[video_id])
                for video_id in period.get("video_ids", [])
                if video_id in videos_by_id
            ]
            for episode_index, program in enumerate(recorded_programs):
                program["series_id"] = entry["id"]
                program["series_broadcast_period_id"] = index
                program["series_title"] = entry["title"]
                if program.get("episode_number") is None:
                    program["episode_number"] = f"第{episode_index + 1}話"
                if program.get("subtitle") is None:
                    program["subtitle"] = entry["title"]
            periods.append({
                "channel": copy.deepcopy(channel),
                "start_date": period.get("start_date", ""),
                "end_date": period.get("end_date", ""),
                "recorded_programs": recorded_programs,
            })
        result.append({
            "id": entry["id"],
            "title": entry["title"],
            "description": entry.get("description", ""),
            "genres": entry.get("genres", []),
            "broadcast_periods": periods,
            "created_at": entry.get("created_at"),
            "updated_at": entry.get("updated_at"),
        })
    return result


def link_series_to_videos(series: list[dict], videos: list[dict]) -> None:
    """Stamp series_id / series_title / episode info onto the source videos."""
    videos_by_id = {video.get("id"): video for video in videos}
    for entry in series:
        for period_index, period in enumerate(entry["broadcast_periods"]):
            for episode_index, program in enumerate(period["recorded_programs"]):
                video = videos_by_id.get(program["id"])
                if video is None:
                    continue
                video["series_id"] = entry["id"]
                video["series_broadcast_period_id"] = period_index
                video["series_title"] = entry["title"]
                if video.get("episode_number") is None:
                    video["episode_number"] = f"第{episode_index + 1}話"
                if video.get("subtitle") is None:
                    video["subtitle"] = entry["title"]


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


# 番組表向けの 1 時間枠の番組パターン (タイトル接尾辞, 概要, ジャンル)
TIMETABLE_PROGRAM_PATTERNS: list[tuple[str, str, list[dict]]] = [
    ("モーニングニュース", "今日のニュースと天気をお伝えします。",
     [{"major": "ニュース・報道", "middle": "定時・総合"}]),
    ("朝の情報ワイド", "暮らしに役立つ情報をお届けします。",
     [{"major": "情報・ワイドショー", "middle": "芸能・ワイドショー"}]),
    ("アニメ劇場", "人気アニメを毎日放送中。",
     [{"major": "アニメ・特撮", "middle": "国内アニメ"}]),
    ("ひるまえドラマ", "連続ドラマの再放送です。",
     [{"major": "ドラマ", "middle": "国内ドラマ"}]),
    ("午後のスポーツ中継", "白熱の試合を生中継でお届けします。",
     [{"major": "スポーツ", "middle": "野球"}]),
    ("映画劇場", "話題の洋画を放送します。",
     [{"major": "映画", "middle": "洋画"}]),
    ("クイズバラエティ", "家族で楽しめるクイズ番組です。",
     [{"major": "バラエティ", "middle": "クイズ"}]),
]

# ショッピング・通販番組を入れる時間帯 (0 時起点)
SHOPPING_PROGRAM_HOUR = 10
SHOPPING_GENRE = {"major": "情報・ワイドショー", "middle": "ショッピング・通販"}


def iter_channels(channels: dict) -> list[dict]:
    """All channels of a channels fixture, in fixture order."""
    return [channel for channel_list in channels.values() for channel in channel_list]


def all_channels(fixtures: dict) -> list[dict]:
    """Channels that are watchable (the ones the timetable API returns)."""
    return [channel for channel in iter_channels(fixtures["channels"]) if channel.get("is_watchable", True)]


def build_day_programs(channel: dict, day_start: datetime, channel_index: int) -> list[dict]:
    """One hour per program across a whole day, including a shopping program."""
    programs: list[dict] = []
    for hour in range(24):
        start = day_start + timedelta(hours=hour)
        end = start + timedelta(hours=1)
        event_id = 20000 + channel_index * 100 + hour
        if hour == SHOPPING_PROGRAM_HOUR:
            title = f"{channel['name']} ショッピング・通販"
            description = "今日のおすすめ商品を紹介します。"
            genres = [copy.deepcopy(SHOPPING_GENRE)]
        else:
            suffix, description, pattern_genres = TIMETABLE_PROGRAM_PATTERNS[
                hour % len(TIMETABLE_PROGRAM_PATTERNS)
            ]
            title = f"{channel['name']} {suffix}"
            genres = copy.deepcopy(pattern_genres)
        program = _program(
            channel,
            f"day{event_id}",
            start,
            end,
            event_id,
            title,
            description,
            genres,
        )
        # 実サーバー (ProgramsRouter.DecodeEDCBEventInfo) と同じ番組 ID 形式にする
        program["id"] = (
            f"NID{channel['network_id']}-SID{channel['service_id']:03d}-EID{event_id}"
        )
        programs.append(program)
    return programs


def build_timetable(fixtures: dict, start_time: datetime, end_time: datetime) -> list[dict]:
    """Programs for the JST day containing start_time, for every watchable channel."""
    day_start = start_time.astimezone(JST).replace(hour=0, minute=0, second=0, microsecond=0)
    result: list[dict] = []
    for channel_index, channel in enumerate(all_channels(fixtures)):
        programs = []
        for program in build_day_programs(channel, day_start, channel_index):
            program_start = datetime.fromisoformat(program["start_time"])
            program_end = datetime.fromisoformat(program["end_time"])
            # 番組表 API と同じく、指定期間に少しでも重なる番組を返す
            if program_end <= start_time or program_start >= end_time:
                continue
            program["reservation"] = None
            programs.append(program)
        result.append({
            "channel": copy.deepcopy(channel),
            "programs": programs,
            "subchannels": None,
        })
    return result


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
            # 実況勢い (tv_channel_sort_by_jikkyo_force の並び替え用)
            channel["jikkyo_force"] = (index * 37 + 11) % 60 if channel.get("is_watchable", True) else None
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
                    status: int = 200, cache: str = "no-store",
                    extra_headers: dict | None = None) -> None:
        self.send_response(status)
        self.send_header("Content-Type", content_type)
        self.send_header("Content-Length", str(len(body)))
        self.send_header("Cache-Control", cache)
        for name, value in (extra_headers or {}).items():
            self.send_header(name, value)
        self.end_headers()
        if self.command != "HEAD":
            self.wfile.write(body)

    def _read_json_body(self):
        """Read and decode a JSON request body (empty/invalid bodies become {})."""
        length = int(self.headers.get("Content-Length") or 0)
        raw = self.rfile.read(length) if length > 0 else b""
        if not raw:
            return {}
        try:
            return json.loads(raw.decode("utf-8"))
        except (ValueError, UnicodeDecodeError):
            return {}

    # -- 認証 --------------------------------------------------------------

    def _bearer_token(self) -> str:
        authorization = self.headers.get("Authorization") or ""
        if authorization.lower().startswith("bearer "):
            return authorization[len("bearer "):].strip()
        return ""

    def _require_user(self, fixtures: dict) -> dict | None:
        """Log in check: returns the user, or sends 401 and returns None."""
        if self._bearer_token() != MOCK_ACCESS_TOKEN:
            self._send_json({"detail": "Unauthorized"}, 401)
            return None
        return fixtures["user"]

    def _require_admin(self, fixtures: dict) -> dict | None:
        """Admin check: returns the user, or sends 401/403 and returns None."""
        user = self._require_user(fixtures)
        if user is None:
            return None
        if not user.get("is_admin", False):
            self._send_json({"detail": "Forbidden"}, 403)
            return None
        return user

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

        if parts[0] == "series":
            self._handle_series(parts, query, fixtures)
            return

        if parts == ["programs", "timetable"]:
            self._handle_timetable(query, fixtures)
            return

        # 実サーバーの番組検索は POST だが、GET でも簡易検索できるようにしておく
        if parts == ["programs", "search"]:
            self._handle_program_search(
                {
                    "keyword": (query.get("query") or query.get("keyword") or [""])[0],
                },
                fixtures,
            )
            return

        if parts == ["settings", "client"]:
            self._handle_client_settings_get(fixtures, state)
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

        if parts == ["settings", "client"]:
            self._handle_client_settings_put(fixtures, state)
            return

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

        # UI テスト用: 初期状態 (フィクスチャとカウンター) に戻す
        if split.path == "/__mock/reset":
            self._handle_mock_reset()
            return

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

        if parts == ["programs", "search"]:
            self._handle_program_search(self._read_json_body(), fixtures)
            return

        if len(parts) == 3 and parts[0] == "videos" and parts[2] == "reanalyze":
            if self._require_admin(fixtures) is None:
                return
            if not self._video_exists(parts[1], fixtures):
                self._unprocessable("Specified video_id was not found")
                return
            self.send_response(204)
            self.send_header("Content-Length", "0")
            self.end_headers()
            return

        if (len(parts) == 4 and parts[0] == "videos"
                and parts[2] == "thumbnail" and parts[3] == "regenerate"):
            if self._require_admin(fixtures) is None:
                return
            if not self._video_exists(parts[1], fixtures):
                self._unprocessable("Specified video_id was not found")
                return
            self.send_response(204)
            self.send_header("Content-Length", "0")
            self.end_headers()
            return

        self._not_found()

    def do_DELETE(self) -> None:  # noqa: N802
        try:
            self._dispatch_delete()
        except (BrokenPipeError, ConnectionResetError):
            pass

    def _dispatch_delete(self) -> None:
        split = urlsplit(self.path)
        parts = [p for p in split.path[len("/api"):].split("/") if p] \
            if split.path.startswith("/api") else []
        fixtures = self.server.fixtures  # type: ignore[attr-defined]
        state = self.server.state  # type: ignore[attr-defined]

        # /api/videos/{video_id}: 管理者のみ。削除した録画番組はプロセスの生存期間中は戻らない。
        if len(parts) == 2 and parts[0] == "videos":
            user = self._require_admin(fixtures)
            if user is None:
                return
            try:
                video_id = int(parts[1])
            except (TypeError, ValueError):
                self._not_found()
                return
            for index, program in enumerate(fixtures["videos"]):
                if program.get("id") == video_id:
                    del fixtures["videos"][index]
                    fixtures["videos_total"] = len(fixtures["videos"])
                    state.record_video_delete(video_id)
                    self.send_response(204)
                    self.send_header("Content-Length", "0")
                    self.end_headers()
                    return
            self._unprocessable("Specified video_id was not found")
            return

        self._not_found()

    # -- テスト用エンドポイント --------------------------------------------

    def _handle_mock_reset(self) -> None:
        """Restore the fixtures and the counters to their initial state.

        Used by the UI tests (``POST /__mock/reset`` in ``setUp``) so tests
        that delete recorded programs or change the client settings do not
        leak into each other.
        """
        server = self.server
        fixtures = load_fixtures()
        server.fixtures = fixtures  # type: ignore[attr-defined]
        server.state = MockServerState(  # type: ignore[attr-defined]
            fixtures["client_settings_default"]
        )
        self._send_json({"status": "ok"})

    # -- 各エンドポイント (API) ----------------------------------------------

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

        # /videos/search?query=...
        if len(parts) == 2 and parts[1] == "search":
            search_query = (query.get("query") or [""])[0]
            needle = search_query.casefold()
            filtered = [
                p for p in videos
                if needle in str(p.get("title", "")).casefold()
                or needle in str(p.get("series_title") or "").casefold()
                or needle in str(p.get("subtitle") or "").casefold()
            ]
            filtered = self._ordered_videos(filtered, self._order_param(query, allow_ids=False))
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

        # /videos/{video_id}/download
        if len(parts) == 3 and parts[2] == "download":
            self._handle_video_download(parts[1], fixtures)
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

        # /videos?order=desc|asc|ids&page=N[&ids=1&ids=2]
        if len(parts) == 1:
            order = self._order_param(query, allow_ids=True)
            page = self._page_param(query)
            ids_raw = query.get("ids")
            if ids_raw:
                try:
                    ids = [int(value) for value in ids_raw]
                except (TypeError, ValueError):
                    self._send_json({"detail": "ids must be integers"}, 422)
                    return
                by_id = {program.get("id"): program for program in videos}
                if order == "ids":
                    # 指定された順序を維持する (ページングも指定順で行う)
                    target_ids = ids[(page - 1) * 30:page * 30]
                    selected = [by_id[i] for i in target_ids if i in by_id]
                else:
                    selected = self._ordered_videos(
                        [by_id[i] for i in ids if i in by_id], order
                    )
                    selected = self._paginate(selected, len(selected), page)["recorded_programs"]
                total = sum(1 for i in ids if i in by_id)
                self._send_json({"total": total, "recorded_programs": selected})
                return
            ordered = self._ordered_videos(videos, order)
            self._send_json(self._paginate(ordered, len(ordered), page))
            return

        self._not_found()

    def _handle_video_download(self, video_id: str, fixtures: dict) -> None:
        """Return a small dummy recording with a proper Content-Disposition."""
        try:
            wanted = int(video_id)
        except (TypeError, ValueError):
            self._not_found()
            return
        for program in fixtures["videos"]:
            if program.get("id") != wanted:
                continue
            recorded_video = program.get("recorded_video") or {}
            if recorded_video.get("status") == "Recording":
                self._unprocessable("The recorded video is recording")
                return
            file_path = str(recorded_video.get("file_path") or f"video{wanted}.m2ts")
            filename = os.path.basename(file_path) or f"video{wanted}.m2ts"
            content_type = "video/mp4" if file_path.endswith(".mp4") else "video/mp2t"
            self._send_bytes(
                fixtures["download_bytes"],
                content_type,
                extra_headers={
                    "Content-Disposition": f'attachment; filename="{filename}"',
                },
            )
            return
        self._unprocessable("Specified video_id was not found")

    @staticmethod
    def _order_param(query: dict, allow_ids: bool) -> str:
        raw = (query.get("order") or ["desc"])[0]
        allowed = {"desc", "asc"}
        if allow_ids:
            allowed.add("ids")
        return raw if raw in allowed else "desc"

    @staticmethod
    def _ordered_videos(videos: list[dict], order: str) -> list[dict]:
        """Sort like the real API: ORDER BY start_time, id (DESC by default)."""
        if order == "asc":
            return sorted(
                videos,
                key=lambda p: (str(p.get("start_time", "")), int(p.get("id", 0))),
            )
        return sorted(
            videos,
            key=lambda p: (str(p.get("start_time", "")), int(p.get("id", 0))),
            reverse=True,
        )

    @staticmethod
    def _datetime_param(query: dict, name: str, default: datetime) -> datetime:
        """Parse an ISO 8601 query parameter, treating naive values as JST."""
        raw = (query.get(name) or [""])[0]
        if not raw:
            return default
        value = raw.strip()
        if value.endswith(("Z", "z")):
            value = value[:-1] + "+00:00"
        try:
            parsed = datetime.fromisoformat(value)
        except ValueError:
            return default
        if parsed.tzinfo is None:
            parsed = parsed.replace(tzinfo=JST)
        return parsed.astimezone(JST)

    # -- シリーズ ----------------------------------------------------------

    def _handle_series(self, parts: list[str], query: dict, fixtures: dict) -> None:
        series = fixtures["series"]
        order = self._order_param(query, allow_ids=False)
        page = self._page_param(query)

        # /series/search?query=...
        if len(parts) == 2 and parts[1] == "search":
            needle = (query.get("query") or [""])[0].casefold()
            if needle:
                series = [
                    entry for entry in series
                    if needle in str(entry.get("title", "")).casefold()
                    or needle in str(entry.get("description", "")).casefold()
                ]
            self._send_json(self._paginate_series(series, order, page))
            return

        # /series/{series_id}
        if len(parts) == 2:
            try:
                wanted = int(parts[1])
            except (TypeError, ValueError):
                self._not_found()
                return
            for entry in series:
                if entry.get("id") == wanted:
                    self._send_json(entry)
                    return
            self._unprocessable("Specified series_id was not found")
            return

        # /series?order=desc&page=N
        if len(parts) == 1:
            self._send_json(self._paginate_series(series, order, page))
            return

        self._not_found()

    @staticmethod
    def _paginate_series(series: list[dict], order: str, page: int,
                         per_page: int = 30) -> dict:
        """Sort by updated_at like the real API and paginate."""
        ordered = sorted(
            series,
            key=lambda entry: (str(entry.get("updated_at", "")), entry.get("id", 0)),
            reverse=(order != "asc"),
        )
        start = (page - 1) * per_page
        return {
            "total": len(ordered),
            "series_list": ordered[start:start + per_page],
        }

    # -- 番組表・番組検索 --------------------------------------------------

    def _handle_timetable(self, query: dict, fixtures: dict) -> None:
        now = now_jst()
        day_start = now.replace(hour=0, minute=0, second=0, microsecond=0)
        start_time = self._datetime_param(query, "start_time", day_start)
        end_time = self._datetime_param(query, "end_time", start_time + timedelta(hours=24))

        # pinned_channel_ids はカンマ区切りの単一パラメータで、channel_type より優先される
        pinned_raw = (query.get("pinned_channel_ids") or [""])[0]
        pinned_channel_ids = [c.strip() for c in pinned_raw.split(",") if c.strip()]
        channel_type = (query.get("channel_type") or [""])[0]

        channels = build_timetable(fixtures, start_time, end_time)
        if pinned_channel_ids:
            order = {channel_id: index for index, channel_id in enumerate(pinned_channel_ids)}
            channels = [
                entry for entry in channels
                if entry["channel"]["id"] in order or entry["channel"]["display_channel_id"] in order
            ]
            channels.sort(
                key=lambda entry: order.get(
                    entry["channel"]["id"],
                    order.get(entry["channel"]["display_channel_id"], len(order)),
                )
            )
        elif channel_type:
            channels = [entry for entry in channels if entry["channel"]["type"] == channel_type]

        # date_range は DB 上の番組データの範囲 (日付セレクター用)
        all_programs = [program for entry in channels for program in entry["programs"]]
        if all_programs:
            earliest = min(program["start_time"] for program in all_programs)
            latest = max(program["end_time"] for program in all_programs)
        else:
            earliest = isoformat(day_start)
            latest = isoformat(day_start + timedelta(days=7))

        self._send_json({
            "channels": channels,
            "date_range": {"earliest": earliest, "latest": latest},
        })

    def _handle_program_search(self, condition: dict, fixtures: dict) -> None:
        """Simple program search over generated EPG data (today and tomorrow)."""
        now = now_jst()
        day_start = now.replace(hour=0, minute=0, second=0, microsecond=0)

        programs: list[dict] = []
        for channel_index, channel in enumerate(all_channels(fixtures)):
            for day in (0, 1):
                programs.extend(
                    build_day_programs(channel, day_start + timedelta(days=day), channel_index)
                )

        keyword = str(condition.get("keyword") or "")
        exclude_keyword = str(condition.get("exclude_keyword") or "")
        is_title_only = bool(condition.get("is_title_only", False))
        is_case_sensitive = bool(condition.get("is_case_sensitive", False))
        genre_ranges = condition.get("genre_ranges") or []
        service_ranges = condition.get("service_ranges") or []
        is_exclude_genre_ranges = bool(condition.get("is_exclude_genre_ranges", False))
        broadcast_type = str(condition.get("broadcast_type") or "All")
        duration_min = condition.get("duration_range_min")
        duration_max = condition.get("duration_range_max")

        keywords = [word for word in keyword.replace("　", " ").split(" ") if word]
        excludes = [word for word in exclude_keyword.replace("　", " ").split(" ") if word]

        def fold(text: str) -> str:
            return text if is_case_sensitive else text.casefold()

        result: list[dict] = []
        for program in programs:
            # 実 API と同じく、既に終了した番組は検索対象外
            if datetime.fromisoformat(program["end_time"]) <= now:
                continue

            title = fold(str(program.get("title", "")))
            description = fold(str(program.get("description", "")))
            haystack = title if is_title_only else title + " " + description
            if any(fold(word) not in haystack for word in keywords):
                continue
            if any(fold(word) in haystack for word in excludes):
                continue

            program_genres = program.get("genres") or []
            if genre_ranges:
                matched = any(
                    any(
                        program_genre.get("major") == wanted.get("major")
                        and program_genre.get("middle") == wanted.get("middle")
                        for program_genre in program_genres
                    )
                    for wanted in genre_ranges
                )
                if matched == is_exclude_genre_ranges:
                    continue

            if service_ranges:
                matched = any(
                    program.get("network_id") == service.get("network_id")
                    and program.get("service_id") == service.get("service_id")
                    for service in service_ranges
                )
                if matched is False:
                    continue

            if broadcast_type == "FreeOnly" and not program.get("is_free", True):
                continue
            if broadcast_type == "PaidOnly" and program.get("is_free", True):
                continue

            duration_minutes = float(program.get("duration", 0)) / 60
            if duration_min is not None and duration_minutes < float(duration_min):
                continue
            if duration_max is not None and duration_minutes > float(duration_max):
                continue

            result.append(program)

        result.sort(key=lambda program: (program["start_time"], program["id"]))
        self._send_json({"total": len(result), "programs": result})

    # -- クライアント設定 --------------------------------------------------

    def _handle_client_settings_get(self, fixtures: dict,
                                    state: MockServerState) -> None:
        if self._require_user(fixtures) is None:
            return
        self._send_json(state.client_settings)

    def _handle_client_settings_put(self, fixtures: dict,
                                    state: MockServerState) -> None:
        if self._require_user(fixtures) is None:
            return

        body = self._read_json_body()
        if not isinstance(body, dict):
            self._unprocessable("Invalid client settings")
            return

        last_synced_at = body.get("last_synced_at")
        if not isinstance(last_synced_at, (int, float)) or isinstance(last_synced_at, bool):
            self._unprocessable("last_synced_at is required")
            return

        current_last_synced_at = state.client_settings.get("last_synced_at") or 0
        if last_synced_at < current_last_synced_at:
            # 実サーバー (SettingsRouter.ClientSettingsUpdateAPI) と同じく 422 を返す
            self._unprocessable(
                "The client settings are outdated. "
                "Please update the client settings from the server."
            )
            return

        state.record_settings_put(body)
        self.send_response(204)
        self.send_header("Content-Length", "0")
        self.end_headers()

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
        user = self._require_user(fixtures)
        if user is None:
            return
        self._send_json(user)


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
    # クライアント設定は Web クライアントのデフォルト値から始まる
    server.state = MockServerState(  # type: ignore[attr-defined]
        server.fixtures["client_settings_default"]  # type: ignore[attr-defined]
    )
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
