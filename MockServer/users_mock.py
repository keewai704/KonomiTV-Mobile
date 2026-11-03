"""In-memory accounts for the mock KonomiTV server.

Implements UsersRouter:

* `POST /api/users`               account creation (first account is admin)
* `POST /api/users/token`         OAuth2 style login
* `GET  /api/users/me`            the logged in account
* `PUT  /api/users/me`            rename / change password
* `GET/PUT /api/users/me/icon`    avatar download / upload
* `DELETE /api/users/me`          delete the logged in account
* `GET  /api/users`               account list (admin only)
* `GET/PUT/DELETE /api/users/{username}` and `.../icon` (admin only)

Accounts live in memory for the lifetime of the process and are restored by
POST /__mock/reset. The fixture account (user.json) is the administrator and
keeps the fixed token the other mock modules and the UI tests use; additional
accounts get `mock-access-token-{id}`.
"""

from __future__ import annotations

import copy
from urllib.parse import parse_qs, unquote

import captures_mock
import twitter_mock

PROFILE_KEYS = (
    "id",
    "name",
    "is_admin",
    "niconico_user_id",
    "niconico_user_name",
    "niconico_user_premium",
    "twitter_accounts",
    "bluesky_accounts",
    "account_links",
    "created_at",
    "updated_at",
)

# Second account, so the administrator's user management screen has somebody
# to show / edit / delete.
SECOND_USER = {
    "id": 2,
    "name": "ビューア",
    "is_admin": False,
    "niconico_user_id": None,
    "niconico_user_name": None,
    "niconico_user_premium": None,
    "twitter_accounts": [],
    "bluesky_accounts": [],
    "account_links": [],
    "created_at": "2025-11-03T21:00:00+09:00",
    "updated_at": "2026-11-03T21:00:00+09:00",
    "password": "viewer",
}


# ---------------------------------------------------------------------------
# State
# ---------------------------------------------------------------------------

def reset(state, primary_user: dict, access_token: str) -> None:
    """Install the fixture account and the second account."""
    primary_user.setdefault("id", 1)
    primary_user.setdefault("password", "test")
    state.users = [primary_user, copy.deepcopy(SECOND_USER)]
    state.primary_user_id = primary_user["id"]
    state.primary_token = access_token
    state.access_tokens = {access_token: primary_user["id"]}
    state.user_icons = {}


def _find_user(state, username: str) -> dict | None:
    return next((user for user in state.users if user.get("name") == username), None)


def _find_user_by_id(state, user_id: int) -> dict | None:
    return next((user for user in state.users if user.get("id") == user_id), None)


def _payload(handler, fixtures: dict, user: dict) -> dict:
    """A response body for schemas.User (with the Twitter / Bluesky lists)."""
    if user.get("id") == fixtures["user"].get("id"):
        payload = twitter_mock.user_payload(fixtures, handler)
        payload.pop("password", None)
        return payload
    payload = {key: copy.deepcopy(user.get(key)) for key in PROFILE_KEYS}
    payload["twitter_accounts"] = []
    payload["bluesky_accounts"] = []
    payload["account_links"] = []
    return payload


def _issue_token(state, user: dict) -> str:
    if user.get("id") == state.primary_user_id:
        token = state.primary_token
    else:
        token = f"mock-access-token-{user.get('id')}"
    state.access_tokens[token] = user.get("id")
    return token


def _delete(state, user: dict) -> None:
    state.users = [entry for entry in state.users if entry.get("id") != user.get("id")]
    state.access_tokens = {
        token: user_id
        for token, user_id in state.access_tokens.items()
        if user_id != user.get("id")
    }
    state.user_icons.pop(user.get("id"), None)
    # The real server hands the admin flag to the youngest remaining account
    # when the last administrator disappears.
    if state.users and not any(entry.get("is_admin") for entry in state.users):
        youngest = min(state.users, key=lambda entry: entry.get("id", 0))
        youngest["is_admin"] = True


def _icon(state, user: dict) -> bytes:
    stored = state.user_icons.get(user.get("id"))
    if stored is not None:
        return stored
    return captures_mock.build_capture_png(user.get("id", 1) + 10, width=64, height=64)


# ---------------------------------------------------------------------------
# Dispatch
# ---------------------------------------------------------------------------

def handle(handler, method: str, parts: list[str], query: dict,
           fixtures: dict, state) -> bool:
    if not parts or parts[0] != "users":
        return False

    # POST /api/users/token (OAuth2 password form, anonymous)
    if parts == ["users", "token"] and method == "POST":
        length = int(handler.headers.get("Content-Length") or 0)
        raw = handler.rfile.read(length) if length > 0 else b""
        form = parse_qs(raw.decode("utf-8", "replace"), keep_blank_values=True)
        username = (form.get("username") or [""])[0]
        password = (form.get("password") or [""])[0]

        primary = _find_user_by_id(state, state.primary_user_id)
        user = None
        # The UI tests log in with test / test; the fixture account is also
        # reachable by its display name.
        if primary is not None and username in ("test", primary.get("name")):
            if password == primary.get("password", "test"):
                user = primary
        if user is None:
            candidate = _find_user(state, username)
            if candidate is not None and candidate.get("password") == password:
                user = candidate
        if user is None:
            handler._send_json({"detail": "Incorrect username or password"}, 401)
            return True
        handler._send_json(
            {"access_token": _issue_token(state, user), "token_type": "bearer"}
        )
        return True

    # POST /api/users (anonymous)
    if parts == ["users"] and method == "POST":
        body = handler._read_json_body()
        username = body.get("username")
        password = body.get("password")
        if not isinstance(username, str) or not isinstance(password, str):
            handler._send_json({"detail": "Invalid request body"}, 422)
            return True
        if _find_user(state, username) is not None:
            handler._send_json({"detail": "Specified username is duplicated"}, 422)
            return True
        if username.lower() in ("me", "token"):
            handler._send_json({"detail": "Specified username is not permitted"}, 422)
            return True
        next_id = max((user.get("id", 0) for user in state.users), default=0) + 1
        user = {
            "id": next_id,
            "name": username,
            "is_admin": not state.users,
            "niconico_user_id": None,
            "niconico_user_name": None,
            "niconico_user_premium": None,
            "twitter_accounts": [],
            "bluesky_accounts": [],
            "account_links": [],
            "created_at": "2026-11-04T12:00:00+09:00",
            "updated_at": "2026-11-04T12:00:00+09:00",
            "password": password,
        }
        state.users.append(user)
        with state.lock:
            state.user_create_count += 1
            state.created_usernames.append(username)
        handler._send_json(_payload(handler, fixtures, user), 201)
        return True

    # GET /api/users (administrator only)
    if parts == ["users"] and method == "GET":
        if handler._require_admin(fixtures) is None:
            return True
        handler._send_json([_payload(handler, fixtures, user) for user in state.users])
        return True

    # The remaining routes are /me or /{username}, optionally followed by icon.
    if len(parts) == 2:
        target = unquote(parts[1])
        is_icon = False
    elif len(parts) == 3 and parts[2] == "icon":
        target = unquote(parts[1])
        is_icon = True
    else:
        # Account links and anything else are handled by twitter_mock.
        return False

    if target == "me":
        user = handler._require_user(fixtures)
        if user is None:
            return True
    else:
        if handler._require_admin(fixtures) is None:
            return True
        user = _find_user(state, target)
        if user is None:
            handler._send_json({"detail": "Specified user was not found"}, 422)
            return True

    # GET /api/users/me/icon or /api/users/{username}/icon
    if is_icon and method == "GET":
        handler._send_bytes(_icon(state, user), "image/png", cache="no-store")
        return True

    # PUT /api/users/me/icon (multipart/form-data, file field "image")
    if is_icon and method == "PUT" and target == "me":
        content_type = handler.headers.get("Content-Type") or ""
        if not content_type.startswith("multipart/form-data"):
            handler._send_json({"detail": "Please upload JPEG or PNG image"}, 422)
            return True
        length = int(handler.headers.get("Content-Length") or 0)
        raw = handler.rfile.read(length) if length > 0 else b""
        fields = captures_mock.parse_multipart(content_type, raw)
        files = fields.get("image") or []
        if not files:
            handler._send_json({"detail": "Please upload JPEG or PNG image"}, 422)
            return True
        uploaded = files[0]
        image_type = uploaded.get("content_type") or ""
        if image_type not in ("image/png", "image/jpeg"):
            handler._send_json({"detail": "Please upload JPEG or PNG image"}, 422)
            return True
        state.user_icons[user.get("id")] = uploaded["data"]
        with state.lock:
            state.user_icon_update_count += 1
            state.last_user_icon = {
                "content_type": image_type,
                "filename": uploaded.get("filename"),
                "size": len(uploaded["data"]),
            }
        handler.send_response(204)
        handler.send_header("Content-Length", "0")
        handler.end_headers()
        return True

    # GET /api/users/me or /api/users/{username}
    if method == "GET":
        handler._send_json(_payload(handler, fixtures, user))
        return True

    # PUT /api/users/me: rename and/or change the password
    if method == "PUT" and target == "me":
        body = handler._read_json_body()
        username = body.get("username")
        password = body.get("password")
        if isinstance(username, str):
            if username != user.get("name") and _find_user(state, username) is not None:
                handler._send_json({"detail": "Specified username is duplicated"}, 422)
                return True
            if username.lower() in ("me", "token"):
                handler._send_json({"detail": "Specified username is not permitted"}, 422)
                return True
            user["name"] = username
        if isinstance(password, str):
            user["password"] = password
        with state.lock:
            state.user_update_count += 1
            state.last_user_update = {"username": username, "password": password}
        handler.send_response(204)
        handler.send_header("Content-Length", "0")
        handler.end_headers()
        return True

    # PUT /api/users/{username}: grant / revoke the admin flag
    if method == "PUT":
        body = handler._read_json_body()
        is_admin = body.get("is_admin")
        if not isinstance(is_admin, bool):
            handler._send_json({"detail": "Invalid request body"}, 422)
            return True
        if is_admin is False:
            remaining = [
                entry for entry in state.users
                if entry.get("is_admin") and entry.get("id") != user.get("id")
            ]
            if not remaining:
                handler._send_json(
                    {
                        "detail": (
                            "Cannot revoke admin permission because there are no more admins"
                        )
                    },
                    422,
                )
                return True
        user["is_admin"] = is_admin
        with state.lock:
            state.user_admin_update_count += 1
        handler.send_response(204)
        handler.send_header("Content-Length", "0")
        handler.end_headers()
        return True

    # DELETE /api/users/me or /api/users/{username}
    if method == "DELETE":
        name = user.get("name", "")
        _delete(state, user)
        with state.lock:
            state.user_delete_count += 1
            state.deleted_usernames.append(name)
        handler.send_response(204)
        handler.send_header("Content-Length", "0")
        handler.end_headers()
        return True

    return False
