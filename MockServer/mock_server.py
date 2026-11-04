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
import hashlib
import json
import os
import queue
import select
import socket
import struct
import threading
import time
import zlib
from datetime import datetime, timedelta, timezone
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import parse_qs, quote, urlsplit

import caption_injector
import captures_mock
import data_broadcasting_mock as data_broadcasting
import maintenance_mock
import offline_mock
import reservations_mock
import settings_mock
import ts_timestamps
import twitter_mock
import users_mock

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

# ニコニコ実況 (モック)
# 視聴セッションが seat で通知する keepSeat の間隔 (実サーバーと同じ 30 秒)
JIKKYO_SEAT_KEEP_INTERVAL_SEC = 30
# モックの視聴セッションが ping を送る間隔 (秒)
JIKKYO_WATCH_PING_INTERVAL = 5.0
# コメントセッションが新着コメントを流す間隔 (秒)
JIKKYO_COMMENT_INTERVAL = 1.0
# コメントセッションがスレッドリクエストを待つ時間 (秒)
JIKKYO_THREAD_REQUEST_TIMEOUT = 5.0
# コメントセッションが接続直後にまとめて送る過去コメントの件数
JIKKYO_INITIAL_COMMENT_COUNT = 12
# 録画番組の過去ログコメントの件数
# 過去ログコメントの件数。録画の尺に対してこの件数を等間隔に並べるため、
# 多いほど最初のコメントが再生開始直後に現れる (UI テストは再生開始から
# 数十秒以内に 1 件目のコメントが流れることを確認する)。
JIKKYO_PAST_COMMENT_COUNT = 200
# 投稿されたコメントに付ける vpos (10 ミリ秒単位) の基準
JIKKYO_MOCK_USER_KEY = "nicolive:mock-user"
# ニコニコ OAuth 連携で設定されるモックユーザーの情報
MOCK_NICONICO_USER_ID = 1234567
MOCK_NICONICO_USER_NAME = "モックニコニコ"
MOCK_NICONICO_USER_PREMIUM = True

JST = timezone(timedelta(hours=9))

# ライブストリーム イベント API: Standby を返してから ONAir になるまでの待ち時間 (秒)
LIVE_EVENTS_STANDBY_SECONDS = 0.5
# ライブストリーム イベント API: clients_update を流す間隔 (秒)
LIVE_EVENTS_UPDATE_INTERVAL = 2.0
# clients_update を何回流すごとに keep-alive のコメントを挟むか
LIVE_EVENTS_PING_INTERVAL_TICKS = 3

# 実サーバー (server/app/constants.py の QUALITY) と同じ並びのベース画質
BASE_QUALITIES = (
    "1080p-60fps", "1080p", "810p", "720p", "540p", "480p", "360p", "240p",
)
VALID_VIDEO_QUALITIES = set(BASE_QUALITIES) | {q + "-hevc" for q in BASE_QUALITIES}
VALID_LIVE_QUALITIES = VALID_VIDEO_QUALITIES | {"original"}

# 画質ごとの (映像ビットレート最大, 音声ビットレート) 。定数は constants.py と同じ (Kbps)
QUALITY_BITRATES = {
    "1080p-60fps": (13000, 256),
    "1080p-60fps-hevc": (5200, 192),
    "1080p": (13000, 256),
    "1080p-hevc": (4500, 192),
    "810p": (7600, 192),
    "810p-hevc": (3700, 192),
    "720p": (6200, 192),
    "720p-hevc": (3000, 192),
    "540p": (4100, 192),
    "540p-hevc": (2100, 192),
    "480p": (2800, 192),
    "480p-hevc": (1750, 192),
    "360p": (1800, 128),
    "360p-hevc": (1250, 128),
    "240p": (650, 128),
    "240p-hevc": (650, 128),
}

# API パスの品質指定の末尾に付くエンコードオプション (-10bit は本クライアントでは使わないが受け付ける)
QUALITY_OPTION_SUFFIXES = ("-24fps", "-10bit")


def _public_user(user: dict) -> dict:
    """A user as UsersRouter returns it (never the password)."""
    return {key: copy.deepcopy(value) for key, value in user.items() if key != "password"}

def _matches_date_range(start_time: datetime, date_range: dict) -> bool:
    """Whether a program start falls in one ProgramSearchConditionDate range."""
    try:
        start_minutes = (
            int(date_range["start_day_of_week"]) * 1440
            + int(date_range["start_hour"]) * 60
            + int(date_range["start_minute"])
        )
        end_minutes = (
            int(date_range["end_day_of_week"]) * 1440
            + int(date_range["end_hour"]) * 60
            + int(date_range["end_minute"])
        )
    except (KeyError, TypeError, ValueError):
        return False
    # Python's weekday() is Monday=0; the API uses Sunday=0.
    weekday = (start_time.weekday() + 1) % 7
    program_minutes = weekday * 1440 + start_time.hour * 60 + start_time.minute
    if start_minutes <= end_minutes:
        return start_minutes <= program_minutes <= end_minutes
    # A range that wraps around the end of the week (e.g. Sunday 22:00 to
    # Monday 03:59) matches both ends.
    return program_minutes >= start_minutes or program_minutes <= end_minutes

def split_api_quality(quality: str) -> tuple[str, bool]:
    """Split "720p-hevc-24fps" into its base quality and the 24fps flag.

    Mirrors server/app/streams/StreamEncodingOptions.py: the suffixes are peeled
    off from the end so a base quality that itself ends with -hevc still works.
    """
    base_quality = quality
    is_24fps_mode = False
    for suffix in QUALITY_OPTION_SUFFIXES:
        if base_quality.endswith(suffix):
            base_quality = base_quality[: -len(suffix)]
            if suffix == "-24fps":
                is_24fps_mode = True
    return base_quality, is_24fps_mode

# シークバー用タイルサムネイル (6 列 x 2 行、12 枚、1 枚 10 秒)
TILE_WIDTH = 160
TILE_HEIGHT = 90
TILE_COLUMNS = 6
TILE_ROWS = 2
TILE_TOTAL = TILE_COLUMNS * TILE_ROWS
TILE_INTERVAL_SEC = 10.0
TILED_THUMBNAIL_INFO = {
    "version": 1,
    "representative": None,
    "tile": {
        "format": "png",
        "image_width": TILE_WIDTH * TILE_COLUMNS,
        "image_height": TILE_HEIGHT * TILE_ROWS,
        "tile_width": TILE_WIDTH,
        "tile_height": TILE_HEIGHT,
        "total_tiles": TILE_TOTAL,
        "column_count": TILE_COLUMNS,
        "row_count": TILE_ROWS,
        "interval_sec": TILE_INTERVAL_SEC,
    },
}


def _png_chunk(kind: bytes, data: bytes) -> bytes:
    payload = kind + data
    return (
        struct.pack(">I", len(data))
        + payload
        + struct.pack(">I", zlib.crc32(payload) & 0xFFFFFFFF)
    )


def build_tiled_thumbnail_png() -> bytes:
    """Generate a valid PNG with one solid colour per tile (stdlib only).

    The iOS UI crops this sheet with Core Graphics, so the image has to have
    the real dimensions from TILED_THUMBNAIL_INFO instead of being a 1x1
    placeholder.
    """
    width = TILE_WIDTH * TILE_COLUMNS
    height = TILE_HEIGHT * TILE_ROWS
    palette = [
        (202, 72, 72), (214, 128, 54), (206, 182, 58), (84, 168, 92),
        (66, 142, 196), (104, 88, 186), (178, 82, 156), (76, 176, 176),
        (140, 104, 62), (110, 122, 138), (188, 118, 92), (96, 160, 120),
    ]

    raw = bytearray()
    for y in range(height):
        raw.append(0)  # filter type: none
        row = y // TILE_HEIGHT
        for x in range(width):
            column = x // TILE_WIDTH
            raw.extend(palette[(row * TILE_COLUMNS + column) % len(palette)])

    header = struct.pack(">IIBBBBB", width, height, 8, 2, 0, 0, 0)
    return (
        b"\x89PNG\r\n\x1a\n"
        + _png_chunk(b"IHDR", header)
        + _png_chunk(b"IDAT", zlib.compress(bytes(raw), 9))
        + _png_chunk(b"IEND", b"")
    )


TILED_THUMBNAIL_PNG = build_tiled_thumbnail_png()

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
        # ニコニコ実況 (視聴セッション / コメントセッション) の接続カウンタ
        self.jikkyo_watch_active = 0
        self.jikkyo_watch_total = 0
        self.jikkyo_comment_active = 0
        self.jikkyo_comment_total = 0
        self.jikkyo_keep_seat_count = 0
        self.jikkyo_posted_comments: list[str] = []
        # チャンネルごとのコメントセッション WebSocket (投稿コメントの配信用)
        self.jikkyo_comment_sockets: dict[str, list] = {}
        # ニコニコ OAuth 連携の呼び出し回数
        self.niconico_authorize_count = 0
        self.niconico_link_count = 0
        self.niconico_unlink_count = 0
        # オフライン保存ストリーム (0.15+) の応答回数と直近の画質
        self.offline_stream = True
        self.offline_stream_truncate = False
        self.offline_stream_count = 0
        self.offline_stream_video_ids: list[int] = []
        self.last_offline_quality: str | None = None
        # 直近にリクエストされた品質・プレイリスト種別 (UI テストの検証用)
        self.last_live_quality: str | None = None
        # データ放送 (BML) のモック
        # POST /__mock/config {"data_component": true} で PMT にデータ放送の
        # コンポーネントを足す (カルーセルは配信しないので、アプリは loading の
        # ままになる)。既定はデータ放送なしのチャンネル。
        self.data_component = False
        self.psi_archived_data_count = 0
        self.psi_archived_data_channels: list[str] = []
        self.last_psi_archived_quality: str | None = None
        self.last_video_quality: str | None = None
        self.last_video_playlist_type: str | None = None
        self.last_video_media_playlist_type: str | None = None
        # クライアント設定はプロセスが生きている間だけ保持する (実サーバーでは DB に保存される)
        self.client_settings: dict = copy.deepcopy(client_settings or {})
        # キャプチャライブラリ (v0.15+) を持つサーバーかどうか
        # POST /__mock/config {"captures_library": false} で v0.14.1 相当になる
        self.captures_library = True
        self.capture_upload_count = 0
        self.last_capture_upload: dict | None = None
        # 受け取ったキャプチャの一覧 (EXIF から読んだ番組情報と撮影日時を含む)
        self.capture_uploads: list[dict] = []
        # お気に入りの付け外しの回数 (UI テストの検証用)
        self.capture_favorite_add_count = 0
        self.capture_favorite_remove_count = 0
        # Twitter / Bluesky 連携・投稿・リアクションのカウンタ (UI テストの検証用)
        self.twitter_auth_count = 0
        self.twitter_account_delete_count = 0
        self.twitter_keep_alive_count = 0
        self.twitter_posted_tweets: list[dict] = []
        self.twitter_retweet_count = 0
        self.twitter_unretweet_count = 0
        self.twitter_favorite_count = 0
        self.twitter_unfavorite_count = 0
        self.twitter_reaction_events: list[dict] = []
        self.bluesky_auth_count = 0
        self.bluesky_account_delete_count = 0
        self.bluesky_posted_posts: list[dict] = []
        self.bluesky_repost_count = 0
        self.bluesky_unrepost_count = 0
        self.bluesky_like_count = 0
        self.bluesky_unlike_count = 0
        self.bluesky_reaction_events: list[dict] = []
        self.account_link_create_count = 0
        self.account_link_delete_count = 0
        # 録画予約・キーワード自動予約条件・録画設定プリセットのカウンタ
        self.reservation_add_count = 0
        self.reservation_added_program_ids: list[str] = []
        self.reservation_update_count = 0
        self.reservation_updated_ids: list[int] = []
        self.last_reservation_settings: dict | None = None
        self.reservation_delete_count = 0
        self.reservation_deleted_ids: list[int] = []
        self.reservation_condition_add_count = 0
        self.reservation_condition_update_count = 0
        self.reservation_condition_delete_count = 0
        self.reservation_condition_deleted_ids: list[int] = []
        self.last_reservation_condition: dict | None = None
        self.reservation_presets_fetch_count = 0
        # ユーザーアカウント (users_mock が初期化・更新する)
        self.users: list[dict] = []
        self.access_tokens: dict[str, int] = {}
        self.primary_token: str = ""
        self.primary_user_id: int = 1
        self.user_icons: dict[int, bytes] = {}
        self.user_create_count = 0
        self.created_usernames: list[str] = []
        self.user_update_count = 0
        self.last_user_update: dict | None = None
        self.user_icon_update_count = 0
        self.last_user_icon: dict | None = None
        self.user_delete_count = 0
        self.deleted_usernames: list[str] = []
        self.user_admin_update_count = 0
        # サーバー設定 (settings_mock が初期化する)
        self.server_settings: dict = {}
        self.server_settings_put_count = 0
        self.last_server_settings: dict | None = None
        # メンテナンス (maintenance_mock が初期化する)
        self.maintenance_tasks: dict[str, dict] = {}
        self.maintenance_run_counts: dict[str, int] = {}
        self.maintenance_update_database_count = 0
        self.maintenance_restart_count = 0
        self.maintenance_shutdown_count = 0
        # 番組検索 (UI テストがリクエストボディを検証する)
        self.program_search_count = 0
        self.last_program_search_condition: dict | None = None

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

    def record_live_quality(self, quality: str) -> None:
        with self.lock:
            self.last_live_quality = quality

    def record_offline_stream(self, video_id: int, quality: str) -> None:
        with self.lock:
            self.offline_stream_count += 1
            self.offline_stream_video_ids.append(video_id)
            self.last_offline_quality = quality

    def record_psi_archived_data(self, display_channel_id: str, quality: str) -> None:
        with self.lock:
            self.psi_archived_data_count += 1
            self.psi_archived_data_channels.append(display_channel_id)
            self.last_psi_archived_quality = quality
            self.last_live_quality = quality

    def record_video_quality(self, quality: str, playlist_type: str | None = None) -> None:
        with self.lock:
            self.last_video_quality = quality
            if playlist_type == "master":
                # The UI tests verify that recorded videos are requested as the
                # master playlist. Media playlist requests are recorded
                # separately so they do not overwrite that check.
                self.last_video_playlist_type = playlist_type
            elif playlist_type is not None:
                self.last_video_media_playlist_type = playlist_type

    def record_settings_put(self, settings: dict) -> None:
        with self.lock:
            self.settings_put_count += 1
            self.client_settings = copy.deepcopy(settings)

    # -- ニコニコ実況 ------------------------------------------------------

    def jikkyo_watch_connected(self) -> None:
        with self.lock:
            self.jikkyo_watch_active += 1
            self.jikkyo_watch_total += 1

    def jikkyo_watch_disconnected(self) -> None:
        with self.lock:
            if self.jikkyo_watch_active > 0:
                self.jikkyo_watch_active -= 1

    def jikkyo_comment_connected(self, channel_id: str, socket_connection) -> None:
        with self.lock:
            self.jikkyo_comment_active += 1
            self.jikkyo_comment_total += 1
            self.jikkyo_comment_sockets.setdefault(channel_id, []).append(socket_connection)

    def jikkyo_comment_disconnected(self, channel_id: str, socket_connection) -> None:
        with self.lock:
            if self.jikkyo_comment_active > 0:
                self.jikkyo_comment_active -= 1
            sockets = self.jikkyo_comment_sockets.get(channel_id) or []
            if socket_connection in sockets:
                sockets.remove(socket_connection)
            if not sockets:
                self.jikkyo_comment_sockets.pop(channel_id, None)

    def record_jikkyo_keep_seat(self) -> None:
        with self.lock:
            self.jikkyo_keep_seat_count += 1

    def record_jikkyo_post(self, text: str) -> None:
        with self.lock:
            self.jikkyo_posted_comments.append(text)

    def broadcast_jikkyo_chat(self, channel_id: str, payload: dict) -> int:
        """Send one chat message to every comment session of a channel."""
        with self.lock:
            sockets = list(self.jikkyo_comment_sockets.get(channel_id) or [])
        sent = 0
        for socket_connection in sockets:
            if socket_connection.send_json(payload):
                sent += 1
        return sent

    def record_niconico_authorize(self) -> None:
        with self.lock:
            self.niconico_authorize_count += 1

    def record_niconico_link(self) -> None:
        with self.lock:
            self.niconico_link_count += 1

    def record_niconico_unlink(self) -> None:
        with self.lock:
            self.niconico_unlink_count += 1

    def record_capture_upload(
        self,
        filename: str,
        fields: dict,
        size: int,
        content_type: str,
        metadata: dict | None = None,
        date_time_original: str | None = None,
    ) -> None:
        with self.lock:
            self.capture_upload_count += 1
            upload = {
                "filename": filename,
                "fields": fields,
                "size": size,
                "content_type": content_type,
                # EXIF の XPComment (読めなければ None)
                "metadata": metadata,
                # EXIF の DateTimeOriginal (EXIF 形式の文字列)
                "date_time_original": date_time_original,
            }
            self.last_capture_upload = upload
            self.capture_uploads.append(copy.deepcopy(upload))

    def record_capture_favorite(self, added: int = 0, removed: int = 0) -> None:
        with self.lock:
            self.capture_favorite_add_count += added
            self.capture_favorite_remove_count += removed

    # -- 録画予約 ----------------------------------------------------------

    def record_reservation_add(self, program_id: str, settings: dict) -> None:
        with self.lock:
            self.reservation_add_count += 1
            self.reservation_added_program_ids.append(program_id)
            self.last_reservation_settings = copy.deepcopy(settings)

    def record_reservation_update(self, reservation_id: int, settings: dict) -> None:
        with self.lock:
            self.reservation_update_count += 1
            self.reservation_updated_ids.append(int(reservation_id))
            self.last_reservation_settings = copy.deepcopy(settings)

    def record_reservation_delete(self, reservation_id: int) -> None:
        with self.lock:
            self.reservation_delete_count += 1
            self.reservation_deleted_ids.append(int(reservation_id))

    def record_reservation_condition_add(self, condition: dict) -> None:
        with self.lock:
            self.reservation_condition_add_count += 1
            self.last_reservation_condition = copy.deepcopy(condition)

    def record_reservation_condition_update(self, condition: dict) -> None:
        with self.lock:
            self.reservation_condition_update_count += 1
            self.last_reservation_condition = copy.deepcopy(condition)

    def record_reservation_condition_delete(self, condition_id: int) -> None:
        with self.lock:
            self.reservation_condition_delete_count += 1
            self.reservation_condition_deleted_ids.append(int(condition_id))

    def record_reservation_presets_fetch(self) -> None:
        with self.lock:
            self.reservation_presets_fetch_count += 1

    def snapshot(self) -> dict:
        with self.lock:
            return {
                "keepalive": dict(self.keepalive),
                "live_active": self.live_active,
                "live_total": self.live_total,
                "settings_put_count": self.settings_put_count,
                "video_delete_count": self.video_delete_count,
                "deleted_video_ids": list(self.deleted_video_ids),
                "last_live_quality": self.last_live_quality,
                "data_component": self.data_component,
                "psi_archived_data_count": self.psi_archived_data_count,
                "psi_archived_data_channels": list(self.psi_archived_data_channels),
                "last_psi_archived_quality": self.last_psi_archived_quality,
                "last_video_quality": self.last_video_quality,
                "last_video_playlist_type": self.last_video_playlist_type,
                "offline_stream": self.offline_stream,
                "offline_stream_truncate": self.offline_stream_truncate,
                "offline_stream_count": self.offline_stream_count,
                "offline_stream_video_ids": list(self.offline_stream_video_ids),
                "last_offline_quality": self.last_offline_quality,
                "last_video_media_playlist_type": self.last_video_media_playlist_type,
                "jikkyo_watch_active": self.jikkyo_watch_active,
                "jikkyo_watch_total": self.jikkyo_watch_total,
                "jikkyo_comment_active": self.jikkyo_comment_active,
                "jikkyo_comment_total": self.jikkyo_comment_total,
                "jikkyo_keep_seat_count": self.jikkyo_keep_seat_count,
                "jikkyo_posted_comments": list(self.jikkyo_posted_comments),
                "niconico_authorize_count": self.niconico_authorize_count,
                "niconico_link_count": self.niconico_link_count,
                "niconico_unlink_count": self.niconico_unlink_count,
                "captures_library": self.captures_library,
                "capture_upload_count": self.capture_upload_count,
                "capture_uploads": copy.deepcopy(self.capture_uploads),
                "last_capture_upload": copy.deepcopy(self.last_capture_upload),
                "capture_favorite_add_count": self.capture_favorite_add_count,
                "capture_favorite_remove_count": self.capture_favorite_remove_count,
                "twitter_auth_count": self.twitter_auth_count,
                "twitter_account_delete_count": self.twitter_account_delete_count,
                "twitter_keep_alive_count": self.twitter_keep_alive_count,
                "twitter_posted_tweets": copy.deepcopy(self.twitter_posted_tweets),
                "twitter_retweet_count": self.twitter_retweet_count,
                "twitter_unretweet_count": self.twitter_unretweet_count,
                "twitter_favorite_count": self.twitter_favorite_count,
                "twitter_unfavorite_count": self.twitter_unfavorite_count,
                "twitter_reaction_events": copy.deepcopy(self.twitter_reaction_events),
                "bluesky_auth_count": self.bluesky_auth_count,
                "bluesky_account_delete_count": self.bluesky_account_delete_count,
                "bluesky_posted_posts": copy.deepcopy(self.bluesky_posted_posts),
                "bluesky_repost_count": self.bluesky_repost_count,
                "bluesky_unrepost_count": self.bluesky_unrepost_count,
                "bluesky_like_count": self.bluesky_like_count,
                "bluesky_unlike_count": self.bluesky_unlike_count,
                "bluesky_reaction_events": copy.deepcopy(self.bluesky_reaction_events),
                "account_link_create_count": self.account_link_create_count,
                "account_link_delete_count": self.account_link_delete_count,
                "reservation_add_count": self.reservation_add_count,
                "reservation_added_program_ids": list(self.reservation_added_program_ids),
                "reservation_update_count": self.reservation_update_count,
                "reservation_updated_ids": list(self.reservation_updated_ids),
                "last_reservation_settings": copy.deepcopy(self.last_reservation_settings),
                "reservation_delete_count": self.reservation_delete_count,
                "reservation_deleted_ids": list(self.reservation_deleted_ids),
                "reservation_condition_add_count": self.reservation_condition_add_count,
                "reservation_condition_update_count": self.reservation_condition_update_count,
                "reservation_condition_delete_count": self.reservation_condition_delete_count,
                "reservation_condition_deleted_ids": list(self.reservation_condition_deleted_ids),
                "last_reservation_condition": copy.deepcopy(self.last_reservation_condition),
                "reservation_presets_fetch_count": self.reservation_presets_fetch_count,
                "user_create_count": self.user_create_count,
                "created_usernames": list(self.created_usernames),
                "user_update_count": self.user_update_count,
                "last_user_update": copy.deepcopy(self.last_user_update),
                "user_icon_update_count": self.user_icon_update_count,
                "last_user_icon": copy.deepcopy(self.last_user_icon),
                "user_delete_count": self.user_delete_count,
                "deleted_usernames": list(self.deleted_usernames),
                "user_admin_update_count": self.user_admin_update_count,
                "users": [_public_user(user) for user in self.users],
                "server_settings_put_count": self.server_settings_put_count,
                "last_server_settings": copy.deepcopy(self.last_server_settings),
                "maintenance_tasks": copy.deepcopy(self.maintenance_tasks),
                "maintenance_run_counts": dict(self.maintenance_run_counts),
                "maintenance_update_database_count": self.maintenance_update_database_count,
                "maintenance_restart_count": self.maintenance_restart_count,
                "maintenance_shutdown_count": self.maintenance_shutdown_count,
                "program_search_count": self.program_search_count,
                "last_program_search_condition": copy.deepcopy(
                    self.last_program_search_condition
                ),
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

    # シークバー用のタイルサムネイル情報を全録画番組に付与する
    for program in videos:
        recorded_video = program.get("recorded_video")
        if isinstance(recorded_video, dict) and recorded_video.get("thumbnail_info") is None:
            recorded_video["thumbnail_info"] = copy.deepcopy(TILED_THUMBNAIL_INFO)

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
        # 字幕の ELEMENTARY STREAM を持たないフィクスチャに、PMT を書き換えて
        # 実際の ARIB 字幕 PES を注入する (バイナリはコミットしない)。
        sample_ts = caption_injector.inject_captions(sample_ts)

    # 録画ファイルダウンロード API が返すダミーファイル (実ファイルの先頭を少しだけ)
    download_bytes = sample_ts[:TS_PACKET_SIZE * 10] if sample_ts else b"KonomiTV mock recorded file\n"

    # 録画予約のフィクスチャが参照する番組 (今日と明日の番組表と同じ ID になる)
    reservation_programs: dict[str, tuple[dict, dict]] = {}
    reservation_now = now_jst()
    reservation_day_start = reservation_now.replace(hour=0, minute=0, second=0, microsecond=0)
    for channel_index, channel in enumerate(all_channels({"channels": channels})):
        for day in (0, 1):
            for program in build_day_programs(
                channel, reservation_day_start + timedelta(days=day), channel_index
            ):
                # 番組 ID は日付に依存しないため、同じ ID は今日の番組を優先して
                # 残す。ただし終わった番組は明日の同じ時間帯の番組に置き換える
                # (深夜には今日の番組がほとんど残っておらず、予約が作れない)。
                kept = reservation_programs.get(program["id"])
                if kept is None or datetime.fromisoformat(kept[1]["end_time"]) <= reservation_now:
                    reservation_programs[program["id"]] = (channel, program)

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
        **captures_mock.build_fixtures(videos, channels),
        **twitter_mock.build_fixtures(),
        **reservations_mock.build_fixtures(reservation_programs),
    }


_SEGMENT_CACHE: dict[int, bytes] = {}
_SEGMENT_LOOP: tuple[int, dict[int, int]] | None = None


def _captioned_source_segment(index: int) -> bytes:
    """One of the six fixture segment files with the ARIB caption stream injected."""
    return offline_mock.segment_bytes(index)


def _segment_loop() -> tuple[int, dict[int, int]]:
    """90 kHz length and per-PID continuity counts of one pass over the six
    source segments."""
    global _SEGMENT_LOOP
    if _SEGMENT_LOOP is None:
        joined = b"".join(_captioned_source_segment(i) for i in range(HLS_SEGMENT_COUNT))
        _SEGMENT_LOOP = (ts_timestamps.loop_length_ticks(joined), ts_timestamps.continuity_counts(joined))
    return _SEGMENT_LOOP


def caption_injected_segment(sequence: int) -> bytes:
    """Return a fixture HLS segment with the ARIB caption stream injected.

    The playlist repeats the six source files; each repetition has its
    timestamps and continuity counters moved past the previous one, so the
    120 s recording is one continuous stream like a real recording (no
    #EXT-X-DISCONTINUITY).
    Results are cached per sequence.
    """
    cached = _SEGMENT_CACHE.get(sequence)
    if cached is not None:
        return cached
    data = _captioned_source_segment(sequence % HLS_SEGMENT_COUNT)
    repetition = sequence // HLS_SEGMENT_COUNT
    ticks, counts = _segment_loop()
    data = ts_timestamps.repeat(data, repetition, ticks, counts)
    _SEGMENT_CACHE[sequence] = data
    return data


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
            # 予約済みの番組には予約情報を付ける (TimeTableProgramReservation)
            program["reservation"] = reservations_mock.reservation_summary(
                fixtures, program["id"]
            )
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
# ニコニコ実況 (コメント) のモックデータ
# ---------------------------------------------------------------------------

# ニコニコの色コマンド → 16 進数カラーコード (client/src/utils/CommentUtils.ts の
# color_table と同じ並び。ここではモックで使う色だけを定義する)
JIKKYO_COLOR_TABLE = {
    "white": "#FFEAEA",
    "red": "#F02840",
    "pink": "#FD7E80",
    "orange": "#FDA708",
    "yellow": "#FFE133",
    "green": "#64DD17",
    "cyan": "#00D4F5",
    "blue": "#4763FF",
    "purple": "#D500F9",
    "black": "#1E1310",
}

JIKKYO_POSITION_TABLE = {"ue": "top", "naka": "right", "shita": "bottom"}

# コメントセッションが流すコメントのテンプレート。
# 色付き・上固定・大きい・小さい・露骨な表現 (組み込みのミュート対象) を一通り含める。
JIKKYO_COMMENT_TEMPLATES = [
    {"mail": "184", "content": "こんばんは"},
    {"mail": "184 red", "content": "赤いコメント"},
    {"mail": "184 ue", "content": "上に固定されるコメント"},
    {"mail": "184 big", "content": "大きいコメント"},
    {"mail": "184 shita small", "content": "下に固定される小さいコメント"},
    {"mail": "184 green", "content": "緑のコメント"},
    {"mail": "184", "content": "きたああああ"},
    # 露骨な表現 (CommentUtils の mute_vulgar_comments に一致する)
    {"mail": "184", "content": "エッチな話をしよう"},
    {"mail": "184 blue big", "content": "青くて大きいコメント"},
    {"mail": "184 orange", "content": "オレンジのコメント"},
    {"mail": "184", "content": "88888888"},
    {"mail": "184 ue small", "content": "上固定の小さいコメント"},
]

# コメントの投稿者 (匿名 ID とニコニコユーザー ID を混ぜる)
JIKKYO_USER_IDS = ["nicolive:1234567", "AbCdEfGhIjKl", "nicolive:7654321", "ZzYyXxWwVvUu"]


def jikkyo_thread_id(channel_id: str) -> str:
    """Thread ID for a channel. The real server uses the program start time."""
    return "mock-thread-" + channel_id


def parse_comment_mail(mail: str | None) -> dict:
    """Resolve a Niconico comment command into color / type / size.

    Mirrors CommentUtils.parseCommentCommand(): the first "184" is dropped and
    the remaining space separated commands are applied in order.
    """
    color = "#FFEAEA"
    position = "right"
    size = "medium"
    if mail:
        for command in mail.replace("184", "", 1).split(" "):
            if command in JIKKYO_COLOR_TABLE:
                color = JIKKYO_COLOR_TABLE[command]
            elif command in JIKKYO_POSITION_TABLE:
                position = JIKKYO_POSITION_TABLE[command]
            elif command in ("big", "medium", "small"):
                size = command
    return {"color": color, "type": position, "size": size}


def build_jikkyo_chat(
    channel_id: str,
    index: int,
    vpos: int,
    date: float,
    *,
    number: int | None = None,
    mail: str | None = None,
    content: str | None = None,
    user_id: str | None = None,
    your_post: int = 0,
    premium: int | None = None,
) -> dict:
    """One "chat" message of the comment session."""
    template = JIKKYO_COMMENT_TEMPLATES[index % len(JIKKYO_COMMENT_TEMPLATES)]
    return {
        "no": number if number is not None else 4000 + index,
        "thread": jikkyo_thread_id(channel_id),
        "vpos": int(vpos),
        "date": int(date),
        "date_usec": int((date - int(date)) * 1_000_000),
        "mail": mail if mail is not None else template["mail"],
        "user_id": user_id or JIKKYO_USER_IDS[index % len(JIKKYO_USER_IDS)],
        "content": content if content is not None else template["content"],
        "premium": premium,
        "anonymity": 1,
        "yourpost": your_post,
        "score": 0,
    }


def build_jikkyo_past_comments(duration: float) -> list[dict]:
    """Past log comments spread over a recording (GET /api/videos/{id}/jikkyo)."""
    length = float(duration or 0)
    if length <= 0:
        length = float(JIKKYO_PAST_COMMENT_COUNT * 60)
    step = length / (JIKKYO_PAST_COMMENT_COUNT + 1)
    comments: list[dict] = []
    for index in range(JIKKYO_PAST_COMMENT_COUNT):
        template = JIKKYO_COMMENT_TEMPLATES[index % len(JIKKYO_COMMENT_TEMPLATES)]
        style = parse_comment_mail(template["mail"])
        comments.append({
            "time": round(step * (index + 1), 2),
            "type": style["type"],
            "size": style["size"],
            "color": style["color"],
            "author": JIKKYO_USER_IDS[index % len(JIKKYO_USER_IDS)],
            "text": template["content"],
        })
    return comments


# ---------------------------------------------------------------------------
# WebSocket (RFC 6455)
# ---------------------------------------------------------------------------

# RFC 6455 のハンドシェイクで使う固定 GUID
WS_GUID = "258EAFA5-E914-47DA-95CA-C5AB0DC85B11"


class WebSocketConnection:
    """Server side of one WebSocket connection (text frames only).

    Only what the jikkyo mock needs is implemented: the RFC 6455 handshake,
    masked client frames, continuation frames, ping/pong and close. Incoming
    text messages are pushed onto the messages queue by a reader thread so the
    session code can also do periodic work (pings, new comments) on its own
    thread.
    """

    OPCODE_CONTINUATION = 0x0
    OPCODE_TEXT = 0x1
    OPCODE_BINARY = 0x2
    OPCODE_CLOSE = 0x8
    OPCODE_PING = 0x9
    OPCODE_PONG = 0xA

    def __init__(self, handler) -> None:
        self.rfile = handler.rfile
        self.wfile = handler.wfile
        self.write_lock = threading.Lock()
        self.closed = False
        self.messages = queue.Queue()
        self.reader = threading.Thread(target=self._reader_loop, daemon=True)
        self.reader.start()

    # -- handshake ---------------------------------------------------------

    @staticmethod
    def accept_key(key: str) -> str:
        digest = hashlib.sha1((key + WS_GUID).encode("ascii")).digest()
        return base64.b64encode(digest).decode("ascii")

    @classmethod
    def upgrade(cls, handler):
        """Complete the handshake; returns None (and sends 400) on failure."""
        key = handler.headers.get("Sec-WebSocket-Key")
        upgrade = (handler.headers.get("Upgrade") or "").lower()
        if not key or upgrade != "websocket":
            handler._send_json({"detail": "Expected a WebSocket upgrade request"}, 400)
            return None

        accept = cls.accept_key(key.strip())
        # BaseHTTPRequestHandler の send_response() は HTTP/1.0 で書いてしまうので、
        # ハンドシェイクのレスポンスは直接書き込む。
        handler.wfile.write(
            (
                "HTTP/1.1 101 Switching Protocols\r\n"
                "Upgrade: websocket\r\n"
                "Connection: Upgrade\r\n"
                "Sec-WebSocket-Accept: " + accept + "\r\n"
                "\r\n"
            ).encode("ascii")
        )
        handler.wfile.flush()
        # ハンドラが戻ったらソケットを閉じる
        handler.close_connection = True
        return cls(handler)

    # -- receiving ---------------------------------------------------------

    def _read_exact(self, size: int) -> bytes:
        chunks = []
        remaining = size
        while remaining > 0:
            chunk = self.rfile.read(remaining)
            if not chunk:
                raise EOFError("socket closed")
            chunks.append(chunk)
            remaining -= len(chunk)
        return b"".join(chunks)

    def _read_frame(self):
        header = self._read_exact(2)
        first, second = header[0], header[1]
        fin = bool(first & 0x80)
        opcode = first & 0x0F
        masked = bool(second & 0x80)
        length = second & 0x7F
        if length == 126:
            length = struct.unpack(">H", self._read_exact(2))[0]
        elif length == 127:
            length = struct.unpack(">Q", self._read_exact(8))[0]
        mask = self._read_exact(4) if masked else b""
        payload = self._read_exact(length) if length else b""
        if masked and mask:
            payload = bytes(byte ^ mask[index % 4] for index, byte in enumerate(payload))
        return fin, opcode, payload

    def _reader_loop(self) -> None:
        buffered = bytearray()
        buffered_opcode = None
        try:
            while not self.closed:
                fin, opcode, payload = self._read_frame()
                if opcode == self.OPCODE_CLOSE:
                    break
                if opcode == self.OPCODE_PING:
                    self._send_frame(self.OPCODE_PONG, payload)
                    continue
                if opcode == self.OPCODE_PONG:
                    continue
                if opcode == self.OPCODE_CONTINUATION:
                    buffered.extend(payload)
                    if fin and buffered_opcode is not None:
                        self.messages.put(("text", buffered.decode("utf-8", "replace")))
                        buffered = bytearray()
                        buffered_opcode = None
                    continue
                if opcode in (self.OPCODE_TEXT, self.OPCODE_BINARY):
                    if fin:
                        self.messages.put(("text", payload.decode("utf-8", "replace")))
                    else:
                        buffered = bytearray(payload)
                        buffered_opcode = opcode
                    continue
        except (EOFError, OSError, ValueError):
            pass
        finally:
            self.closed = True
            self.messages.put(("close", ""))

    def next_message(self, timeout: float = 0.2):
        """Next ("text" | "close", payload) message, or None on timeout."""
        try:
            return self.messages.get(timeout=timeout)
        except queue.Empty:
            return None

    # -- sending -----------------------------------------------------------

    def _send_frame(self, opcode: int, payload: bytes = b"") -> bool:
        header = bytearray()
        header.append(0x80 | opcode)
        length = len(payload)
        if length < 126:
            header.append(length)
        elif length < 65536:
            header.append(126)
            header.extend(struct.pack(">H", length))
        else:
            header.append(127)
            header.extend(struct.pack(">Q", length))

        with self.write_lock:
            if self.closed:
                return False
            try:
                self.wfile.write(bytes(header) + payload)
                self.wfile.flush()
            except (BrokenPipeError, ConnectionResetError, OSError):
                self.closed = True
                return False
        return True

    def send_text(self, text: str) -> bool:
        return self._send_frame(self.OPCODE_TEXT, text.encode("utf-8"))

    def send_json(self, payload) -> bool:
        return self.send_text(json.dumps(payload, ensure_ascii=False))

    def send_ping(self, payload: bytes = b"jikkyo") -> bool:
        return self._send_frame(self.OPCODE_PING, payload)

    def close(self, code: int = 1000) -> None:
        if not self.closed:
            self._send_frame(self.OPCODE_CLOSE, struct.pack(">H", code))
        self.closed = True


def parse_thread_request(text: str):
    """Extract the thread object from a comment session request.

    The web client sends a JSON array of pings that wraps the thread request:
    [{"ping":{"content":"rs:0"}}, ..., {"thread":{...}}, ...].
    """
    try:
        payload = json.loads(text)
    except (TypeError, ValueError):
        return None
    if isinstance(payload, dict):
        entries = [payload]
    elif isinstance(payload, list):
        entries = payload
    else:
        return None
    for entry in entries:
        if isinstance(entry, dict) and isinstance(entry.get("thread"), dict):
            return entry["thread"]
    return None


# ---------------------------------------------------------------------------
# HTTP ハンドラ
# ---------------------------------------------------------------------------

class MockHandler(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.0"
    server_version = "KonomiTVMock/1.0"
    sys_version = ""

    # -- ログ (stdout へ) --------------------------------------------------

    def log_message(self, fmt: str, *args) -> None:
        # The time lines the log up with the app log CI streams from the
        # simulator (same clock, millisecond precision).
        try:
            now = datetime.now()
            stamp = now.strftime("%H:%M:%S.") + f"{now.microsecond // 1000:03d}"
            print(f"[mock] {stamp} {self.address_string()} {fmt % args}", flush=True)
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

    def _current_user(self, fixtures: dict) -> dict | None:
        """The account behind the bearer token, or None."""
        token = self._bearer_token()
        if not token:
            return None
        state = self.server.state  # type: ignore[attr-defined]
        user_id = state.access_tokens.get(token)
        if user_id is None:
            return None
        return next((user for user in state.users if user.get("id") == user_id), None)

    def _require_user(self, fixtures: dict) -> dict | None:
        """Log in check: returns the user, or sends 401 and returns None."""
        user = self._current_user(fixtures)
        if user is None:
            self._send_json({"detail": "Unauthorized"}, 401)
            return None
        return user

    def _optional_user(self, fixtures: dict) -> dict | None:
        """Optional login check: the user, or None when there is no valid token."""
        return self._current_user(fixtures)

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

        # ニコニコ実況の WebSocket (アプリはこの URL に直接接続する)
        if path.startswith("/__mock/jikkyo/watch/"):
            self._serve_jikkyo_watch(path[len("/__mock/jikkyo/watch/"):], state)
            return

        if path.startswith("/__mock/jikkyo/comment/"):
            self._serve_jikkyo_comment(path[len("/__mock/jikkyo/comment/"):], state)
            return

        # ニコニコ OAuth のモック認可ページ (すぐにコールバックへリダイレクトする)
        if path == "/__mock/niconico/authorize":
            self._handle_niconico_authorize(query)
            return

        # Twitter / Bluesky のツイート画像・アイコン (生成した PNG)
        if path.startswith("/__mock/twitter/"):
            if not twitter_mock.handle_mock_image(self, path):
                self._not_found()
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

        if len(parts) == 3 and parts[0] == "channels" and parts[2] == "jikkyo":
            self._handle_channel_jikkyo(parts[1], fixtures)
            return

        if parts == ["niconico", "auth"]:
            self._handle_niconico_auth(fixtures, state)
            return

        if parts == ["niconico", "callback"]:
            self._handle_niconico_callback(query, fixtures, state)
            return

        if parts[0] == "videos":
            self._handle_videos(parts, query, fixtures)
            return

        if parts[0] == "series":
            self._handle_series(parts, query, fixtures)
            return

        # Twitter / Bluesky (TwitterRouter / BlueskyRouter)
        if parts[0] in ("twitter", "bluesky"):
            if twitter_mock.handle(self, "GET", parts, query, fixtures, state):
                return

        # /api/users/me/account-links/{link_id} (DELETE のみ)
        if len(parts) == 4 and parts[:3] == ["users", "me", "account-links"]:
            if twitter_mock.handle(self, "GET", parts, query, fixtures, state):
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

        if parts == ["settings", "server"]:
            settings_mock.handle(self, "GET", parts, query, fixtures, state)
            return

        if parts and parts[0] == "maintenance":
            if not maintenance_mock.handle(self, "GET", parts, query, fixtures, state):
                self._not_found()
            return

        # アカウント (UsersRouter)
        if parts and parts[0] == "users":
            if not users_mock.handle(self, "GET", parts, query, fixtures, state):
                self._not_found()
            return

        # 録画予約・キーワード自動予約条件・録画設定プリセット (EDCB バックエンド専用 API)
        if parts and parts[0] == "recording":
            reservations_mock.handle(self, "GET", parts, query, fixtures, state)
            return

        if parts and parts[0] == "captures":
            captures_mock.handle(self, "GET", parts, query, fixtures, state)
            return

        if parts[0] == "streams" and len(parts) >= 2:
            # オフライン保存ストリーム (0.15+) は録画番組の HLS より先に処理する
            if (len(parts) == 5 and parts[1] == "video"
                    and parts[4] == "offline-stream"):
                offline_mock.handle(self, parts, query, fixtures, state)
                return
            if parts[1] == "video":
                self._handle_video_stream(parts, query, state, fixtures)
                return
            if parts[1] == "live":
                self._handle_live_stream(parts, state, fixtures)
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

        if parts == ["settings", "server"]:
            settings_mock.handle(self, "PUT", parts, query, fixtures, state)
            return

        if parts and parts[0] == "users":
            if not users_mock.handle(self, "PUT", parts, query, fixtures, state):
                self._not_found()
            return

        if parts and parts[0] in ("twitter", "bluesky"):
            if twitter_mock.handle(self, "PUT", parts, query, fixtures, state):
                return

        if parts and parts[0] == "recording":
            reservations_mock.handle(self, "PUT", parts, query, fixtures, state)
            return

        if parts and parts[0] == "captures":
            captures_mock.handle(self, "PUT", parts, query, fixtures, state)
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

        # UI テスト用: サーバーの機能を切り替える
        if split.path == "/__mock/config":
            self._handle_mock_config()
            return

        if parts and parts[0] in ("twitter", "bluesky"):
            state = self.server.state  # type: ignore[attr-defined]
            if twitter_mock.handle(self, "POST", parts, self._query(), fixtures, state):
                return

        if parts == ["users", "me", "account-links"]:
            state = self.server.state  # type: ignore[attr-defined]
            if twitter_mock.handle(self, "POST", parts, self._query(), fixtures, state):
                return

        if parts and parts[0] == "recording":
            state = self.server.state  # type: ignore[attr-defined]
            reservations_mock.handle(self, "POST", parts, self._query(), fixtures, state)
            return

        if parts and parts[0] == "captures":
            state = self.server.state  # type: ignore[attr-defined]
            captures_mock.handle(self, "POST", parts, self._query(), fixtures, state)
            return

        if parts and parts[0] == "users":
            state = self.server.state  # type: ignore[attr-defined]
            if not users_mock.handle(self, "POST", parts, self._query(), fixtures, state):
                self._not_found()
            return

        if parts and parts[0] == "maintenance":
            state = self.server.state  # type: ignore[attr-defined]
            if not maintenance_mock.handle(self, "POST", parts, self._query(), fixtures, state):
                self._not_found()
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

        # /api/niconico/logout: ニコニコアカウントとの連携を解除する
        if parts == ["niconico", "logout"]:
            self._handle_niconico_logout(fixtures, state)
            return

        # Twitter / Bluesky の連携解除とアカウント紐付け解除
        if parts and parts[0] in ("twitter", "bluesky"):
            if twitter_mock.handle(self, "DELETE", parts, self._query(), fixtures, state):
                return
        if len(parts) == 4 and parts[:3] == ["users", "me", "account-links"]:
            if twitter_mock.handle(self, "DELETE", parts, self._query(), fixtures, state):
                return

        if parts and parts[0] == "recording":
            reservations_mock.handle(self, "DELETE", parts, self._query(), fixtures, state)
            return

        if parts and parts[0] == "captures":
            captures_mock.handle(self, "DELETE", parts, self._query(), fixtures, state)
            return

        if parts and parts[0] == "users":
            if not users_mock.handle(self, "DELETE", parts, self._query(), fixtures, state):
                self._not_found()
            return

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

    def _handle_mock_config(self) -> None:
        """Change mock server behaviour.

        POST /__mock/config {"captures_library": false} makes the server behave
        like KonomiTV v0.14.1: every captures endpoint except the upload
        answers 404. {"offline_stream": false} does the same for the offline
        save stream (the route answers 404 and the app hides the feature), and
        {"offline_stream_truncate": true} drops the save stream after two
        segments without its terminator record.
        POST /__mock/reset restores the defaults.
        """
        state = self.server.state  # type: ignore[attr-defined]
        body = self._read_json_body()
        if "captures_library" in body:
            state.captures_library = bool(body["captures_library"])
        if "offline_stream" in body:
            state.offline_stream = bool(body["offline_stream"])
        if "offline_stream_truncate" in body:
            state.offline_stream_truncate = bool(body["offline_stream_truncate"])
        if "data_component" in body:
            state.data_component = bool(body["data_component"])
        self._send_json(
            {
                "status": "ok",
                "captures_library": state.captures_library,
                "offline_stream": state.offline_stream,
                "offline_stream_truncate": state.offline_stream_truncate,
                "data_component": state.data_component,
            }
        )

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
        users_mock.reset(server.state, fixtures["user"], MOCK_ACCESS_TOKEN)
        settings_mock.reset(server.state)
        maintenance_mock.reset(server.state)
        offline_mock.reset(server.state)
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
        # 810p / 540p と -hevc / -24fps / -10bit のサフィックスを受け付ける
        base_quality, _ = split_api_quality(quality)
        return base_quality in VALID_VIDEO_QUALITIES

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

        # /videos/{video_id}/jikkyo (過去ログコメント)
        if len(parts) == 3 and parts[2] == "jikkyo":
            self._handle_video_jikkyo(parts[1], fixtures)
            return

        # /videos/{video_id}/thumbnail/tiled (seek-bar tile sheet)
        if len(parts) == 4 and parts[2] == "thumbnail" and parts[3] == "tiled":
            if not self._video_exists(parts[1], fixtures):
                self._not_found()
                return
            self._send_bytes(
                TILED_THUMBNAIL_PNG, "image/png", cache="max-age=3600"
            )
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
        state = self.server.state  # type: ignore[attr-defined]
        with state.lock:
            state.program_search_count += 1
            state.last_program_search_condition = copy.deepcopy(condition)
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
        date_ranges = condition.get("date_ranges") or []
        is_exclude_date_ranges = bool(condition.get("is_exclude_date_ranges", False))

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

            # 放送日時範囲: 開始曜日・時刻から終了曜日・時刻まで (曜日は 0=日曜日)
            if date_ranges:
                start_time = datetime.fromisoformat(program["start_time"])
                matched = any(
                    _matches_date_range(start_time, date_range)
                    for date_range in date_ranges
                )
                if matched == is_exclude_date_ranges:
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

        state.record_video_quality(quality)

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
            state.record_video_quality(quality, playlist_type)
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
            body = caption_injected_segment(sequence)
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
        """Master playlist with a 主音声 / 副音声 audio group.

        Same shape as VideoStreamsRouter.py: the audio group is declared with
        EXT-X-MEDIA so AVPlayer shows both tracks natively, and the variant
        points at the primary-audio media playlist. CODECS / RESOLUTION are not
        declared, like the real server.
        """
        base_quality, _ = split_api_quality(quality)
        video_kbps, audio_kbps = QUALITY_BITRATES.get(base_quality, (8000, 192))
        # MPEG-TS の多重化オーバーヘッドを10%見込み、映像と2本分の音声を収容できる帯域幅
        bandwidth = round((video_kbps * 1000 + audio_kbps * 1000 * 2) * 1.1)
        playlist_uri = f"playlist?session_id={quote(session_id, safe='')}"
        return (
            "#EXTM3U\n"
            "#EXT-X-VERSION:6\n"
            '#EXT-X-MEDIA:TYPE=AUDIO,GROUP-ID="audio",NAME="主音声",'
            'DEFAULT=YES,AUTOSELECT=YES,LANGUAGE="jpn"\n'
            '#EXT-X-MEDIA:TYPE=AUDIO,GROUP-ID="audio",NAME="副音声",'
            f'DEFAULT=NO,AUTOSELECT=YES,LANGUAGE="jpn",URI="{playlist_uri}&type=secondary-audio"\n'
            f'#EXT-X-STREAM-INF:BANDWIDTH={bandwidth},AUDIO="audio"\n'
            f"{playlist_uri}&type=primary-audio\n"
        )

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

        6 本のセグメント (各 2 秒) を 10 回繰り返す。録画ビデオの再生時間を
        バックグラウンド再生・PiP を観察できる長さにするため。繰り返しごとに
        セグメントのタイムスタンプをずらして連続させる
        (caption_injected_segment) ので、#EXT-X-DISCONTINUITY は入れない。
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
            lines.append(entries[sequence % len(entries)])
            lines.append(
                f"segment?session_id={escaped_session}&sequence={sequence}"
            )
        lines.append("#EXT-X-ENDLIST")
        return "\n".join(lines) + "\n"

    def _handle_live_stream(self, parts: list[str], state: MockServerState,
                            fixtures: dict) -> None:
        # /streams/live/{display_channel_id}/{quality}/{mpegts|events}
        if len(parts) != 5 or parts[0] != "streams" or parts[1] != "live":
            self._not_found()
            return
        display_channel_id, quality, action = parts[2], parts[3], parts[4]
        if action not in ("mpegts", "events", "psi-archived-data"):
            self._not_found()
            return

        channels = fixtures["channels"]
        known = any(
            c["display_channel_id"] == display_channel_id or c["id"] == display_channel_id
            for channel_list in channels.values()
            for c in channel_list
        )
        if not known:
            self._not_found()
            return
        if not self._valid_live_quality(quality):
            self._unprocessable()
            return

        state.record_live_quality(quality)

        if action == "events":
            self._serve_live_events(state)
            return

        if action == "psi-archived-data":
            self._serve_psi_archived_data(
                state, fixtures, display_channel_id, quality,
            )
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

    # -- ライブ PSI/SI アーカイブデータ (データ放送) -------------------------

    def _serve_psi_archived_data(self, state: MockServerState, fixtures: dict,
                                 display_channel_id: str, quality: str) -> None:
        """Live PSI/SI archived data stream (psisiarc).

        Mirrors LiveStreamsRouter.LivePSIArchivedDataAPI: an endless
        application/octet-stream response of psisiarc chunks with the
        channel's PAT / PMT / SDT / EIT[p/f] / TOT. With the data_component
        switch the PMT advertises a BML data component (there is no DSM-CC
        carousel behind it, so the app stays in its loading state).
        """
        channel = find_channel(fixtures["channels"], display_channel_id)
        if channel is None:
            self._not_found()
            return
        state.record_psi_archived_data(display_channel_id, quality)
        include_data_component = bool(state.snapshot()["data_component"])

        self.send_response(200)
        self.send_header("Content-Type", "application/octet-stream")
        self.send_header("Cache-Control", "no-store")
        self.send_header("Connection", "close")
        self.end_headers()
        try:
            for chunk in data_broadcasting.iter_psi_archived_data(
                channel, include_data_component
            ):
                self.wfile.write(chunk)
                self.wfile.flush()
                if self._client_disconnected():
                    return
        except (BrokenPipeError, ConnectionResetError, OSError):
            pass

    # -- ライブストリーム イベント (Server-Sent Events) ---------------------

    @staticmethod
    def _valid_live_quality(quality: str) -> bool:
        if quality == "original":
            return True
        base_quality, _ = split_api_quality(quality)
        return base_quality in VALID_VIDEO_QUALITIES

    @staticmethod
    def _live_status_payload(status: str, detail: str, started_at: float,
                             updated_at: float, client_count: int) -> str:
        """JSON body of a live stream status event (schemas.LiveStreamStatus)."""
        return json.dumps({
            "status": status,
            "detail": detail,
            "started_at": started_at,
            "updated_at": updated_at,
            "client_count": client_count,
        }, ensure_ascii=False)

    def _serve_live_events(self, state: MockServerState) -> None:
        """Live stream event stream (text/event-stream).

        Mirrors LiveStreamsRouter.LiveStreamEventAPI: an initial_update event on
        connect, then status_update when the status changes, detail_update when
        only the detail changes and clients_update when only the viewer count
        changes. The real server only writes when something changed and relies
        on sse_starlette's periodic ping comment, so this mock sends a comment
        ping every few seconds to keep the connection alive.
        """
        self.send_response(200)
        self.send_header("Content-Type", "text/event-stream; charset=utf-8")
        self.send_header("Cache-Control", "no-store")
        self.send_header("X-Accel-Buffering", "no")
        self.send_header("Connection", "close")
        self.end_headers()

        def write(payload: str) -> None:
            self.wfile.write(payload.encode("utf-8"))
            self.wfile.flush()

        def write_event(name: str, body: str) -> None:
            write(f"event: {name}\ndata: {body}\n\n")

        started_at = time.time()
        state.live_connected()
        try:
            client_count = state.snapshot()["live_active"]
            # 初回接続時は必ず現在のステータスを返す
            write_event("initial_update", self._live_status_payload(
                "Standby", "エンコードタスクを起動しています…",
                started_at, started_at, client_count,
            ))

            # エンコードタスクが立ち上がるまでの待ちを再現する
            if self._sleep_until_disconnected(LIVE_EVENTS_STANDBY_SECONDS):
                return
            now = time.time()
            write_event("status_update", self._live_status_payload(
                "ONAir", "ライブストリームは ONAir です。",
                started_at, now, max(client_count, 1),
            ))

            # 以降は視聴者数の変化と keep-alive のコメントだけを流す
            tick = 0
            while True:
                if self._sleep_until_disconnected(LIVE_EVENTS_UPDATE_INTERVAL):
                    return
                tick += 1
                if tick % LIVE_EVENTS_PING_INTERVAL_TICKS == 0:
                    write(": keep-alive\n\n")
                now = time.time()
                viewers = max(state.snapshot()["live_active"], 1)
                write_event("clients_update", self._live_status_payload(
                    "ONAir", "ライブストリームは ONAir です。",
                    started_at, now, viewers,
                ))
        except (BrokenPipeError, ConnectionResetError, OSError):
            pass
        finally:
            state.live_disconnected()

    def _sleep_until_disconnected(self, seconds: float) -> bool:
        """Sleep in small steps; returns True when the client went away."""
        deadline = time.monotonic() + seconds
        while time.monotonic() < deadline:
            if self._client_disconnected():
                return True
            time.sleep(min(0.05, max(deadline - time.monotonic(), 0)))
        return self._client_disconnected()

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
        """Stream the sample over and over as one live broadcast.

        Each repetition has its PCR / PTS / DTS and continuity counters moved
        past the previous one, so the stream's clock keeps running like a
        real broadcast instead of jumping back every 12 s.
        """
        bytes_per_second = max(len(sample) / LIVE_DURATION_SECONDS, 1.0)
        loop_ticks = ts_timestamps.loop_length_ticks(sample)
        loop_counts = ts_timestamps.continuity_counts(sample)
        repetition = 0
        current = sample
        offset = 0
        started = time.monotonic()
        bytes_sent = 0
        while True:
            if self._client_disconnected():
                return
            chunk = current[offset:offset + STREAM_CHUNK_SIZE]
            if not chunk:
                offset = 0
                repetition += 1
                current = ts_timestamps.repeat(sample, repetition, loop_ticks, loop_counts)
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

    # -- ニコニコ実況 (REST) ------------------------------------------------

    def _http_base_url(self) -> str:
        port = self.server.server_address[1]
        return "http://127.0.0.1:" + str(port)

    def _ws_base_url(self) -> str:
        port = self.server.server_address[1]
        return "ws://127.0.0.1:" + str(port)

    def _handle_channel_jikkyo(self, channel_id: str, fixtures: dict) -> None:
        """チャンネルのニコニコ実況 WebSocket URL (schemas.JikkyoWebSocketInfo).

        実サーバーと同じく、ログイン中 (Authorization ヘッダーあり) でも
        Nicolive の視聴セッションは返さない。アプリは常に NX-Jikkyo を使う。
        """
        channel = find_channel(fixtures["channels"], channel_id)
        if channel is None:
            self._unprocessable("Specified display_channel_id was not found")
            return

        base = self._ws_base_url()
        self._send_json({
            "watch_session_url": base + "/__mock/jikkyo/watch/" + channel_id,
            "nicolive_watch_session_url": None,
            "nicolive_watch_session_error": None,
            "comment_session_url": base + "/__mock/jikkyo/comment/" + channel_id,
            "is_nxjikkyo_exclusive": False,
        })

    def _handle_video_jikkyo(self, video_id: str, fixtures: dict) -> None:
        """録画番組の過去ログコメント (schemas.JikkyoComments)."""
        try:
            wanted = int(video_id)
        except (TypeError, ValueError):
            self._not_found()
            return

        for program in fixtures["videos"]:
            if program.get("id") != wanted:
                continue
            recorded_video = program.get("recorded_video") or {}
            duration = recorded_video.get("duration") or program.get("duration") or 0
            self._send_json({
                "is_success": True,
                "comments": build_jikkyo_past_comments(float(duration)),
                "detail": "Success",
            })
            return

        self._not_found()

    # -- ニコニコ実況 (視聴セッション WebSocket) ------------------------------

    def _serve_jikkyo_watch(self, channel_id: str, state: MockServerState) -> None:
        socket_connection = WebSocketConnection.upgrade(self)
        if socket_connection is None:
            return

        state.jikkyo_watch_connected()
        try:
            self._run_jikkyo_watch_session(socket_connection, channel_id, state)
        finally:
            socket_connection.close()
            state.jikkyo_watch_disconnected()

    def _run_jikkyo_watch_session(self, socket_connection: WebSocketConnection,
                                  channel_id: str, state: MockServerState) -> None:
        """Watch session: startWatching -> seat + room, keepSeat, postComment."""
        base_time = datetime.now(JST)
        thread_id = jikkyo_thread_id(channel_id)
        last_ping = time.monotonic()
        posted_index = 0

        while not socket_connection.closed:
            message = socket_connection.next_message(timeout=0.2)
            if message is not None:
                kind, text = message
                if kind == "close":
                    return
                try:
                    payload = json.loads(text)
                except (TypeError, ValueError):
                    payload = None
                if not isinstance(payload, dict):
                    continue

                message_type = payload.get("type")
                data = payload.get("data")
                if not isinstance(data, dict):
                    data = {}

                if message_type == "startWatching":
                    # 実際の NX-Jikkyo は seat → room の順で送ってくる
                    socket_connection.send_json({
                        "type": "seat",
                        "data": {
                            "keepIntervalSec": JIKKYO_SEAT_KEEP_INTERVAL_SEC,
                            "seatId": "mock-seat",
                        },
                    })
                    socket_connection.send_json({
                        "type": "room",
                        "data": {
                            "vposBaseTime": isoformat(base_time),
                            "threadId": thread_id,
                            "messageServer": {
                                "uri": self._ws_base_url() + "/__mock/jikkyo/comment/" + channel_id,
                                "type": "websocket",
                            },
                            "yourPostKey": JIKKYO_MOCK_USER_KEY,
                            "roomId": channel_id,
                        },
                    })
                elif message_type == "keepSeat":
                    state.record_jikkyo_keep_seat()
                elif message_type == "pong":
                    # ping への応答。何もしなくてよい
                    pass
                elif message_type == "postComment":
                    posted_index += 1
                    content = str(data.get("text") or "")
                    state.record_jikkyo_post(content)
                    mail_parts = ["184"]
                    for key in ("position", "size", "color"):
                        value = data.get(key)
                        if isinstance(value, str) and value:
                            mail_parts.append(value)
                    chat = build_jikkyo_chat(
                        channel_id,
                        posted_index,
                        int(data.get("vpos") or 0),
                        time.time(),
                        number=5000 + posted_index,
                        mail=" ".join(mail_parts),
                        content=content,
                        user_id=JIKKYO_MOCK_USER_KEY,
                        your_post=1,
                    )
                    # 投稿できたことを知らせる (実サーバーも chat を返す)
                    socket_connection.send_json({
                        "type": "postCommentResult",
                        "data": {"chat": chat},
                    })
                    # 同じチャンネルのコメントセッションにも流す
                    state.broadcast_jikkyo_chat(channel_id, {"chat": chat})

            now = time.monotonic()
            if now - last_ping >= JIKKYO_WATCH_PING_INTERVAL:
                if not socket_connection.send_ping():
                    return
                last_ping = now

    # -- ニコニコ実況 (コメントセッション WebSocket) --------------------------

    def _serve_jikkyo_comment(self, channel_id: str, state: MockServerState) -> None:
        socket_connection = WebSocketConnection.upgrade(self)
        if socket_connection is None:
            return

        state.jikkyo_comment_connected(channel_id, socket_connection)
        try:
            self._run_jikkyo_comment_session(socket_connection, channel_id)
        finally:
            socket_connection.close()
            state.jikkyo_comment_disconnected(channel_id, socket_connection)

    def _run_jikkyo_comment_session(self, socket_connection: WebSocketConnection,
                                    channel_id: str) -> None:
        """Comment session: thread request -> thread + past chats + rf:0, then
        one new chat every JIKKYO_COMMENT_INTERVAL seconds."""
        thread_id = jikkyo_thread_id(channel_id)

        # スレッドリクエスト (ping に包まれた thread) を待つ
        deadline = time.monotonic() + JIKKYO_THREAD_REQUEST_TIMEOUT
        while not socket_connection.closed and time.monotonic() < deadline:
            message = socket_connection.next_message(timeout=0.1)
            if message is None:
                continue
            kind, text = message
            if kind == "close":
                return
            thread = parse_thread_request(text)
            if thread is not None:
                requested = thread.get("thread")
                if isinstance(requested, str) and requested:
                    thread_id = requested
                break

        socket_connection.send_json({
            "thread": {
                "resultcode": 0,
                "thread": thread_id,
                "revision": 1,
                "server_time": int(time.time()),
                "last_res": 4000,
                "ticket": "mock-ticket",
                "comment_count": 0,
            },
        })

        # 接続直後にまとめて過去コメントを送る (実サーバーも res_from=-100 で送る)
        now = time.time()
        for index in range(JIKKYO_INITIAL_COMMENT_COUNT):
            socket_connection.send_json({
                "chat": build_jikkyo_chat(
                    channel_id,
                    index,
                    index * 300,
                    now - (JIKKYO_INITIAL_COMMENT_COUNT - index) * 3,
                ),
            })
        # rf:0 で過去コメントの送信が完了したことを伝える
        socket_connection.send_json({"ping": {"content": "rf:0"}})

        # 以降は新着コメントを 1 秒ごとに流し続ける
        index = JIKKYO_INITIAL_COMMENT_COUNT
        started = time.time()
        next_send = time.monotonic() + JIKKYO_COMMENT_INTERVAL
        while not socket_connection.closed:
            message = socket_connection.next_message(timeout=0.05)
            if message is not None and message[0] == "close":
                return

            current = time.monotonic()
            if current < next_send:
                continue
            index += 1
            vpos = int((time.time() - started) * 100) + index * 300
            if not socket_connection.send_json({
                "chat": build_jikkyo_chat(channel_id, index, vpos, time.time()),
            }):
                return
            next_send = current + JIKKYO_COMMENT_INTERVAL

    # -- ニコニコ OAuth -----------------------------------------------------

    @staticmethod
    def _encode_oauth_state(payload: dict) -> str:
        encoded = base64.b64encode(
            json.dumps(payload, ensure_ascii=False).encode("utf-8")
        ).decode("ascii")
        # 実サーバーと同じく、末尾の = はリダイレクト時に URL エンコードされるので削除する
        return encoded.replace("=", "")

    @staticmethod
    def _decode_oauth_state(value: str) -> dict:
        padded = value + "=" * (-len(value) % 4)
        try:
            decoded = base64.b64decode(padded).decode("utf-8")
            payload = json.loads(decoded)
        except (ValueError, TypeError, UnicodeDecodeError):
            return {}
        return payload if isinstance(payload, dict) else {}

    def _handle_niconico_auth(self, fixtures: dict, state: MockServerState) -> None:
        """GET /api/niconico/auth: authorization URL issuing API."""
        if self._require_user(fixtures) is None:
            return

        state.record_niconico_authorize()

        # 実サーバーは Origin ヘッダーからクライアント URL を決める
        client_url = (self.headers.get("Origin") or "").rstrip("/")
        if client_url:
            client_url += "/"
        else:
            client_url = self._http_base_url() + "/"

        oauth_state = self._encode_oauth_state({
            "server": self._http_base_url() + "/",
            "client": client_url,
            "user_access_token": self._bearer_token(),
        })
        self._send_json({
            "authorization_url": (
                self._http_base_url() + "/__mock/niconico/authorize"
                "?response_type=code"
                "&scope=offline_access%20openid%20profile%20user.premium"
                "&client_id=mock-niconico-client"
                "&redirect_uri=https://app.konomi.tv/api/redirect/niconico"
                # state は base64 なので + / = を含みうる。クエリ文字列として安全に渡すため
                # パーセントエンコードしておく (parse_qs 側でデコードされる)
                "&state=" + quote(oauth_state, safe="")
            ),
        })

    def _handle_niconico_authorize(self, query: dict) -> None:
        """Mock authorization page: redirects straight to the callback.

        The real Niconico page asks the user for permission and then redirects
        to https://app.konomi.tv/api/redirect/niconico, which forwards to
        {server}/api/niconico/callback?client=..&user_access_token=..&code=..
        """
        oauth_state = self._decode_oauth_state((query.get("state") or [""])[0])
        client_url = str(oauth_state.get("client") or (self._http_base_url() + "/"))
        user_access_token = str(oauth_state.get("user_access_token") or "")

        location = (
            "/api/niconico/callback"
            "?client=" + quote(client_url, safe="")
            + "&user_access_token=" + quote(user_access_token, safe="")
        )
        # ?deny=1 でユーザーが連携を拒否したケースを再現できる
        if (query.get("deny") or [""])[0]:
            location += "&error=access_denied"
        else:
            location += "&code=mock-authorization-code"

        self._send_bytes(
            b"", "text/plain; charset=utf-8", status=302,
            extra_headers={"Location": location},
        )

    def _handle_niconico_callback(self, query: dict, fixtures: dict,
                                  state: MockServerState) -> None:
        """GET /api/niconico/callback: links the Niconico account."""
        client_url = (query.get("client") or [""])[0] or (self._http_base_url() + "/")
        redirect_to = client_url.rstrip("/") + "/settings/jikkyo"
        user_access_token = (query.get("user_access_token") or [""])[0]
        error = (query.get("error") or [None])[0]
        code = (query.get("code") or [None])[0]

        if error is not None:
            self._send_oauth_callback_html(
                status=401,
                detail="Authorization was denied (" + error + ")",
                redirect_to=redirect_to,
            )
            return

        if code is None:
            self._send_oauth_callback_html(
                status=500,
                detail="Authorization code does not exist",
                redirect_to=redirect_to,
            )
            return

        user_id = state.access_tokens.get(user_access_token)
        user = next(
            (entry for entry in state.users if entry.get("id") == user_id),
            None,
        )
        if user is None:
            self._send_oauth_callback_html(
                status=401,
                detail="Unauthorized",
                redirect_to=redirect_to,
            )
            return

        user["niconico_user_id"] = MOCK_NICONICO_USER_ID
        user["niconico_user_name"] = MOCK_NICONICO_USER_NAME
        user["niconico_user_premium"] = MOCK_NICONICO_USER_PREMIUM
        state.record_niconico_link()

        self._send_oauth_callback_html(
            status=200, detail="Success", redirect_to=redirect_to
        )

    def _handle_niconico_logout(self, fixtures: dict, state: MockServerState) -> None:
        """DELETE /api/niconico/logout: unlinks the Niconico account."""
        user = self._require_user(fixtures)
        if user is None:
            return

        user["niconico_user_id"] = None
        user["niconico_user_name"] = None
        user["niconico_user_premium"] = None
        state.record_niconico_unlink()

        self.send_response(204)
        self.send_header("Content-Length", "0")
        self.end_headers()

    def _send_oauth_callback_html(self, status: int, detail: str,
                                  redirect_to: str) -> None:
        """Mirror of OAuthCallbackResponse: HTML that forwards the result.

        A popup gets a postMessage, a redirect (mobile) gets the result in the
        URL hash of the client's redirect URL.
        """
        callback_data = json.dumps(
            {"status": status, "detail": detail},
            ensure_ascii=False,
            separators=(",", ":"),
        ).replace("<", "\\u003C").replace(">", "\\u003E").replace("&", "\\u0026")
        redirect_json = json.dumps(redirect_to, ensure_ascii=False)
        target_origin = json.dumps(self._http_base_url())
        html = (
            "<!DOCTYPE html>\n"
            "<html lang=\"ja\">\n"
            "<head><meta charset=\"utf-8\">\n"
            "<script>\n"
            "window.onload = () => {\n"
            "    if (window.opener) {\n"
            "        window.opener.postMessage({'KonomiTV-OAuthPopup': " + callback_data + "}, " + target_origin + ");\n"
            "    } else {\n"
            "        const callbackData = " + callback_data + ";\n"
            "        const redirectURL = new URL(" + redirect_json + ");\n"
            "        redirectURL.hash = new URLSearchParams(callbackData).toString();\n"
            "        location.href = redirectURL.toString();\n"
            "    }\n"
            "};\n"
            "</script>\n"
            "<body>KonomiTV Niconico OAuth (" + str(status) + ")</body>\n"
            "</html>\n"
        )
        self._send_bytes(html.encode("utf-8"), "text/html; charset=utf-8", status=status)

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
    users_mock.reset(server.state, server.fixtures["user"], MOCK_ACCESS_TOKEN)  # type: ignore[attr-defined]
    settings_mock.reset(server.state)  # type: ignore[attr-defined]
    maintenance_mock.reset(server.state)  # type: ignore[attr-defined]
    offline_mock.reset(server.state)  # type: ignore[attr-defined]
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
