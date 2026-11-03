"""In-memory Twitter / Bluesky mock for the KonomiTV mock server.

Implements the endpoints the iOS client uses:

* TwitterRouter   (cookie auth, keep-alive, post, retweet, favorite, timeline,
                   search, unlink)
* BlueskyRouter   (App Password auth, post, repost, like, timeline, search,
                   unlink)
* UsersRouter     (/users/me account lists and account links)

Tweets, posts and accounts live in memory for the lifetime of the process (and
are reset by POST /__mock/reset). The fixture images are generated PNGs, so no
binary fixtures are needed.
"""

from __future__ import annotations

import hashlib
import json
from datetime import datetime, timedelta, timezone
from urllib.parse import unquote

import captures_mock

JST = timezone(timedelta(hours=9))

# The mock Twitter account created by /api/twitter/auth.
MOCK_TWITTER_SCREEN_NAME = "konomi_tv"
MOCK_TWITTER_NAME = "KonomiTV モック"
# The default Bluesky account created by /api/bluesky/auth.
MOCK_BLUESKY_HANDLE = "mock.bsky.social"
MOCK_BLUESKY_NAME = "モック Bluesky"

# Posted tweets / posts are counted into /__mock/stats, so the UI tests can
# verify what actually reached the server.
MAX_IMAGE_COUNT = 4

PAGE_SIZE = 2


# ---------------------------------------------------------------------------
# Fixtures
# ---------------------------------------------------------------------------

def build_fixtures() -> dict:
    """Initial Twitter / Bluesky state, merged into the server fixtures."""
    return {
        "twitter": {
            "accounts": [],
            "bluesky_accounts": [],
            "account_links": [],
            "next_twitter_id": 1,
            "next_bluesky_id": 1,
            "next_link_id": 1,
            "next_tweet_id": 1001,
            "next_post_id": 1,
        }
    }


def _now() -> datetime:
    return datetime.now(JST).replace(microsecond=0)


def _iso(value: datetime) -> str:
    return value.isoformat()


def _user(name: str, screen_name: str, icon_seed: int,
          source: str = "Twitter", user_id: str | None = None) -> dict:
    return {
        "source": source,
        "id": user_id or f"user-{icon_seed}",
        "name": name,
        "screen_name": screen_name,
        "icon_url": f"/__mock/twitter/icon/{icon_seed}.png",
    }


def _tweet(
    tweet_id: str,
    user: dict,
    text: str,
    created_at: datetime,
    *,
    source: str = "Twitter",
    image_seeds: list[int] | None = None,
    retweet_count: int = 0,
    retweeted: bool = False,
    favorite_count: int = 0,
    favorited: bool = False,
    retweeted_tweet: dict | None = None,
    quoted_tweet: dict | None = None,
) -> dict:
    return {
        "source": source,
        "id": tweet_id,
        "created_at": _iso(created_at),
        "user": user,
        "text": text,
        "lang": "ja",
        "via": "KonomiTV Mock",
        "image_urls": [
            f"/__mock/twitter/image/{seed}.png" for seed in (image_seeds or [])
        ],
        "movie_url": None,
        "retweet_count": retweet_count,
        "retweeted": retweeted,
        "favorite_count": favorite_count,
        "favorited": favorited,
        "retweeted_tweet": retweeted_tweet,
        "quoted_tweet": quoted_tweet,
    }


def _quoted_tweet(created_at: datetime) -> dict:
    return _tweet(
        "tweet-0900",
        _user("引用元ユーザー", "quoted_user", 9),
        "引用されたツイートです。",
        created_at,
    )


def fixture_tweets() -> list[dict]:
    """Home timeline / search fixtures (oldest last)."""
    now = _now()
    quoted = _quoted_tweet(now - timedelta(minutes=30))
    original = _tweet(
        "tweet-1003",
        _user("オリジナル", "original", 3),
        "画像付きのツイート #anime",
        now - timedelta(minutes=4),
        image_seeds=[3],
        retweet_count=2,
        favorite_count=7,
        quoted_tweet=quoted,
    )
    repost = _tweet(
        "tweet-1002",
        _user("まとめアカウント", "matome", 2),
        "RT @original: 画像付きのツイート #anime",
        now - timedelta(minutes=3),
        retweeted_tweet=original,
    )
    first = _tweet(
        "tweet-1001",
        _user("実況ファン", "jikkyo_fan", 1),
        "こんばんは！ #nhk で実況中です",
        now - timedelta(minutes=2),
        favorite_count=5,
    )
    search_only = _tweet(
        "tweet-1000",
        _user("検索用", "search_user", 4),
        "検索用のツイート #nhk",
        now - timedelta(minutes=1),
    )
    return [search_only, first, repost, original]


def fixture_posts() -> list[dict]:
    """Bluesky home timeline / search fixtures (oldest last)."""
    now = _now()
    original = _tweet(
        "at://did:plc:mockbob/app.bsky.feed.post/bsky-2",
        _user("ボブ", "bob.bsky.social", 6, source="Bluesky",
              user_id="did:plc:mockbob"),
        "Bluesky の投稿です #nhk",
        now - timedelta(minutes=6),
        source="Bluesky",
        retweet_count=1,
        favorite_count=2,
    )
    repost = _tweet(
        "at://did:plc:mockalice/app.bsky.feed.post/bsky-repost",
        _user("アリス", "alice.bsky.social", 5, source="Bluesky",
              user_id="did:plc:mockalice"),
        "リポスト",
        now - timedelta(minutes=5),
        source="Bluesky",
        retweeted_tweet=original,
    )
    first = _tweet(
        "at://did:plc:mockalice/app.bsky.feed.post/bsky-1",
        _user("アリス", "alice.bsky.social", 5, source="Bluesky",
              user_id="did:plc:mockalice"),
        "こんばんは！ #nhk で実況中です",
        now - timedelta(minutes=1),
        source="Bluesky",
        favorite_count=3,
    )
    return [first, repost, original]


# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

def _data(fixtures: dict) -> dict:
    data = fixtures.get("twitter")
    if data is None:
        data = build_fixtures()["twitter"]
        fixtures["twitter"] = data
    return data


def base_url(handler) -> str:
    host = handler.headers.get("Host") or "127.0.0.1"
    return f"http://{host}"


def _absolutize(handler, value):
    """Prefix relative /__mock/twitter/... URLs with the request's origin."""
    if handler is None:
        return value
    origin = base_url(handler)
    if isinstance(value, str):
        if value.startswith("/"):
            return origin + value
        return value
    if isinstance(value, list):
        return [_absolutize(handler, item) for item in value]
    if isinstance(value, dict):
        return {key: _absolutize(handler, item) for key, item in value.items()}
    return value


def _send(handler, obj, status: int = 200) -> None:
    handler._send_json(_absolutize(handler, obj), status)


def _error(handler, status: int, detail: str) -> None:
    handler._send_json({"detail": detail}, status)


def _no_content(handler) -> None:
    handler.send_response(204)
    handler.send_header("Content-Length", "0")
    handler.end_headers()


def _read_body(handler) -> bytes:
    length = int(handler.headers.get("Content-Length") or 0)
    return handler.rfile.read(length) if length > 0 else b""


def _read_json(handler) -> dict:
    raw = _read_body(handler)
    if not raw:
        return {}
    try:
        value = json.loads(raw.decode("utf-8"))
    except (ValueError, UnicodeDecodeError):
        return {}
    return value if isinstance(value, dict) else {}


def _read_form(handler) -> dict[str, list[dict]]:
    return captures_mock.parse_multipart(
        handler.headers.get("Content-Type") or "",
        _read_body(handler),
    )


def _form_text(fields: dict[str, list[dict]], name: str) -> str | None:
    parts = fields.get(name) or []
    if not parts:
        return None
    return (parts[0].get("data") or b"").decode("utf-8", "replace")


def _twitter_account(data: dict, screen_name: str) -> dict | None:
    for account in data["accounts"]:
        if account["screen_name"] == screen_name:
            return account
    return None


def _bluesky_account(data: dict, handle: str) -> dict | None:
    normalized = handle.lower()
    for account in data["bluesky_accounts"]:
        if account["handle"].lower() == normalized:
            return account
    return None


def _account_link_payload(data: dict, link: dict) -> dict:
    twitter = next(
        (a for a in data["accounts"] if a["id"] == link["twitter_account_id"]),
        None,
    )
    bluesky = next(
        (a for a in data["bluesky_accounts"] if a["id"] == link["bluesky_account_id"]),
        None,
    )
    return {
        "id": link["id"],
        "twitter_account": twitter,
        "bluesky_account": bluesky,
        "created_at": link["created_at"],
        "updated_at": link["updated_at"],
    }


def user_payload(fixtures: dict, handler=None) -> dict:
    """GET /api/users/me with the Twitter / Bluesky additions."""
    user = dict(fixtures["user"])
    data = _data(fixtures)
    user["twitter_accounts"] = [dict(a) for a in data["accounts"]]
    user["bluesky_accounts"] = [dict(a) for a in data["bluesky_accounts"]]
    user["account_links"] = [
        _account_link_payload(data, link) for link in data["account_links"]
    ]
    return _absolutize(handler, user)


# ---------------------------------------------------------------------------
# Images
# ---------------------------------------------------------------------------

def handle_mock_image(handler, path: str) -> bool:
    """Serve the generated avatars / tweet images."""
    parts = [part for part in path.split("/") if part]
    if len(parts) != 4 or parts[0] != "__mock" or parts[1] != "twitter":
        return False
    kind = parts[2]
    try:
        seed = int(parts[3].split(".")[0])
    except (TypeError, ValueError):
        return False
    if kind == "icon":
        data = captures_mock.build_capture_png(seed, width=96, height=96)
    elif kind == "image":
        data = captures_mock.build_capture_png(seed, width=320, height=180)
    else:
        return False
    handler._send_bytes(data, "image/png", cache="max-age=3600")
    return True


# ---------------------------------------------------------------------------
# Pagination
# ---------------------------------------------------------------------------

def _page(tweets: list[dict], cursor_id: str | None, detail: str) -> dict:
    start = 0
    if cursor_id and cursor_id.startswith("page-"):
        try:
            start = int(cursor_id.split("-", 1)[1])
        except ValueError:
            start = 0
    page = tweets[start:start + PAGE_SIZE]
    next_start = start + PAGE_SIZE
    load_more = []
    if next_start < len(tweets):
        load_more.append({
            "cursor_type": "Older",
            "cursor_id": f"page-{next_start}",
            "entry_id": None,
            "upper_created_at": page[-1]["created_at"] if page else None,
            "lower_created_at": None,
        })
    return {
        "is_success": True,
        "detail": detail,
        "tweets": page,
        "newer_cursor_id": None,
        "load_more_cursors": load_more,
        "is_cursor_consumed": True,
    }


def _matches(text: str, query: str) -> bool:
    needle = query.replace("include:nativeretweets", "").strip().lower()
    needle = needle.lstrip("#")
    if not needle:
        return True
    return needle in text.lower()


# ---------------------------------------------------------------------------
# Twitter routes
# ---------------------------------------------------------------------------

def _handle_twitter(handler, method: str, parts: list[str], query: dict,
                    fixtures: dict, state) -> bool:
    data = _data(fixtures)

    # POST /twitter/auth
    if method == "POST" and parts == ["twitter", "auth"]:
        if handler._require_user(fixtures) is None:
            return True
        body = _read_json(handler)
        cookies = body.get("cookies_txt") or ""
        if "x.com" not in cookies:
            _error(handler, 422, "No valid cookies found in the provided cookies.txt")
            return True
        existing = _twitter_account(data, MOCK_TWITTER_SCREEN_NAME)
        if existing is None:
            account = {
                "id": data["next_twitter_id"],
                "name": MOCK_TWITTER_NAME,
                "screen_name": MOCK_TWITTER_SCREEN_NAME,
                "icon_url": "/__mock/twitter/icon/1.png",
                "created_at": _iso(_now()),
                "updated_at": _iso(_now()),
            }
            data["next_twitter_id"] += 1
            data["accounts"].append(account)
        with state.lock:
            state.twitter_auth_count += 1
        _no_content(handler)
        return True

    if len(parts) < 3 or parts[0] != "twitter" or parts[1] != "accounts":
        return False

    if handler._require_user(fixtures) is None:
        return True

    screen_name = parts[2]
    account = _twitter_account(data, screen_name)

    # DELETE /twitter/accounts/{screen_name}
    if method == "DELETE" and len(parts) == 3:
        if account is None:
            _error(handler, 422, "TwitterAccount associated with screen_name does not exist")
            return True
        data["accounts"].remove(account)
        data["account_links"] = [
            link for link in data["account_links"]
            if link["twitter_account_id"] != account["id"]
        ]
        with state.lock:
            state.twitter_account_delete_count += 1
        _no_content(handler)
        return True

    if account is None:
        _error(handler, 422, "TwitterAccount associated with screen_name does not exist")
        return True

    # POST /twitter/accounts/{screen_name}/keep-alive
    if method == "POST" and parts[3:] == ["keep-alive"]:
        with state.lock:
            state.twitter_keep_alive_count += 1
        _no_content(handler)
        return True

    # POST /twitter/accounts/{screen_name}/tweets
    if method == "POST" and parts[3:] == ["tweets"]:
        fields = _read_form(handler)
        text = _form_text(fields, "tweet") or ""
        images = fields.get("images") or []
        if len(images) > MAX_IMAGE_COUNT:
            _error(handler, 422, "Can tweet up to 4 images")
            return True
        if not text.strip() and not images:
            _error(handler, 422, "Tweet text or images are required")
            return True
        reply_to = _form_text(fields, "in_reply_to_status_id") or None
        with state.lock:
            tweet_id = str(data["next_tweet_id"])
            data["next_tweet_id"] += 1
            state.twitter_posted_tweets.append({
                "screen_name": screen_name,
                "tweet_id": tweet_id,
                "text": text,
                "image_count": len(images),
                "image_sizes": [len(part.get("data") or b"") for part in images],
                "image_filenames": [part.get("filename") for part in images],
                "in_reply_to_status_id": reply_to,
            })
        _send(handler, {
            "is_success": True,
            "detail": f"ツイートしました (モック #{tweet_id})",
            "tweet_url": f"https://x.com/{screen_name}/status/{tweet_id}",
            "tweet_id": tweet_id,
            "post_uri": None,
            "post_cid": None,
        })
        return True

    # PUT / DELETE /twitter/accounts/{screen_name}/tweets/{tweet_id}/{action}
    if len(parts) == 6 and parts[3] == "tweets" and method in ("PUT", "DELETE"):
        tweet_id, action = parts[4], parts[5]
        if action not in ("retweet", "favorite"):
            return False
        with state.lock:
            if action == "retweet":
                key = "retweet" if method == "PUT" else "unretweet"
            else:
                key = "favorite" if method == "PUT" else "unfavorite"
            if key == "retweet":
                state.twitter_retweet_count += 1
            elif key == "unretweet":
                state.twitter_unretweet_count += 1
            elif key == "favorite":
                state.twitter_favorite_count += 1
            else:
                state.twitter_unfavorite_count += 1
            state.twitter_reaction_events.append({
                "action": key,
                "tweet_id": tweet_id,
                "screen_name": screen_name,
            })
        _send(handler, {
            "is_success": True,
            "detail": "モックの操作に成功しました",
        })
        return True

    # GET /twitter/accounts/{screen_name}/timeline
    if method == "GET" and parts[3:] == ["timeline"]:
        cursor_id = (query.get("cursor_id") or [None])[0]
        _send(handler, _page(fixture_tweets(), cursor_id, "モックのタイムライン"))
        return True

    # GET /twitter/accounts/{screen_name}/search
    if method == "GET" and parts[3:] == ["search"]:
        search_query = (query.get("query") or [""])[0]
        cursor_id = (query.get("cursor_id") or [None])[0]
        matched = [
            tweet for tweet in fixture_tweets()
            if _matches(tweet["text"], search_query)
        ]
        _send(handler, _page(matched, cursor_id, "モックの検索結果"))
        return True

    return False


# ---------------------------------------------------------------------------
# Bluesky routes
# ---------------------------------------------------------------------------

def _bluesky_did(handle: str) -> str:
    digest = hashlib.sha1(handle.encode("utf-8")).hexdigest()[:12]
    return f"did:plc:{digest}"


def _handle_bluesky(handler, method: str, parts: list[str], query: dict,
                    fixtures: dict, state) -> bool:
    data = _data(fixtures)

    # POST /bluesky/auth
    if method == "POST" and parts == ["bluesky", "auth"]:
        if handler._require_user(fixtures) is None:
            return True
        body = _read_json(handler)
        handle = (body.get("handle") or "").strip().lstrip("@")
        app_password = body.get("app_password") or ""
        if not handle or not app_password:
            _error(handler, 422, "Failed to login to Bluesky")
            return True
        existing = _bluesky_account(data, handle)
        if existing is None:
            did = _bluesky_did(handle.lower())
            account = {
                "id": data["next_bluesky_id"],
                "did": did,
                "handle": handle,
                "name": handle.split(".")[0].capitalize(),
                "icon_url": "/__mock/twitter/icon/5.png",
                "created_at": _iso(_now()),
                "updated_at": _iso(_now()),
            }
            data["next_bluesky_id"] += 1
            data["bluesky_accounts"].append(account)
        with state.lock:
            state.bluesky_auth_count += 1
        _no_content(handler)
        return True

    if len(parts) < 3 or parts[0] != "bluesky" or parts[1] != "accounts":
        return False

    if handler._require_user(fixtures) is None:
        return True

    handle = parts[2]
    account = _bluesky_account(data, handle)

    # DELETE /bluesky/accounts/{handle}
    if method == "DELETE" and len(parts) == 3:
        if account is None:
            _error(handler, 422, "BlueskyAccount associated with handle does not exist")
            return True
        data["bluesky_accounts"].remove(account)
        data["account_links"] = [
            link for link in data["account_links"]
            if link["bluesky_account_id"] != account["id"]
        ]
        with state.lock:
            state.bluesky_account_delete_count += 1
        _no_content(handler)
        return True

    if account is None:
        _error(handler, 422, "BlueskyAccount associated with handle does not exist")
        return True

    # POST /bluesky/accounts/{handle}/posts
    if method == "POST" and parts[3:] == ["posts"]:
        fields = _read_form(handler)
        text = _form_text(fields, "post") or ""
        images = fields.get("images") or []
        if len(images) > MAX_IMAGE_COUNT:
            _error(handler, 422, "Bluesky では画像は 4 枚まで添付できます。")
            return True
        if not text.strip() and not images:
            _error(handler, 422, "投稿本文または画像を指定してください。")
            return True
        reply_fields = [
            _form_text(fields, name)
            for name in (
                "reply_root_uri",
                "reply_root_cid",
                "reply_parent_uri",
                "reply_parent_cid",
            )
        ]
        if any(value for value in reply_fields) and not all(reply_fields):
            _error(
                handler,
                422,
                "reply_root_uri / reply_root_cid / reply_parent_uri / "
                "reply_parent_cid must all be specified together.",
            )
            return True
        with state.lock:
            post_id = data["next_post_id"]
            data["next_post_id"] += 1
            record_key = f"mock{post_id}"
            post_uri = f"at://{account['did']}/app.bsky.feed.post/{record_key}"
            state.bluesky_posted_posts.append({
                "handle": account["handle"],
                "post_uri": post_uri,
                "post_cid": f"cid-{record_key}",
                "text": text,
                "image_count": len(images),
                "image_sizes": [len(part.get("data") or b"") for part in images],
                "reply_root_uri": reply_fields[0],
                "reply_parent_uri": reply_fields[2],
            })
        _send(handler, {
            "is_success": True,
            "detail": f"ポストしました (モック {record_key})",
            "tweet_url": "",
            "tweet_id": None,
            "post_uri": post_uri,
            "post_cid": f"cid-{record_key}",
        })
        return True

    # PUT / DELETE /bluesky/accounts/{handle}/posts/{post_id}/{action}
    if method in ("PUT", "DELETE") and len(parts) >= 6 and parts[3] == "posts":
        action = parts[-1]
        if action not in ("repost", "like"):
            return False
        with state.lock:
            if action == "repost":
                if method == "PUT":
                    state.bluesky_repost_count += 1
                else:
                    state.bluesky_unrepost_count += 1
            else:
                if method == "PUT":
                    state.bluesky_like_count += 1
                else:
                    state.bluesky_unlike_count += 1
            state.bluesky_reaction_events.append({
                "action": action if method == "PUT" else f"un{action}",
                "post_id": "/".join(parts[4:-1]),
                "handle": account["handle"],
            })
        _send(handler, {
            "is_success": True,
            "detail": "モックの操作に成功しました",
        })
        return True

    # GET /bluesky/accounts/{handle}/timeline
    if method == "GET" and parts[3:] == ["timeline"]:
        cursor_id = (query.get("cursor_id") or [None])[0]
        _send(handler, _page(fixture_posts(), cursor_id, "モックのタイムライン"))
        return True

    # GET /bluesky/accounts/{handle}/search
    if method == "GET" and parts[3:] == ["search"]:
        search_query = (query.get("query") or [""])[0]
        cursor_id = (query.get("cursor_id") or [None])[0]
        matched = [
            post for post in fixture_posts()
            if _matches(post["text"], search_query)
        ]
        _send(handler, _page(matched, cursor_id, "モックの検索結果"))
        return True

    return False


# ---------------------------------------------------------------------------
# Account links
# ---------------------------------------------------------------------------

def _handle_account_links(handler, method: str, parts: list[str],
                          fixtures: dict, state) -> bool:
    if method not in ("POST", "DELETE"):
        return False

    data = _data(fixtures)

    if handler._require_user(fixtures) is None:
        return True

    if method == "POST" and parts == ["users", "me", "account-links"]:
        body = _read_json(handler)
        twitter_id = body.get("twitter_account_id")
        bluesky_id = body.get("bluesky_account_id")
        twitter = next((a for a in data["accounts"] if a["id"] == twitter_id), None)
        bluesky = next(
            (a for a in data["bluesky_accounts"] if a["id"] == bluesky_id),
            None,
        )
        if twitter is None:
            _error(handler, 422, "Specified Twitter account does not exist")
            return True
        if bluesky is None:
            _error(handler, 422, "Specified Bluesky account does not exist")
            return True
        if any(link["twitter_account_id"] == twitter_id for link in data["account_links"]):
            _error(handler, 422, "Specified Twitter account is already linked")
            return True
        if any(link["bluesky_account_id"] == bluesky_id for link in data["account_links"]):
            _error(handler, 422, "Specified Bluesky account is already linked")
            return True
        link = {
            "id": data["next_link_id"],
            "twitter_account_id": twitter_id,
            "bluesky_account_id": bluesky_id,
            "created_at": _iso(_now()),
            "updated_at": _iso(_now()),
        }
        data["next_link_id"] += 1
        data["account_links"].append(link)
        with state.lock:
            state.account_link_create_count += 1
        _send(handler, _account_link_payload(data, link), 201)
        return True

    if method == "DELETE" and len(parts) == 4:
        try:
            link_id = int(parts[3])
        except (TypeError, ValueError):
            _error(handler, 422, "Specified account link does not exist")
            return True
        link = next(
            (item for item in data["account_links"] if item["id"] == link_id),
            None,
        )
        if link is None:
            _error(handler, 422, "Specified account link does not exist")
            return True
        data["account_links"].remove(link)
        with state.lock:
            state.account_link_delete_count += 1
        _no_content(handler)
        return True

    return False


# ---------------------------------------------------------------------------
# Dispatch
# ---------------------------------------------------------------------------

def handle(handler, method: str, parts: list[str], query: dict,
           fixtures: dict, state) -> bool:
    """Handle a Twitter / Bluesky / account link request.

    Returns True when the request was handled (including error responses).
    """
    if not parts:
        return False
    decoded = [unquote(part) for part in parts]
    if decoded[0] == "twitter":
        return _handle_twitter(handler, method, decoded, query, fixtures, state)
    if decoded[0] == "bluesky":
        return _handle_bluesky(handler, method, decoded, query, fixtures, state)
    if decoded[:3] == ["users", "me", "account-links"]:
        return _handle_account_links(handler, method, decoded, fixtures, state)
    return False
