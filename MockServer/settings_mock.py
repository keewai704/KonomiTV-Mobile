"""In-memory server settings for the mock KonomiTV server.

Implements SettingsRouter's `GET/PUT /api/settings/server`:

* GET is anonymous (like the real server), so the screen can render before the
  administrator check finishes.
* PUT is administrator only and stores the body for `GET /__mock/stats`
  (`server_settings_put_count`, `last_server_settings`).
"""

from __future__ import annotations

import copy


def default_server_settings() -> dict:
    """The shape of app.config.ServerSettings with its default values."""
    return {
        "general": {
            "backend": "EDCB",
            "always_receive_tv_from_mirakurun": False,
            "edcb_url": "tcp://127.0.0.1:4510/",
            "mirakurun_url": "http://127.0.0.1:40772/",
            "encoder": "FFmpeg",
            "program_update_interval": 5.0,
            "debug": False,
            "debug_encoder": False,
        },
        "server": {
            "port": 7000,
            "custom_https_certificate": None,
            "custom_https_private_key": None,
        },
        "tv": {
            "preferred_terrestrial_region": None,
            "max_alive_time": 10,
            "debug_mode_ts_path": None,
        },
        "video": {
            "recorded_folders": ["/recorded"],
            "exclude_scan_paths": [],
            "recorded_folders_polling_interval": 5.0,
        },
        "capture": {
            "upload_folders": ["/captures"],
            "upload_folders_polling_interval": 0.0,
        },
    }


def reset(state) -> None:
    state.server_settings = default_server_settings()


def handle(handler, method: str, parts: list[str], query: dict,
           fixtures: dict, state) -> bool:
    if parts != ["settings", "server"]:
        return False

    if method == "GET":
        handler._send_json(copy.deepcopy(state.server_settings))
        return True

    if method == "PUT":
        if handler._require_admin(fixtures) is None:
            return True
        body = handler._read_json_body()
        if not isinstance(body, dict):
            handler._send_json({"detail": "Invalid server settings"}, 422)
            return True
        general = body.get("general") or {}
        backend = general.get("backend", "EDCB")
        if backend not in ("EDCB", "Mirakurun"):
            handler._send_json({"detail": "Specified backend is invalid"}, 422)
            return True
        port = (body.get("server") or {}).get("port", 7000)
        if not isinstance(port, int) or isinstance(port, bool) or not (1024 <= port <= 65525):
            handler._send_json({"detail": "Specified port is invalid"}, 422)
            return True
        with state.lock:
            state.server_settings_put_count += 1
            state.last_server_settings = copy.deepcopy(body)
            # Merge into the stored settings so a later GET shows the change,
            # just like SaveConfig() updates config.yaml.
            merged = copy.deepcopy(state.server_settings)
            for section, values in body.items():
                if isinstance(values, dict) and isinstance(merged.get(section), dict):
                    merged[section].update(copy.deepcopy(values))
                else:
                    merged[section] = copy.deepcopy(values)
            state.server_settings = merged
        handler.send_response(204)
        handler.send_header("Content-Length", "0")
        handler.end_headers()
        return True

    return False
