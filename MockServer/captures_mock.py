"""In-memory capture library for the mock KonomiTV server.

Implements the CapturesRouter of KonomiTV v0.15+ (list / upload / delete /
sections / channels / programs / tags / favorites / tag items / detail / image)
with Python's standard library only, plus the KonomiTV v0.14.1 mode where only
the upload endpoint exists.

The handler integration lives in mock_server.MockHandler; this module owns the
fixtures and the endpoint logic so mock_server.py stays readable.
"""

from __future__ import annotations

import base64
import hashlib
import json
import re
import struct
import zlib
from datetime import date as Date
from datetime import datetime, timedelta, timezone

JST = timezone(timedelta(hours=9))

CAPTURE_JPEG = "image/jpeg"
CAPTURE_PNG = "image/png"
MAX_UPLOAD_SIZE = 50 * 1024 * 1024

INVALID_FILENAME_CHARS = re.compile(r'[<>"|?*\x01-\x1f]')


# ---------------------------------------------------------------------------
# PNG generation (stdlib only)
# ---------------------------------------------------------------------------

def _png_chunk(kind: bytes, data: bytes) -> bytes:
    payload = kind + data
    return (
        struct.pack(">I", len(data))
        + payload
        + struct.pack(">I", zlib.crc32(payload) & 0xFFFFFFFF)
    )


def build_capture_png(seed: int, width: int = 160, height: int = 90) -> bytes:
    """Build a small valid RGB PNG with a deterministic gradient."""
    base = (
        (180 + seed * 37) % 256,
        (90 + seed * 73) % 256,
        (120 + seed * 19) % 256,
    )
    raw = bytearray()
    for y in range(height):
        raw.append(0)  # filter: none
        for x in range(width):
            shade = (x * 40 // width + y * 30 // height) % 60
            raw.extend(
                (
                    (base[0] + shade) % 256,
                    (base[1] + shade // 2) % 256,
                    (base[2] + shade) % 256,
                )
            )
    header = struct.pack(">IIBBBBB", width, height, 8, 2, 0, 0, 0)
    return (
        b"\x89PNG\r\n\x1a\n"
        + _png_chunk(b"IHDR", header)
        + _png_chunk(b"IDAT", zlib.compress(bytes(raw), 9))
        + _png_chunk(b"IEND", b"")
    )


def image_dimensions(data: bytes) -> tuple[int, int]:
    """Read the dimensions of a PNG or use a sane default for a JPEG."""
    if data.startswith(b"\x89PNG\r\n\x1a\n") and len(data) >= 24:
        width, height = struct.unpack(">II", data[16:24])
        return int(width), int(height)
    # Parsing JPEG SOF markers is not needed by the app; a plausible size is
    # enough for the mock.
    return 1920, 1080


# ---------------------------------------------------------------------------
# EXIF reading (stdlib only)
# ---------------------------------------------------------------------------

# TIFF の型ごとのバイト数 (BYTE/ASCII/SBYTE/UNDEFINED は 1、SHORT/SSHORT は 2、LONG 系は 4、RATIONAL 系は 8)
_EXIF_TYPE_SIZES = {1: 1, 2: 1, 3: 2, 4: 4, 5: 8, 6: 1, 7: 1, 8: 2, 9: 4, 10: 8, 11: 4, 12: 8}


def _exif_tiff(data: bytes) -> bytes | None:
    """JPEG の APP1 Exif セグメントから TIFF ブロックを取り出す (見つからなければ None)。"""
    if not data.startswith(b"\xff\xd8"):
        return None
    index = 2
    size = len(data)
    while index + 3 < size:
        if data[index] != 0xFF:
            return None
        marker = data[index + 1]
        if marker in (0xDA, 0xD9):
            return None
        if marker == 0xFF:
            index += 1
            continue
        if marker == 0xD8 or marker == 0x01 or 0xD0 <= marker <= 0xD7:
            index += 2
            continue
        length = int.from_bytes(data[index + 2:index + 4], "big")
        if length < 2:
            return None
        start = index + 4
        end = index + 2 + length
        if end > size:
            return None
        if marker == 0xE1 and data[start:start + 6] == b"Exif\x00\x00":
            return data[start + 6:end]
        index = end
    return None


def _read_exif_ifd(tiff: bytes, offset: int, byte_order: str) -> dict[int, bytes]:
    """1 つの IFD を読み、タグ番号から生の値への辞書を返す。"""
    entries: dict[int, bytes] = {}
    if offset < 0 or offset + 2 > len(tiff):
        return entries
    count = int.from_bytes(tiff[offset:offset + 2], byte_order)
    for position in range(count):
        base = offset + 2 + position * 12
        if base + 12 > len(tiff):
            break
        tag = int.from_bytes(tiff[base:base + 2], byte_order)
        kind = int.from_bytes(tiff[base + 2:base + 4], byte_order)
        value_count = int.from_bytes(tiff[base + 4:base + 8], byte_order)
        length = _EXIF_TYPE_SIZES.get(kind, 1) * value_count
        if length <= 4:
            entries[tag] = tiff[base + 8:base + 8 + length]
            continue
        value_offset = int.from_bytes(tiff[base + 8:base + 12], byte_order)
        if value_offset < 0 or value_offset + length > len(tiff):
            continue
        entries[tag] = tiff[value_offset:value_offset + length]
    return entries


def read_capture_exif(data: bytes) -> tuple[dict | None, str | None]:
    """キャプチャ画像の EXIF から、番組情報 (XPComment) と撮影日時を読み出す。

    Returns:
        tuple[dict | None, str | None]: XPComment の JSON と DateTimeOriginal
            (EXIF 形式の文字列) 。読めなければ None 。
    """
    tiff = _exif_tiff(data)
    if tiff is None or len(tiff) < 8:
        return None, None
    if tiff[0:2] == b"II":
        byte_order = "little"
    elif tiff[0:2] == b"MM":
        byte_order = "big"
    else:
        return None, None

    ifd0 = _read_exif_ifd(tiff, int.from_bytes(tiff[4:8], byte_order), byte_order)

    metadata: dict | None = None
    raw_comment = ifd0.get(40092)
    if raw_comment:
        try:
            parsed = json.loads(raw_comment.decode("utf-16-le").rstrip("\x00"))
            if isinstance(parsed, dict):
                metadata = parsed
        except (UnicodeDecodeError, ValueError):
            metadata = None

    date_time_original: str | None = None
    exif_pointer = ifd0.get(34665)
    if exif_pointer and len(exif_pointer) >= 4:
        exif_ifd = _read_exif_ifd(
            tiff,
            int.from_bytes(exif_pointer[:4], byte_order),
            byte_order,
        )
        raw_datetime = exif_ifd.get(36867)
        if raw_datetime:
            date_time_original = raw_datetime.decode("ascii", "replace").rstrip("\x00")

    return metadata, date_time_original


def match_capture_program(fixtures: dict, metadata: dict | None) -> int | None:
    """XPComment の番組キー (network_id / service_id / event_id) に一致する放送回の ID 。"""
    if not metadata:
        return None
    keys = []
    for name in ("network_id", "service_id", "event_id"):
        value = metadata.get(name)
        if not isinstance(value, int) or isinstance(value, bool) or value < 0:
            return None
        keys.append(value)
    for program in fixtures["capture_programs"]:
        if (
            program["network_id"],
            program["service_id"],
            program["event_id"],
        ) == tuple(keys):
            return program["id"]
    return None



# ---------------------------------------------------------------------------
# Fixtures
# ---------------------------------------------------------------------------

def _iso(dt: datetime) -> str:
    return dt.isoformat()


def _program_from_video(video: dict, program_id: int, videos: list[dict]) -> dict:
    channel = video.get("channel") or {}
    recorded_ids = [
        other["id"]
        for other in videos
        if (
            other.get("network_id") == video.get("network_id")
            and other.get("service_id") == video.get("service_id")
            and other.get("event_id") == video.get("event_id")
            and other.get("start_time") == video.get("start_time")
        )
    ]
    return {
        "id": program_id,
        "network_id": video["network_id"],
        "service_id": video["service_id"],
        "event_id": video["event_id"],
        "start_time": video["start_time"],
        "end_time": video.get("end_time"),
        "duration": video.get("duration"),
        "title": video.get("title", ""),
        "description": video.get("description", ""),
        "channel_id": channel.get("id"),
        "recorded_program_ids": recorded_ids,
    }


def build_fixtures(videos: list[dict], channels: dict) -> dict:
    """Build capture fixtures consistent with the existing channels/videos."""
    programs = [
        _program_from_video(videos[index], index + 1, videos)
        for index in range(min(4, len(videos)))
    ]

    # (capture_id, program_id, captured_at, playback_position, caption_text,
    #  caption_composited, comment_composited, metadata_status)
    definitions = [
        (1, 1, "2026-11-03T20:01:05+09:00", 65.0, "今日のニュースです", True, False, "Parsed"),
        (2, 1, "2026-11-03T20:05:30+09:00", 330.0, "政府は新しい対策を発表しました", True, False, "Parsed"),
        (3, 1, "2026-11-03T20:15:00+09:00", 900.0, None, False, True, "Parsed"),
        (4, 1, "2026-11-03T20:30:45+09:00", 1845.0, "明日の天気です", True, True, "Parsed"),
        (5, 2, "2026-11-02T20:02:10+09:00", 130.0, "特集の始まりです", True, False, "Parsed"),
        (6, 2, "2026-11-02T20:20:00+09:00", 1200.0, None, False, False, "Parsed"),
        (7, 2, "2026-11-02T20:45:00+09:00", None, "解説します", True, False, "Parsed"),
        (8, 3, "2026-11-01T20:03:00+09:00", 180.0, "BSのニュースです", True, False, "Parsed"),
        (9, 3, "2026-11-01T20:40:00+09:00", 2400.0, None, False, True, "Parsed"),
        # A local upload style capture without program metadata.
        (10, None, "2026-11-03T22:10:00+09:00", None, None, False, False, "NoMetadata"),
    ]

    captures: list[dict] = []
    files: dict[int, list[dict]] = {}
    images: dict[int, bytes] = {}
    for index, definition in enumerate(definitions):
        (
            capture_id,
            program_id,
            captured_at,
            playback_position,
            caption_text,
            is_caption_composited,
            is_comment_composited,
            metadata_status,
        ) = definition
        program = next((p for p in programs if p["id"] == program_id), None)
        image = build_capture_png(index + 1)
        file_hash = hashlib.sha256(image).hexdigest()
        stamp = captured_at[0:19].replace("-", "").replace(":", "").replace("T", "-")
        file_name = f"Capture_{stamp}.jpg"
        captures.append(
            {
                "id": capture_id,
                "file_hash": file_hash,
                "file_size": len(image),
                "captured_at": captured_at,
                "broadcast_at": program["start_time"] if program else None,
                "image_width": 160,
                "image_height": 90,
                "metadata_status": metadata_status,
                "playback_position": playback_position,
                "caption_text": caption_text,
                "is_caption_composited": is_caption_composited,
                "is_comment_composited": is_comment_composited,
                "capture_program_id": program_id,
            }
        )
        files[capture_id] = [
            {
                "file_name": file_name,
                "file_path": f"/captures/{file_name}",
                "status": "Available",
            }
        ]
        images[capture_id] = image

    tags = [
        {
            "id": 1,
            "name": "お気に入り",
            "created_at": "2026-11-01T10:00:00+09:00",
            "updated_at": "2026-11-01T10:00:00+09:00",
        },
        {
            "id": 2,
            "name": "名場面",
            "created_at": "2026-11-02T11:00:00+09:00",
            "updated_at": "2026-11-02T11:00:00+09:00",
        },
    ]

    return {
        "captures": captures,
        "capture_programs": programs,
        "capture_files": files,
        "capture_images": images,
        "capture_tags": tags,
        "capture_favorites": {1, 4, 8},
        "capture_tag_items": {1: {1, 4, 8}, 2: {1, 5, 9}},
        "capture_channels": channels,
    }


# ---------------------------------------------------------------------------
# Serialisation helpers
# ---------------------------------------------------------------------------

def _find_program(fixtures: dict, program_id: int | None) -> dict | None:
    if program_id is None:
        return None
    return next(
        (p for p in fixtures["capture_programs"] if p["id"] == program_id),
        None,
    )


def _find_channel(fixtures: dict, program: dict | None) -> dict | None:
    if program is None:
        return None
    for channel_list in fixtures["capture_channels"].values():
        for channel in channel_list:
            if (
                channel.get("network_id") == program.get("network_id")
                and channel.get("service_id") == program.get("service_id")
            ):
                return channel
    return None


def _serialize_program(fixtures: dict, program: dict | None) -> dict | None:
    if program is None:
        return None
    channel = _find_channel(fixtures, program)
    return {
        "id": program["id"],
        "network_id": program["network_id"],
        "service_id": program["service_id"],
        "event_id": program["event_id"],
        "start_time": program["start_time"],
        "end_time": program.get("end_time"),
        "duration": program.get("duration"),
        "title": program["title"],
        "description": program["description"],
        "channel": (
            {
                "id": channel.get("id", ""),
                "display_channel_id": channel.get("display_channel_id", ""),
                "name": channel.get("name", ""),
                "type": channel.get("type", ""),
            }
            if channel
            else None
        ),
        "recorded_program_ids": list(program.get("recorded_program_ids") or []),
    }


def _serialize_capture(fixtures: dict, capture: dict, user: dict | None) -> dict:
    output = {
        "id": capture["id"],
        "file_hash": capture["file_hash"],
        "file_size": capture["file_size"],
        "captured_at": capture["captured_at"],
        "broadcast_at": capture.get("broadcast_at"),
        "image_width": capture["image_width"],
        "image_height": capture["image_height"],
        "metadata_status": capture.get("metadata_status", "NoMetadata"),
        "playback_position": capture.get("playback_position"),
        "caption_text": capture.get("caption_text"),
        "is_caption_composited": capture.get("is_caption_composited", False),
        "is_comment_composited": capture.get("is_comment_composited", False),
        "capture_program_id": capture.get("capture_program_id"),
    }
    if user is None:
        output["is_favorite"] = None
        output["tag_ids"] = None
    else:
        output["is_favorite"] = capture["id"] in fixtures["capture_favorites"]
        output["tag_ids"] = sorted(
            tag_id
            for tag_id, items in fixtures["capture_tag_items"].items()
            if capture["id"] in items
        )
    return output


def _available_captures(fixtures: dict) -> list[dict]:
    available_ids = {
        capture_id
        for capture_id, stored_files in fixtures["capture_files"].items()
        if any(f.get("status") == "Available" for f in stored_files)
    }
    return [
        capture for capture in fixtures["captures"] if capture["id"] in available_ids
    ]


def _serialize_tag(fixtures: dict, tag: dict) -> dict:
    capture_ids = fixtures["capture_tag_items"].get(tag["id"], set())
    available = {c["id"] for c in _available_captures(fixtures)}
    return {
        "id": tag["id"],
        "name": tag["name"],
        "capture_count": len(capture_ids & available),
        "created_at": tag["created_at"],
        "updated_at": tag["updated_at"],
    }


def _album(fixtures: dict, program: dict, user: dict | None) -> dict | None:
    program_captures = [
        c
        for c in _available_captures(fixtures)
        if c.get("capture_program_id") == program["id"]
    ]
    if not program_captures:
        return None
    program_captures.sort(
        key=lambda c: (
            c.get("playback_position") is None,
            c.get("playback_position") or 0,
            c["captured_at"],
            c["id"],
        )
    )
    positioned = [c for c in program_captures if c.get("playback_position") is not None]
    cover = program_captures[len(positioned) // 2]
    album = _serialize_program(fixtures, program) or {}
    album["capture_count"] = len(program_captures)
    album["cover_capture"] = _serialize_capture(fixtures, cover, user)
    return album


# ---------------------------------------------------------------------------
# Query handling
# ---------------------------------------------------------------------------

def _q1(query: dict, name: str, default=None):
    values = query.get(name)
    return values[0] if values else default


def _qlist(query: dict, name: str) -> list[str]:
    return list(query.get(name) or [])


def _qbool(query: dict, name: str) -> bool | None:
    raw = _q1(query, name)
    if raw is None or raw == "":
        return None
    return raw.lower() in ("1", "true", "yes", "on")


def _qint(query: dict, name: str) -> int | None:
    raw = _q1(query, name)
    if raw is None or raw == "":
        return None
    try:
        return int(raw)
    except ValueError:
        return None


def _parse_datetime(value: str) -> datetime:
    parsed = datetime.fromisoformat(value)
    if parsed.tzinfo is None:
        parsed = parsed.replace(tzinfo=JST)
    return parsed.astimezone(JST)


def _parse_date(value: str) -> Date:
    return Date.fromisoformat(value)


def _day_boundary(day: Date, hour: int) -> datetime:
    return datetime.combine(day, datetime.min.time(), JST) + timedelta(hours=hour)


def _jst_date(value: str, day_start_hour: int) -> str:
    dt = _parse_datetime(value) - timedelta(hours=day_start_hour)
    return dt.date().isoformat()


def _program_key(program: dict | None) -> tuple | None:
    if program is None:
        return None
    return (
        program["network_id"],
        program["service_id"],
        program["event_id"],
        _parse_datetime(program["start_time"]),
    )


class FilterError(Exception):
    def __init__(self, status: int, detail: str) -> None:
        super().__init__(detail)
        self.status = status
        self.detail = detail


def _filtered_captures(
    fixtures: dict,
    query: dict,
    user: dict | None,
    axis: str,
    day_start_hour: int,
) -> list[dict]:
    captures = _available_captures(fixtures)
    programs = {p["id"]: p for p in fixtures["capture_programs"]}

    program_key_fields = [
        _qint(query, "network_id"),
        _qint(query, "service_id"),
        _qint(query, "event_id"),
    ]
    start_time_raw = _q1(query, "start_time")
    has_program_key = any(v is not None for v in program_key_fields) or bool(start_time_raw)
    if has_program_key:
        if any(v is None for v in program_key_fields) or not start_time_raw:
            raise FilterError(422, "Specify all four program key fields")
        wanted = (
            program_key_fields[0],
            program_key_fields[1],
            program_key_fields[2],
            _parse_datetime(start_time_raw),
        )
        captures = [
            c
            for c in captures
            if _program_key(programs.get(c.get("capture_program_id"))) == wanted
        ]

    capture_program_id = _qint(query, "capture_program_id")
    if capture_program_id is not None:
        captures = [
            c for c in captures if c.get("capture_program_id") == capture_program_id
        ]

    recorded_program_id = _qint(query, "recorded_program_id")
    if recorded_program_id is not None:
        wanted_program_ids = set()
        for video in fixtures.get("videos", []):
            if video["id"] != recorded_program_id:
                continue
            key = (
                video["network_id"],
                video["service_id"],
                video["event_id"],
                _parse_datetime(video["start_time"]),
            )
            for program in fixtures["capture_programs"]:
                if _program_key(program) == key:
                    wanted_program_ids.add(program["id"])
        captures = [
            c for c in captures if c.get("capture_program_id") in wanted_program_ids
        ]

    is_favorite = _qbool(query, "is_favorite")
    if is_favorite is True:
        if user is None:
            raise FilterError(401, "Not authenticated")
        captures = [
            c for c in captures if c["id"] in fixtures["capture_favorites"]
        ]

    for raw_tag_id in sorted(set(_qlist(query, "tag_ids"))):
        if user is None:
            raise FilterError(401, "Not authenticated")
        try:
            tag_id = int(raw_tag_id)
        except ValueError:
            raise FilterError(422, "Invalid tag_ids")
        if not any(tag["id"] == tag_id for tag in fixtures["capture_tags"]):
            raise FilterError(404, "Capture tag not found")
        item_ids = fixtures["capture_tag_items"].get(tag_id, set())
        captures = [c for c in captures if c["id"] in item_ids]

    channel_ids = set(_qlist(query, "channel_ids"))
    if channel_ids:
        allowed_program_ids = set()
        for program in fixtures["capture_programs"]:
            channel = _find_channel(fixtures, program)
            if channel and (
                channel.get("id") in channel_ids
                or channel.get("display_channel_id") in channel_ids
            ):
                allowed_program_ids.add(program["id"])
        captures = [
            c for c in captures if c.get("capture_program_id") in allowed_program_ids
        ]

    start_date = _q1(query, "start_date")
    end_date = _q1(query, "end_date")
    if start_date:
        start = _day_boundary(_parse_date(start_date), day_start_hour)
        captures = [
            c
            for c in captures
            if c.get(axis) and _parse_datetime(c[axis]) >= start
        ]
    if end_date:
        end = _day_boundary(_parse_date(end_date), day_start_hour) + timedelta(days=1)
        captures = [
            c for c in captures if c.get(axis) and _parse_datetime(c[axis]) < end
        ]

    single_date = _q1(query, "date")
    if single_date:
        start = _day_boundary(_parse_date(single_date), day_start_hour)
        end = start + timedelta(days=1)
        captures = [
            c
            for c in captures
            if c.get(axis) and start <= _parse_datetime(c[axis]) < end
        ]

    is_caption_composited = _qbool(query, "is_caption_composited")
    if is_caption_composited is not None:
        captures = [
            c
            for c in captures
            if c.get("is_caption_composited", False) == is_caption_composited
        ]
    is_comment_composited = _qbool(query, "is_comment_composited")
    if is_comment_composited is not None:
        captures = [
            c
            for c in captures
            if c.get("is_comment_composited", False) == is_comment_composited
        ]

    has_caption_text = _qbool(query, "has_caption_text")
    if has_caption_text is True:
        captures = [c for c in captures if c.get("caption_text")]
    elif has_caption_text is False:
        captures = [c for c in captures if not c.get("caption_text")]

    has_metadata = _qbool(query, "has_metadata")
    if has_metadata is True:
        captures = [c for c in captures if c.get("metadata_status") == "Parsed"]
    elif has_metadata is False:
        captures = [c for c in captures if c.get("metadata_status") != "Parsed"]

    query_text = _q1(query, "query") or ""
    targets = set(_qlist(query, "query_targets"))
    all_targets = not targets or targets == {
        "CaptionText",
        "ProgramTitle",
        "ProgramDescription",
    }
    for keyword in query_text.split():
        lowered = keyword.casefold()
        matched_ids = set()
        for capture in captures:
            program = programs.get(capture.get("capture_program_id"))
            channel = _find_channel(fixtures, program)
            file_names = [
                f["file_name"]
                for f in fixtures["capture_files"].get(capture["id"], [])
            ]
            ok = False
            if all_targets or "CaptionText" in targets:
                ok = ok or lowered in (capture.get("caption_text") or "").casefold()
            if all_targets or "ProgramTitle" in targets or "ProgramDescription" in targets:
                if program is not None:
                    if all_targets or "ProgramTitle" in targets:
                        ok = ok or lowered in program["title"].casefold()
                    if all_targets or "ProgramDescription" in targets:
                        ok = ok or lowered in program["description"].casefold()
                    if all_targets and channel is not None:
                        ok = ok or lowered in channel.get("name", "").casefold()
            if all_targets:
                ok = ok or any(lowered in name.casefold() for name in file_names)
            if ok:
                matched_ids.add(capture["id"])
        captures = [c for c in captures if c["id"] in matched_ids]

    if axis == "broadcast_at":
        captures = [c for c in captures if c.get("broadcast_at")]
    return captures


def _sort_captures(captures: list[dict], order: str) -> list[dict]:
    if order == "PlaybackPosition":
        return sorted(
            captures,
            key=lambda c: (
                c.get("playback_position") is None,
                c.get("playback_position") or 0,
                _parse_datetime(c["captured_at"]),
                c["id"],
            ),
        )
    axis = "broadcast_at" if order.startswith("BroadcastAt") else "captured_at"
    reverse = order.endswith("Desc")
    return sorted(
        captures,
        key=lambda c: (_parse_datetime(c[axis]), c["id"]),
        reverse=reverse,
    )


def _encode_cursor(offset: int) -> str:
    payload = json.dumps({"offset": offset}, separators=(",", ":")).encode()
    return base64.urlsafe_b64encode(payload).decode()


def _decode_cursor(cursor: str) -> int:
    try:
        parsed = json.loads(base64.urlsafe_b64decode(cursor.encode()))
        return max(0, int(parsed.get("offset", 0)))
    except (ValueError, TypeError, KeyError):
        raise FilterError(422, "Invalid cursor")


# ---------------------------------------------------------------------------
# Multipart
# ---------------------------------------------------------------------------

def parse_multipart(content_type: str, body: bytes) -> dict[str, list[dict]]:
    match = re.search(r'boundary="?([^";]+)"?', content_type or "")
    if not match:
        return {}
    boundary = match.group(1).encode()
    delimiter = b"--" + boundary
    fields: dict[str, list[dict]] = {}
    for chunk in body.split(delimiter)[1:]:
        if chunk.startswith(b"--"):
            break
        if chunk.startswith(b"\r\n"):
            chunk = chunk[2:]
        if chunk.endswith(b"\r\n"):
            chunk = chunk[:-2]
        if not chunk:
            continue
        if b"\r\n\r\n" not in chunk:
            continue
        raw_headers, data = chunk.split(b"\r\n\r\n", 1)
        headers = {}
        for line in raw_headers.split(b"\r\n"):
            if b":" not in line:
                continue
            name, value = line.split(b":", 1)
            headers[name.strip().lower().decode("latin-1")] = (
                value.strip().decode("latin-1")
            )
        disposition = headers.get("content-disposition", "")
        name_match = re.search(r'name="([^"]*)"', disposition)
        filename_match = re.search(r'filename="([^"]*)"', disposition)
        if name_match is None:
            continue
        fields.setdefault(name_match.group(1), []).append(
            {
                "filename": filename_match.group(1) if filename_match else None,
                "content_type": headers.get("content-type"),
                "data": data,
            }
        )
    return fields


# ---------------------------------------------------------------------------
# Endpoint handling
# ---------------------------------------------------------------------------

def _send(handler, obj, status: int = 200) -> None:
    handler._send_json(obj, status)


def _error(handler, status: int, detail: str) -> None:
    handler._send_json({"detail": detail}, status)


def handle(
    handler,
    method: str,
    parts: list[str],
    query: dict,
    fixtures: dict,
    state,
) -> bool:
    """Handle an /api/captures request. Returns True when it was handled."""
    if not parts or parts[0] != "captures":
        return False

    is_upload = method == "POST" and len(parts) == 1
    if not getattr(state, "captures_library", True) and not is_upload:
        _error(handler, 404, "Not Found")
        return True

    try:
        if method == "GET":
            _handle_get(handler, parts, query, fixtures, state)
        elif method == "POST":
            _handle_post(handler, parts, query, fixtures, state)
        elif method == "PUT":
            _handle_put(handler, parts, fixtures, state)
        elif method == "DELETE":
            _handle_delete(handler, parts, fixtures, state)
        else:
            _error(handler, 405, "Method Not Allowed")
    except FilterError as error:
        _error(handler, error.status, error.detail)
    return True


def _handle_get(handler, parts, query, fixtures, state) -> None:
    user = handler._optional_user(fixtures)
    if parts == ["captures"]:
        _list_captures(handler, query, fixtures, user)
        return
    if parts == ["captures", "sections"]:
        _list_sections(handler, query, fixtures, user)
        return
    if parts == ["captures", "channels"]:
        _list_channels(handler, fixtures)
        return
    if parts == ["captures", "programs"]:
        _list_programs(handler, query, fixtures, user)
        return
    if len(parts) == 3 and parts[1] == "programs":
        try:
            program_id = int(parts[2])
        except ValueError:
            _error(handler, 404, "Capture program not found")
            return
        program = _find_program(fixtures, program_id)
        album = _album(fixtures, program, user) if program else None
        if album is None:
            _error(handler, 404, "Capture program not found")
            return
        _send(handler, album)
        return
    if parts == ["captures", "tags"]:
        if user is None:
            _error(handler, 401, "Unauthorized")
            return
        tags = sorted(fixtures["capture_tags"], key=lambda t: t["name"])
        _send(handler, [_serialize_tag(fixtures, tag) for tag in tags])
        return
    if len(parts) == 3 and parts[1] == "tags":
        _error(handler, 404, "Not Found")
        return
    if len(parts) == 3 and parts[2] == "image":
        _serve_image(handler, parts[1], query, fixtures)
        return
    if len(parts) == 2:
        _capture_detail(handler, parts[1], fixtures, user)
        return
    _error(handler, 404, "Not Found")


def _list_captures(handler, query, fixtures, user) -> None:
    order = _q1(query, "order", "CapturedAtDesc")
    if order not in {
        "CapturedAtDesc",
        "CapturedAtAsc",
        "BroadcastAtDesc",
        "BroadcastAtAsc",
        "PlaybackPosition",
    }:
        raise FilterError(422, "Invalid order")
    axis = "broadcast_at" if order.startswith("BroadcastAt") else "captured_at"
    day_start_hour = _qint(query, "day_start_hour") or 0
    captures = _filtered_captures(fixtures, query, user, axis, day_start_hour)
    captures = _sort_captures(captures, order)
    limit = _qint(query, "limit")
    limit = 100 if limit is None else min(max(limit, 1), 200)
    cursor = _q1(query, "cursor")
    offset = _decode_cursor(cursor) if cursor else 0
    page = captures[offset : offset + limit]
    next_cursor = (
        _encode_cursor(offset + limit) if offset + limit < len(captures) else None
    )
    program_ids = {
        c["capture_program_id"]
        for c in page
        if c.get("capture_program_id") is not None
    }
    programs = [
        _serialize_program(fixtures, p)
        for p in fixtures["capture_programs"]
        if p["id"] in program_ids
    ]
    _send(
        handler,
        {
            "captures": [_serialize_capture(fixtures, c, user) for c in page],
            "programs": programs,
            "next_cursor": next_cursor,
        },
    )


def _list_sections(handler, query, fixtures, user) -> None:
    axis_name = _q1(query, "axis", "CapturedAt")
    axis = "broadcast_at" if axis_name == "BroadcastAt" else "captured_at"
    day_start_hour = _qint(query, "day_start_hour") or 0
    captures = _filtered_captures(fixtures, query, user, axis, day_start_hour)
    counts: dict[str, int] = {}
    for capture in captures:
        value = capture.get(axis)
        if not value:
            continue
        day = _jst_date(value, day_start_hour)
        counts[day] = counts.get(day, 0) + 1
    sections = [
        {"date": day, "count": count}
        for day, count in sorted(counts.items(), reverse=True)
    ]
    _send(
        handler,
        {"sections": sections, "total": sum(counts.values())},
    )


def _list_channels(handler, fixtures) -> None:
    channel_ids = set()
    for program in fixtures["capture_programs"]:
        if not _album(fixtures, program, None):
            continue
        channel = _find_channel(fixtures, program)
        if channel:
            channel_ids.add(channel.get("id"))
    channels = []
    for channel_list in fixtures["capture_channels"].values():
        for channel in channel_list:
            if channel.get("id") in channel_ids:
                channels.append(
                    {
                        "id": channel.get("id", ""),
                        "display_channel_id": channel.get("display_channel_id", ""),
                        "name": channel.get("name", ""),
                        "type": channel.get("type", ""),
                    }
                )
    channels.sort(
        key=lambda c: (
            _channel_sort_key(fixtures, c),
            c.get("display_channel_id", ""),
            c.get("id", ""),
        )
    )
    _send(handler, channels)


def _channel_sort_key(fixtures: dict, serialized: dict) -> int:
    for channel_list in fixtures["capture_channels"].values():
        for channel in channel_list:
            if channel.get("id") == serialized.get("id"):
                return channel.get("remocon_id", 0)
    return 0


def _list_programs(handler, query, fixtures, user) -> None:
    order = _q1(query, "order", "BroadcastAtDesc")
    reverse = order != "BroadcastAtAsc"
    keywords = [k.casefold() for k in (_q1(query, "query") or "").split()]
    has_recorded = _qbool(query, "has_recorded_program")
    limit = _qint(query, "limit")
    limit = 60 if limit is None else min(max(limit, 1), 200)
    cursor = _q1(query, "cursor")
    offset = _decode_cursor(cursor) if cursor else 0

    albums = []
    for program in fixtures["capture_programs"]:
        album = _album(fixtures, program, user)
        if album is None:
            continue
        channel = _find_channel(fixtures, program)
        haystack = (program["title"] + " " + (channel.get("name", "") if channel else "")).casefold()
        if any(keyword not in haystack for keyword in keywords):
            continue
        has_recorded_program = bool(program.get("recorded_program_ids"))
        if has_recorded is True and not has_recorded_program:
            continue
        if has_recorded is False and has_recorded_program:
            continue
        albums.append(album)
    albums.sort(
        key=lambda album: (album["start_time"], album["id"]),
        reverse=reverse,
    )
    page = albums[offset : offset + limit]
    next_cursor = (
        _encode_cursor(offset + limit) if offset + limit < len(albums) else None
    )
    _send(handler, {"programs": page, "next_cursor": next_cursor})


def _capture_detail(handler, raw_id, fixtures, user) -> None:
    try:
        capture_id = int(raw_id)
    except ValueError:
        _error(handler, 404, "Capture not found")
        return
    capture = next(
        (c for c in fixtures["captures"] if c["id"] == capture_id), None
    )
    if capture is None:
        _error(handler, 404, "Capture not found")
        return
    detail = _serialize_capture(fixtures, capture, user)
    program = _serialize_program(
        fixtures, _find_program(fixtures, capture.get("capture_program_id"))
    )
    detail["program"] = program
    detail["files"] = list(fixtures["capture_files"].get(capture_id, []))
    _send(handler, detail)


def _serve_image(handler, raw_id, query, fixtures) -> None:
    try:
        capture_id = int(raw_id)
    except ValueError:
        _error(handler, 404, "Capture image not found")
        return
    capture = next(
        (c for c in fixtures["captures"] if c["id"] == capture_id), None
    )
    hash_value = _q1(query, "hash")
    if capture is None or hash_value != capture["file_hash"]:
        _error(handler, 404, "Capture image not found")
        return
    data = fixtures["capture_images"].get(capture_id)
    if data is None:
        _error(handler, 404, "Capture image not found")
        return
    media_type = CAPTURE_PNG if data.startswith(b"\x89PNG") else CAPTURE_JPEG
    handler._send_bytes(
        data,
        media_type,
        cache="public, max-age=31536000, immutable",
        extra_headers={"ETag": f'"{hash_value}"'},
    )


def _handle_post(handler, parts, query, fixtures, state) -> None:
    user = handler._optional_user(fixtures)
    if parts == ["captures"]:
        _upload_capture(handler, fixtures, state, user)
        return
    if parts == ["captures", "tags"]:
        if user is None:
            _error(handler, 401, "Unauthorized")
            return
        _create_tag(handler, fixtures)
        return
    if parts == ["captures", "favorites"]:
        if user is None:
            _error(handler, 401, "Unauthorized")
            return
        ids = _validated_capture_ids(handler, fixtures)
        if ids is None:
            return
        fixtures["capture_favorites"].update(ids)
        state.record_capture_favorite(added=len(ids))
        handler.send_response(204)
        handler.send_header("Content-Length", "0")
        handler.end_headers()
        return
    if len(parts) == 4 and parts[1] == "tags" and parts[3] == "items":
        if user is None:
            _error(handler, 401, "Unauthorized")
            return
        tag = _owned_tag(handler, fixtures, parts[2])
        if tag is None:
            return
        ids = _validated_capture_ids(handler, fixtures)
        if ids is None:
            return
        fixtures["capture_tag_items"].setdefault(tag["id"], set()).update(ids)
        handler.send_response(204)
        handler.send_header("Content-Length", "0")
        handler.end_headers()
        return
    _error(handler, 404, "Not Found")


def _handle_put(handler, parts, fixtures, state) -> None:
    user = handler._optional_user(fixtures)
    if len(parts) == 3 and parts[1] == "tags":
        if user is None:
            _error(handler, 401, "Unauthorized")
            return
        tag = _owned_tag(handler, fixtures, parts[2])
        if tag is None:
            return
        body = handler._read_json_body()
        name = str(body.get("name") or "").strip()
        if not 1 <= len(name) <= 255:
            _error(handler, 422, "Invalid tag name")
            return
        if any(t["name"] == name and t["id"] != tag["id"] for t in fixtures["capture_tags"]):
            _error(handler, 422, "Capture tag name already exists")
            return
        tag["name"] = name
        tag["updated_at"] = datetime.now(JST).isoformat()
        _send(handler, _serialize_tag(fixtures, tag))
        return
    _error(handler, 404, "Not Found")


def _handle_delete(handler, parts, fixtures, state) -> None:
    user = handler._optional_user(fixtures)
    if parts == ["captures"]:
        if user is None:
            _error(handler, 401, "Unauthorized")
            return
        if not user.get("is_admin", False):
            _error(handler, 403, "Forbidden")
            return
        body = handler._read_json_body()
        ids = body.get("capture_ids") or []
        deleted = []
        failed = []
        for capture_id in sorted(set(ids)):
            capture = next(
                (c for c in fixtures["captures"] if c["id"] == capture_id), None
            )
            if capture is None:
                failed.append(capture_id)
                continue
            fixtures["captures"].remove(capture)
            fixtures["capture_files"].pop(capture_id, None)
            fixtures["capture_images"].pop(capture_id, None)
            fixtures["capture_favorites"].discard(capture_id)
            for items in fixtures["capture_tag_items"].values():
                items.discard(capture_id)
            deleted.append(capture_id)
        _send(
            handler,
            {"deleted_capture_ids": deleted, "failed_capture_ids": failed},
        )
        return
    if len(parts) == 3 and parts[1] == "tags":
        if user is None:
            _error(handler, 401, "Unauthorized")
            return
        tag = _owned_tag(handler, fixtures, parts[2])
        if tag is None:
            return
        fixtures["capture_tags"].remove(tag)
        fixtures["capture_tag_items"].pop(tag["id"], None)
        handler.send_response(204)
        handler.send_header("Content-Length", "0")
        handler.end_headers()
        return
    if parts == ["captures", "favorites"]:
        if user is None:
            _error(handler, 401, "Unauthorized")
            return
        body = handler._read_json_body()
        removed = 0
        for capture_id in body.get("capture_ids") or []:
            if capture_id in fixtures["capture_favorites"]:
                fixtures["capture_favorites"].discard(capture_id)
                removed += 1
        state.record_capture_favorite(removed=removed)
        handler.send_response(204)
        handler.send_header("Content-Length", "0")
        handler.end_headers()
        return
    if len(parts) == 4 and parts[1] == "tags" and parts[3] == "items":
        if user is None:
            _error(handler, 401, "Unauthorized")
            return
        tag = _owned_tag(handler, fixtures, parts[2])
        if tag is None:
            return
        body = handler._read_json_body()
        items = fixtures["capture_tag_items"].setdefault(tag["id"], set())
        for capture_id in body.get("capture_ids") or []:
            items.discard(capture_id)
        handler.send_response(204)
        handler.send_header("Content-Length", "0")
        handler.end_headers()
        return
    _error(handler, 404, "Not Found")


# ---------------------------------------------------------------------------
# Tags / ids / upload
# ---------------------------------------------------------------------------

def _owned_tag(handler, fixtures, raw_id):
    try:
        tag_id = int(raw_id)
    except ValueError:
        _error(handler, 404, "Capture tag not found")
        return None
    tag = next((t for t in fixtures["capture_tags"] if t["id"] == tag_id), None)
    if tag is None:
        _error(handler, 404, "Capture tag not found")
        return None
    return tag


def _create_tag(handler, fixtures) -> None:
    body = handler._read_json_body()
    name = str(body.get("name") or "").strip()
    if not 1 <= len(name) <= 255:
        _error(handler, 422, "Invalid tag name")
        return
    if any(tag["name"] == name for tag in fixtures["capture_tags"]):
        _error(handler, 422, "Capture tag name already exists")
        return
    tag_id = max((tag["id"] for tag in fixtures["capture_tags"]), default=0) + 1
    now = datetime.now(JST).isoformat()
    tag = {"id": tag_id, "name": name, "created_at": now, "updated_at": now}
    fixtures["capture_tags"].append(tag)
    fixtures["capture_tag_items"][tag_id] = set()
    _send(handler, _serialize_tag(fixtures, tag), 201)


def _validated_capture_ids(handler, fixtures) -> list[int] | None:
    body = handler._read_json_body()
    raw_ids = body.get("capture_ids") or []
    try:
        ids = sorted(set(int(value) for value in raw_ids))
    except (TypeError, ValueError):
        _error(handler, 422, "Invalid capture_ids")
        return None
    existing = {capture["id"] for capture in fixtures["captures"]}
    if any(capture_id not in existing for capture_id in ids):
        _error(handler, 404, "Capture not found")
        return None
    return ids


def _upload_capture(handler, fixtures, state, user) -> None:
    content_type = handler.headers.get("Content-Type") or ""
    length = int(handler.headers.get("Content-Length") or 0)
    if length > MAX_UPLOAD_SIZE + 1024 * 1024:
        _error(handler, 413, "Image file is too large")
        return
    body = handler.rfile.read(length) if length > 0 else b""
    fields = parse_multipart(content_type, body)
    images = fields.get("image") or []
    if not images:
        _error(handler, 422, "Please upload JPEG or PNG image")
        return
    image_part = images[0]
    filename = image_part.get("filename") or ""
    data = image_part.get("data") or b""

    if len(data) > MAX_UPLOAD_SIZE:
        _error(handler, 413, "Image file is too large")
        return
    if filename in ("", ".", "..") or any(ch in filename for ch in ("/", "\\", "\x00", ":")):
        _error(handler, 422, "Specified filename is invalid")
        return
    filename = INVALID_FILENAME_CHARS.sub("_", filename)
    if not filename.lower().endswith((".jpg", ".jpeg", ".png")):
        _error(handler, 422, "Please upload JPEG or PNG image")
        return
    if not (data.startswith(b"\x89PNG\r\n\x1a\n") or data.startswith(b"\xff\xd8\xff")):
        _error(handler, 422, "Please upload JPEG or PNG image")
        return

    modified_at: datetime
    modified_raw = (fields.get("file_modified_at") or [{}])[0].get("data", b"")
    if modified_raw:
        try:
            milliseconds = float(modified_raw.decode("utf-8"))
            modified_at = datetime.fromtimestamp(milliseconds / 1000, JST)
        except (ValueError, OverflowError, OSError, UnicodeDecodeError):
            _error(handler, 422, "Invalid file_modified_at")
            return
    else:
        modified_at = datetime.now(JST)

    # 実際のサーバーと同じく、アップロードされた画像の EXIF (XPComment) を読んで
    # 番組情報・撮影日時・字幕/コメントの合成状態を登録する
    metadata, date_time_original = read_capture_exif(data)

    fields_summary = {
        name: [
            {
                "filename": part.get("filename"),
                "content_type": part.get("content_type"),
                "size": len(part.get("data") or b""),
            }
            for part in parts
        ]
        for name, parts in fields.items()
    }
    state.record_capture_upload(
        filename,
        fields_summary,
        len(data),
        content_type,
        metadata=metadata,
        date_time_original=date_time_original,
    )

    # KonomiTV v0.14.1 has no captures library: it just writes the file and
    # answers 204 without registering anything.
    if not getattr(state, "captures_library", True):
        handler.send_response(204)
        handler.send_header("Content-Length", "0")
        handler.end_headers()
        return

    digest = hashlib.sha256(data).hexdigest()
    existing = next(
        (c for c in fixtures["captures"] if c["file_hash"] == digest), None
    )
    if existing is not None:
        _send(handler, _serialize_capture(fixtures, existing, user), 201)
        return

    capture_id = max((c["id"] for c in fixtures["captures"]), default=0) + 1
    stored_name = filename
    existing_names = {
        f["file_name"]
        for files in fixtures["capture_files"].values()
        for f in files
    }
    count = 1
    while stored_name in existing_names:
        stem, dot, extension = filename.rpartition(".")
        stored_name = f"{stem}-{count}.{extension}" if dot else f"{filename}-{count}"
        count += 1

    width, height = image_dimensions(data)

    # EXIF の番組情報をキャプチャの列に反映する (読めない画像は NoMetadata のまま)
    captured_at = modified_at
    metadata_status = "NoMetadata"
    playback_position = None
    caption_text = None
    is_caption_composited = False
    is_comment_composited = False
    capture_program_id = None
    broadcast_at = None
    if metadata is not None:
        metadata_status = "Parsed"
        position = metadata.get("captured_playback_position")
        if isinstance(position, (int, float)) and not isinstance(position, bool):
            if position == position and position not in (float("inf"), float("-inf")):
                playback_position = float(position)
        text = metadata.get("caption_text")
        if isinstance(text, str):
            caption_text = text or None
        is_caption_composited = bool(metadata.get("is_caption_composited"))
        is_comment_composited = bool(metadata.get("is_comment_composited"))
        capture_program_id = match_capture_program(fixtures, metadata)
        program = _find_program(fixtures, capture_program_id)
        if program is not None:
            broadcast_at = program["start_time"]
        # ファイルの更新日時が指定されていない場合は、EXIF の撮影日時を使う
        exif_captured_at = metadata.get("captured_at")
        if modified_raw == b"" and isinstance(exif_captured_at, str):
            try:
                captured_at = _parse_datetime(exif_captured_at)
            except ValueError:
                captured_at = modified_at

    capture = {
        "id": capture_id,
        "file_hash": digest,
        "file_size": len(data),
        "captured_at": captured_at.isoformat(),
        "broadcast_at": broadcast_at,
        "image_width": width,
        "image_height": height,
        "metadata_status": metadata_status,
        "playback_position": playback_position,
        "caption_text": caption_text,
        "is_caption_composited": is_caption_composited,
        "is_comment_composited": is_comment_composited,
        "capture_program_id": capture_program_id,
    }
    fixtures["captures"].append(capture)
    fixtures["capture_files"][capture_id] = [
        {
            "file_name": stored_name,
            "file_path": f"/captures/{stored_name}",
            "status": "Available",
        }
    ]
    fixtures["capture_images"][capture_id] = data
    _send(handler, _serialize_capture(fixtures, capture, user), 201)
