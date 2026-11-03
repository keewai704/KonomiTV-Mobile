"""Maintenance tasks and log streaming for the mock KonomiTV server.

Implements MaintenanceRouter:

* `GET  /api/maintenance/logs/{server|access}`  Server-Sent Events stream
* `POST /api/maintenance/update-database`
* `POST /api/maintenance/{task}/run`            batch-scan, background-analysis,
                                                  capture-scan, database-vacuum
* `GET  /api/maintenance/{task}/status`
* `POST /api/maintenance/restart` / `shutdown`

The run routes answer immediately and simulate progress in a background thread,
so the app's status polling has something to show (the real server blocks the
request until the task finished).
"""

from __future__ import annotations

import json
import threading
import time

TASKS = ("batch-scan", "background-analysis", "capture-scan", "database-vacuum")

TASK_TOTALS = {
    "batch-scan": 8,
    "background-analysis": 5,
    "capture-scan": 3,
    "database-vacuum": 0,
}

ALREADY_RUNNING_DETAILS = {
    "batch-scan": "Batch scan of recording folders is already running",
    "background-analysis": "Background analysis task is already running",
    "capture-scan": "Batch scan of capture folders is already running",
    "database-vacuum": "Database vacuum is already running",
}

# The lines the log stream sends as initial_log_update, then log_update.
INITIAL_SERVER_LOG_LINES = [
    "2026-11-04 12:00:00 [INFO] KonomiTV Server (mock) starting...",
    "2026-11-04 12:00:00 [INFO] Backend: EDCB (tcp://127.0.0.1:4510/)",
    "2026-11-04 12:00:01 [INFO] Encoder: FFmpeg 8.0-mock",
    "2026-11-04 12:00:02 [INFO] KonomiTV Server (mock) started.",
]
STREAMED_LOG_LINES = [
    "2026-11-04 12:00:05 [INFO] Program update finished. (channels: 5, programs: 120)",
    "2026-11-04 12:00:10 [INFO] Recorded folder scan finished.",
    "2026-11-04 12:00:15 [INFO] Live stream: started encoding gr011.",
]
INITIAL_ACCESS_LOG_LINES = [
    '127.0.0.1 - "GET /api/version HTTP/1.1" 200',
    '127.0.0.1 - "GET /api/channels HTTP/1.1" 200',
]
STREAMED_ACCESS_LOG_LINES = [
    '127.0.0.1 - "GET /api/videos HTTP/1.1" 200',
    '127.0.0.1 - "GET /api/settings/client HTTP/1.1" 200',
    '127.0.0.1 - "POST /api/programs/search HTTP/1.1" 200',
]

# 進捗を進める間隔 (秒)
PROGRESS_STEP_SECONDS = 0.2


# ---------------------------------------------------------------------------
# State
# ---------------------------------------------------------------------------

def _idle_status() -> dict:
    return {
        "is_running": False,
        "processed_count": 0,
        "total_count": 0,
        "has_registered_files": True,
    }


def reset(state) -> None:
    state.maintenance_tasks = {task: _idle_status() for task in TASKS}
    state.maintenance_run_counts = {task: 0 for task in TASKS}
    state.maintenance_update_database_count = 0
    state.maintenance_restart_count = 0
    state.maintenance_shutdown_count = 0


def _simulate_progress(state, task: str) -> None:
    total = TASK_TOTALS.get(task, 0)
    steps = total if total > 0 else 8

    def worker() -> None:
        for index in range(1, steps + 1):
            time.sleep(PROGRESS_STEP_SECONDS)
            with state.lock:
                status = state.maintenance_tasks.get(task)
                if status is None:
                    return
                if total > 0:
                    status["processed_count"] = index
                status["total_count"] = total
        with state.lock:
            status = state.maintenance_tasks.get(task)
            if status is not None:
                status["is_running"] = False

    threading.Thread(target=worker, daemon=True).start()


# ---------------------------------------------------------------------------
# Dispatch
# ---------------------------------------------------------------------------

def handle(handler, method: str, parts: list[str], query: dict,
           fixtures: dict, state) -> bool:
    if not parts or parts[0] != "maintenance":
        return False

    # GET /api/maintenance/logs/{log_type}
    if len(parts) == 3 and parts[1] == "logs" and method == "GET":
        if handler._require_admin(fixtures) is None:
            return True
        log_type = parts[2]
        if log_type not in ("server", "access"):
            handler._not_found()
            return True
        _stream_logs(handler, log_type)
        return True

    action = parts[1] if len(parts) >= 2 else ""

    if action == "update-database" and method == "POST" and len(parts) == 2:
        with state.lock:
            state.maintenance_update_database_count += 1
        handler.send_response(204)
        handler.send_header("Content-Length", "0")
        handler.end_headers()
        return True

    if action == "restart" and method == "POST" and len(parts) == 2:
        with state.lock:
            state.maintenance_restart_count += 1
        handler.send_response(204)
        handler.send_header("Content-Length", "0")
        handler.end_headers()
        return True

    if action == "shutdown" and method == "POST" and len(parts) == 2:
        with state.lock:
            state.maintenance_shutdown_count += 1
        handler.send_response(204)
        handler.send_header("Content-Length", "0")
        handler.end_headers()
        return True

    # POST /api/maintenance/{task}/run
    if len(parts) == 3 and parts[2] == "run" and method == "POST":
        task = parts[1]
        if task not in TASKS:
            handler._not_found()
            return True
        with state.lock:
            status = state.maintenance_tasks[task]
            if status["is_running"]:
                already_running = True
            else:
                already_running = False
                status.update({
                    "is_running": True,
                    "processed_count": 0,
                    "total_count": TASK_TOTALS.get(task, 0),
                    "has_registered_files": True,
                })
                state.maintenance_run_counts[task] = (
                    state.maintenance_run_counts.get(task, 0) + 1
                )
        if already_running:
            handler._send_json(
                {"detail": ALREADY_RUNNING_DETAILS[task]},
                429,
            )
            return True
        _simulate_progress(state, task)
        handler.send_response(204)
        handler.send_header("Content-Length", "0")
        handler.end_headers()
        return True

    # GET /api/maintenance/{task}/status
    if len(parts) == 3 and parts[2] == "status" and method == "GET":
        task = parts[1]
        if task not in TASKS:
            handler._not_found()
            return True
        with state.lock:
            status = dict(state.maintenance_tasks[task])
        handler._send_json(status)
        return True

    return False


# ---------------------------------------------------------------------------
# Log streaming
# ---------------------------------------------------------------------------

def _stream_logs(handler, log_type: str) -> None:
    initial_lines = (
        INITIAL_SERVER_LOG_LINES if log_type == "server" else INITIAL_ACCESS_LOG_LINES
    )
    streamed_lines = (
        STREAMED_LOG_LINES if log_type == "server" else STREAMED_ACCESS_LOG_LINES
    )

    handler.send_response(200)
    handler.send_header("Content-Type", "text/event-stream; charset=utf-8")
    handler.send_header("Cache-Control", "no-store")
    handler.send_header("X-Accel-Buffering", "no")
    handler.send_header("Connection", "close")
    handler.end_headers()

    def write(payload: str) -> None:
        handler.wfile.write(payload.encode("utf-8"))
        handler.wfile.flush()

    def write_event(name: str, body: str) -> None:
        write(f"event: {name}\ndata: {body}\n\n")

    try:
        write_event(
            "initial_log_update",
            json.dumps(initial_lines, ensure_ascii=False),
        )
        index = 0
        while True:
            if handler._sleep_until_disconnected(0.5):
                return
            line = streamed_lines[index % len(streamed_lines)]
            index += 1
            write_event("log_update", json.dumps(line, ensure_ascii=False))
    except (BrokenPipeError, ConnectionResetError, OSError):
        pass
