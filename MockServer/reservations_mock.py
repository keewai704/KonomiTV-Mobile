"""In-memory recording reservations for the mock KonomiTV server.

Implements the three EDCB-only recording routers:

- ReservationsRouter           `/api/recording/reservations`
- ReservationConditionsRouter  `/api/recording/conditions`
- RecordingPresetsRouter       `/api/recording/presets`

The handler integration lives in `mock_server.MockHandler`; this module owns the
fixtures, the mutation logic and the shapes of the responses, so
`mock_server.py` stays readable.

Program IDs are stable across days (they are built from the network / service /
event IDs), so a fixture reservation also marks the same hour of the timetable
on every day the mock generates.
"""

from __future__ import annotations

import copy
from datetime import datetime, timedelta, timezone

JST = timezone(timedelta(hours=9))

RECORDING_PRESETS_KEY = "recording_presets"
RESERVATIONS_KEY = "reservations"
CONDITIONS_KEY = "reservation_conditions"
PROGRAMS_KEY = "reservation_programs"


# ---------------------------------------------------------------------------
# Record settings fixtures
# ---------------------------------------------------------------------------

def global_defaults() -> dict:
    return {
        "recording_start_margin": 5,
        "recording_end_margin": 2,
        "caption_recording_mode": "Enable",
        "data_broadcasting_recording_mode": "Disable",
        "post_recording_mode": "Nothing",
    }


def record_settings(**overrides) -> dict:
    """Record settings in the shape schemas.RecordSettings expects."""
    settings = {
        "is_enabled": True,
        "priority": 2,
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
    settings.update(overrides)
    return settings


def build_presets() -> dict:
    return {
        "global_defaults": global_defaults(),
        "presets": [
            {
                "id": 0,
                "name": "デフォルト",
                "record_settings": record_settings(),
            },
            {
                "id": 1,
                "name": "アニメ (マージン多め)",
                "record_settings": record_settings(
                    priority=4,
                    recording_start_margin=10,
                    recording_end_margin=5,
                    recording_folders=[
                        {
                            "recording_folder_path": "/mnt/hdd/Records/アニメ",
                            "recording_file_name_template": "$ZtoH(Title)$.ts",
                            "is_oneseg_separate_recording_folder": False,
                        }
                    ],
                ),
            },
            {
                "id": 2,
                "name": "ニュース (優先度 5)",
                "record_settings": record_settings(
                    priority=5,
                    caption_recording_mode="Enable",
                    data_broadcasting_recording_mode="Disable",
                ),
            },
        ],
    }


# ---------------------------------------------------------------------------
# Fixtures
# ---------------------------------------------------------------------------

def _program_start(program: dict) -> datetime:
    return datetime.fromisoformat(program["start_time"])


def _pick_programs(programs: dict, now: datetime, count: int) -> list[tuple[dict, dict]]:
    """Upcoming programs spread over the channels (and a few hours)."""
    by_channel: dict[str, list[tuple[dict, dict]]] = {}
    for channel, program in programs.values():
        if _program_start(program) <= now:
            continue
        by_channel.setdefault(channel["display_channel_id"], []).append((channel, program))
    for entries in by_channel.values():
        entries.sort(key=lambda entry: entry[1]["start_time"])

    channel_ids = list(by_channel)
    if not channel_ids:
        return []

    # Round robin over the channels, taking the next upcoming program of each,
    # so the fixtures do not all start at the same hour.
    picked: list[tuple[dict, dict]] = []
    extra = 0
    while len(picked) < count:
        progressed = False
        for channel_id in channel_ids:
            entries = by_channel[channel_id]
            if len(entries) <= extra:
                continue
            picked.append(entries[extra])
            progressed = True
            if len(picked) == count:
                break
        if not progressed:
            break
        extra += 1
    return picked


def _current_program(
    programs: dict,
    now: datetime,
    channel_index: int = 1,
) -> tuple[dict, dict] | None:
    """A program that is on air, of the channel at channel_index when possible.

    The first channel is deliberately skipped: the live screen is opened with
    it in the UI tests, and its program panel should offer a reservation.
    """
    on_air: list[tuple[dict, dict]] = []
    seen_channels: set[str] = set()
    for channel, program in programs.values():
        channel_id = channel["display_channel_id"]
        if channel_id in seen_channels:
            continue
        start = _program_start(program)
        end = datetime.fromisoformat(program["end_time"])
        if start <= now < end:
            seen_channels.add(channel_id)
            on_air.append((channel, program))
    if not on_air:
        return None
    return on_air[min(channel_index, len(on_air) - 1)]


def _estimated_file_size(program: dict) -> int:
    """Rough estimate (the real server uses the channel's bitrate)."""
    duration = float(program.get("duration") or 0)
    return int(duration * 2_500_000)


def _scheduled_file_name(program: dict) -> str:
    return f"{program.get('title', '')}.ts"


def _reservation(
    reservation_id: int,
    channel: dict,
    program: dict,
    settings: dict,
    is_recording_in_progress: bool = False,
    recording_availability: str = "Full",
    comment: str = "",
) -> dict:
    return {
        "id": reservation_id,
        "channel": copy.deepcopy(channel),
        "program": copy.deepcopy(program),
        "is_recording_in_progress": is_recording_in_progress,
        "recording_availability": recording_availability,
        "comment": comment,
        "scheduled_recording_file_name": _scheduled_file_name(program),
        "estimated_recording_file_size": _estimated_file_size(program),
        "record_settings": copy.deepcopy(settings),
    }


def _condition(condition_id: int, keyword: str, settings: dict, count: int = 0) -> dict:
    return {
        "id": condition_id,
        "reservation_count": count,
        "program_search_condition": {
            "is_enabled": True,
            "keyword": keyword,
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
        },
        "record_settings": copy.deepcopy(settings),
    }


def build_fixtures(programs: dict, now: datetime | None = None) -> dict:
    """Build the reservation fixtures from the EPG the mock server generates.

    Args:
        programs: {program_id: (channel, program)} for today and tomorrow,
            built by mock_server.build_day_programs.
        now: The current time (JST).
    """
    now = now or datetime.now(JST)
    presets = build_presets()
    default_settings = presets["presets"][0]["record_settings"]

    picked = _pick_programs(programs, now, 4)
    reservations: list[dict] = []

    if picked:
        channel, program = picked[0]
        reservations.append(_reservation(
            1,
            channel,
            program,
            record_settings(priority=3),
        ))
    if len(picked) > 1:
        channel, program = picked[1]
        reservations.append(_reservation(
            2,
            channel,
            program,
            record_settings(priority=4),
            recording_availability="Partial",
        ))
    if len(picked) > 2:
        channel, program = picked[2]
        reservations.append(_reservation(
            3,
            channel,
            program,
            record_settings(priority=5, caption_recording_mode="Enable"),
            recording_availability="Unavailable",
        ))
    if len(picked) > 3:
        channel, program = picked[3]
        reservations.append(_reservation(
            4,
            channel,
            program,
            record_settings(is_enabled=False),
        ))

    on_air = _current_program(programs, now)
    if on_air is not None:
        channel, program = on_air
        reservations.append(_reservation(
            5,
            channel,
            program,
            record_settings(priority=3),
            is_recording_in_progress=True,
        ))

    return {
        RESERVATIONS_KEY: reservations,
        CONDITIONS_KEY: [
            _condition(1, "ニュース", record_settings(priority=3), count=2),
            _condition(
                2,
                "アニメ",
                presets["presets"][1]["record_settings"],
                count=0,
            ),
        ],
        RECORDING_PRESETS_KEY: presets,
        PROGRAMS_KEY: programs,
    }


# ---------------------------------------------------------------------------
# Helpers used by the timetable
# ---------------------------------------------------------------------------

def reservation_summary(fixtures: dict, program_id: str) -> dict | None:
    """The `reservation` field of a timetable program (or None)."""
    for reservation in fixtures.get(RESERVATIONS_KEY, []):
        if reservation["program"].get("id") != program_id:
            continue
        settings = reservation.get("record_settings") or {}
        if reservation.get("is_recording_in_progress"):
            status = "Recording"
        elif settings.get("is_enabled") is False:
            status = "Disabled"
        else:
            status = "Reserved"
        return {
            "id": reservation["id"],
            "status": status,
            "recording_availability": reservation.get("recording_availability", "Full"),
        }
    return None


def find_reservation(fixtures: dict, reservation_id: int) -> dict | None:
    for reservation in fixtures.get(RESERVATIONS_KEY, []):
        if reservation.get("id") == reservation_id:
            return reservation
    return None


def find_condition(fixtures: dict, condition_id: int) -> dict | None:
    for condition in fixtures.get(CONDITIONS_KEY, []):
        if condition.get("id") == condition_id:
            return condition
    return None


def _next_id(items: list[dict]) -> int:
    return max((int(item.get("id") or 0) for item in items), default=0) + 1


def _resolve_program(fixtures: dict, program_id: str, payload: dict | None) -> tuple[dict, dict] | None:
    """Channel and program of a reservation request."""
    programs = fixtures.get(PROGRAMS_KEY) or {}
    if program_id in programs:
        return programs[program_id]

    # A program the EPG of the mock does not generate: the client sent the
    # minimal payload the real server accepts for EIT[p/f] programs.
    if not payload:
        return None
    channel = None
    for channel_list in (fixtures.get("channels") or {}).values():
        for entry in channel_list:
            if entry.get("id") == payload.get("channel_id"):
                channel = entry
                break
    if channel is None:
        return None
    program = {
        "id": program_id,
        "channel_id": payload.get("channel_id"),
        "network_id": payload.get("network_id"),
        "service_id": payload.get("service_id"),
        "event_id": payload.get("event_id"),
        "title": payload.get("title") or "",
        "description": "",
        "detail": {},
        "start_time": payload.get("start_time"),
        "end_time": None,
        "duration": payload.get("duration") or 0,
        "is_free": True,
        "genres": [],
        "video_type": None,
        "video_codec": None,
        "video_resolution": None,
        "primary_audio_type": "",
        "primary_audio_language": "",
        "primary_audio_sampling_rate": "",
        "secondary_audio_type": None,
        "secondary_audio_language": None,
        "secondary_audio_sampling_rate": None,
    }
    start = payload.get("start_time")
    if isinstance(start, str):
        try:
            end = datetime.fromisoformat(start) + timedelta(
                seconds=float(payload.get("duration") or 0)
            )
            program["end_time"] = end.isoformat(timespec="seconds")
        except ValueError:
            program["end_time"] = start
    return channel, program


# ---------------------------------------------------------------------------
# HTTP handling
# ---------------------------------------------------------------------------

def handle(handler, method: str, parts: list[str], query: dict, fixtures: dict, state) -> bool:
    """Handle an /api/recording request. Returns True when it was handled."""
    if not parts or parts[0] != "recording":
        return False

    if method == "GET":
        _handle_get(handler, parts, fixtures, state)
    elif method == "POST":
        _handle_post(handler, parts, fixtures, state)
    elif method == "PUT":
        _handle_put(handler, parts, fixtures, state)
    elif method == "DELETE":
        _handle_delete(handler, parts, fixtures, state)
    else:
        handler._send_json({"detail": "Method Not Allowed"}, 405)
    return True


def _not_found(handler) -> None:
    handler._send_json({"detail": "Not Found"}, 404)


def _no_content(handler) -> None:
    handler.send_response(204)
    handler.send_header("Content-Length", "0")
    handler.end_headers()


def _handle_get(handler, parts: list[str], fixtures: dict, state) -> None:
    if parts == ["recording", "reservations"]:
        reservations = copy.deepcopy(fixtures.get(RESERVATIONS_KEY, []))
        reservations.sort(key=lambda item: item["program"].get("start_time") or "")
        handler._send_json({
            "total": len(reservations),
            "reservations": reservations,
        })
        return

    if len(parts) == 3 and parts[1] == "reservations":
        reservation = find_reservation(fixtures, _int(parts[2]))
        if reservation is None:
            handler._send_json({"detail": "Specified reservation_id was not found"}, 422)
            return
        handler._send_json(copy.deepcopy(reservation))
        return

    if parts == ["recording", "conditions"]:
        conditions = copy.deepcopy(fixtures.get(CONDITIONS_KEY, []))
        handler._send_json({
            "total": len(conditions),
            "reservation_conditions": conditions,
        })
        return

    if len(parts) == 3 and parts[1] == "conditions":
        condition = find_condition(fixtures, _int(parts[2]))
        if condition is None:
            handler._send_json(
                {"detail": "Specified reservation_condition_id was not found"}, 422
            )
            return
        handler._send_json(copy.deepcopy(condition))
        return

    if parts == ["recording", "presets"]:
        state.record_reservation_presets_fetch()
        handler._send_json(copy.deepcopy(fixtures.get(RECORDING_PRESETS_KEY, build_presets())))
        return

    _not_found(handler)


def _handle_post(handler, parts: list[str], fixtures: dict, state) -> None:
    body = handler._read_json_body()

    if parts == ["recording", "reservations"]:
        program_id = str(body.get("program_id") or "")
        record_settings_body = body.get("record_settings") or record_settings()
        resolved = _resolve_program(fixtures, program_id, body.get("program"))
        if resolved is None:
            handler._send_json({"detail": "Specified program was not found"}, 422)
            return
        channel, program = resolved
        reservations = fixtures.setdefault(RESERVATIONS_KEY, [])
        for existing in reservations:
            if existing["program"].get("id") == program_id:
                handler._send_json(
                    {"detail": "The same program_id is already reserved"}, 422
                )
                return
        reservation = _reservation(
            _next_id(reservations),
            channel,
            program,
            record_settings_body,
        )
        reservations.append(reservation)
        state.record_reservation_add(program_id, record_settings_body)
        handler._send_json({"status": "ok", "id": reservation["id"]}, 201)
        return

    if parts == ["recording", "conditions"]:
        search_condition = body.get("program_search_condition")
        if not isinstance(search_condition, dict):
            handler._send_json(
                {"detail": "program_search_condition is required"}, 422
            )
            return
        record_settings_body = body.get("record_settings") or record_settings()
        conditions = fixtures.setdefault(CONDITIONS_KEY, [])
        condition = {
            "id": _next_id(conditions),
            "reservation_count": 0,
            "program_search_condition": copy.deepcopy(search_condition),
            "record_settings": copy.deepcopy(record_settings_body),
        }
        conditions.append(condition)
        state.record_reservation_condition_add(copy.deepcopy(condition))
        handler._send_json({"status": "ok", "id": condition["id"]}, 201)
        return

    _not_found(handler)


def _handle_put(handler, parts: list[str], fixtures: dict, state) -> None:
    body = handler._read_json_body()

    if len(parts) == 3 and parts[1] == "reservations":
        reservation = find_reservation(fixtures, _int(parts[2]))
        if reservation is None:
            handler._send_json({"detail": "Specified reservation_id was not found"}, 422)
            return
        record_settings_body = body.get("record_settings")
        if not isinstance(record_settings_body, dict):
            handler._send_json({"detail": "record_settings is required"}, 422)
            return
        reservation["record_settings"] = copy.deepcopy(record_settings_body)
        state.record_reservation_update(reservation["id"], record_settings_body)
        handler._send_json(copy.deepcopy(reservation))
        return

    if len(parts) == 3 and parts[1] == "conditions":
        condition = find_condition(fixtures, _int(parts[2]))
        if condition is None:
            handler._send_json(
                {"detail": "Specified reservation_condition_id was not found"}, 422
            )
            return
        search_condition = body.get("program_search_condition")
        record_settings_body = body.get("record_settings")
        if not isinstance(search_condition, dict) or not isinstance(record_settings_body, dict):
            handler._send_json(
                {"detail": "program_search_condition and record_settings are required"}, 422
            )
            return
        condition["program_search_condition"] = copy.deepcopy(search_condition)
        condition["record_settings"] = copy.deepcopy(record_settings_body)
        state.record_reservation_condition_update(copy.deepcopy(condition))
        handler._send_json(copy.deepcopy(condition))
        return

    _not_found(handler)


def _handle_delete(handler, parts: list[str], fixtures: dict, state) -> None:
    if len(parts) == 3 and parts[1] == "reservations":
        reservations = fixtures.get(RESERVATIONS_KEY, [])
        for index, reservation in enumerate(reservations):
            if reservation.get("id") == _int(parts[2]):
                del reservations[index]
                state.record_reservation_delete(reservation["id"])
                _no_content(handler)
                return
        handler._send_json({"detail": "Specified reservation_id was not found"}, 422)
        return

    if len(parts) == 3 and parts[1] == "conditions":
        conditions = fixtures.get(CONDITIONS_KEY, [])
        for index, condition in enumerate(conditions):
            if condition.get("id") == _int(parts[2]):
                del conditions[index]
                state.record_reservation_condition_delete(condition["id"])
                _no_content(handler)
                return
        handler._send_json(
            {"detail": "Specified reservation_condition_id was not found"}, 422
        )
        return

    _not_found(handler)


def _int(value) -> int:
    try:
        return int(value)
    except (TypeError, ValueError):
        return -1
