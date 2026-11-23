#!/usr/bin/env python3
"""
Pegs of Ur — Global Standings, Turn-Based Online Rooms & Email-Linked Quota Server
Backed by SQLite WAL on Linode behind Traefik (https://bughouse-online.com/pegsofur-api)
Copyright (c) 2026 Fair Computing and Publishing, LLC.
"""

import hashlib
import json
import os
import re
import secrets
import sqlite3
import string
import threading
import time
import urllib.parse
import urllib.request
from datetime import datetime, timezone
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import parse_qs, urlparse

DB_PATH = os.environ.get("PEGSOFUR_DB_PATH", "/data/pegsofur.db")
PORT = int(os.environ.get("PORT", "8092"))
IP_SALT = os.environ.get("PEGSOFUR_SALT", "pegsofur-linode-2026-v1")
SUPPORTER_API_BASE = os.environ.get(
    "SUPPORTER_API_BASE", "http://fairplay-telemetry-prod:8091"
).rstrip("/")
FREE_DAILY_ONLINE_LIMIT = int(os.environ.get("FREE_DAILY_ONLINE_LIMIT", "5"))

EMAIL_RE = re.compile(r"^[a-zA-Z0-9._%+\-]{1,64}@[a-zA-Z0-9.\-]{1,120}\.[a-zA-Z]{2,24}$")
NAME_RE = re.compile(r"^[a-zA-Z0-9 _.\-]{2,32}$")
ROOM_CODE_RE = re.compile(r"^[A-Z0-9]{6}$")

_rate_lock = threading.Lock()
_ip_buckets: dict[str, list[float]] = {}


def check_rate_limit(ip_hash: str, bucket: str, max_reqs: int, window_sec: float) -> bool:
    now = time.time()
    key = f"{bucket}:{ip_hash}"
    with _rate_lock:
        if len(_ip_buckets) > 10000:
            _ip_buckets.clear()
        hist = [t for t in _ip_buckets.get(key, []) if now - t < window_sec]
        if len(hist) >= max_reqs:
            _ip_buckets[key] = hist
            return False
        hist.append(now)
        _ip_buckets[key] = hist
        return True


def today_utc_key() -> str:
    return datetime.now(timezone.utc).strftime("%Y-%m-%d")


def hash_identity(raw: str) -> str:
    return hashlib.sha256(f"{IP_SALT}:{raw.strip().lower()}".encode("utf-8")).hexdigest()[:24]


def get_db() -> sqlite3.Connection:
    os.makedirs(os.path.dirname(DB_PATH), exist_ok=True)
    conn = sqlite3.connect(DB_PATH, timeout=10.0)
    conn.row_factory = sqlite3.Row
    conn.execute("PRAGMA journal_mode=WAL;")
    conn.execute("PRAGMA synchronous=NORMAL;")
    return conn


def init_db() -> None:
    with get_db() as conn:
        conn.executescript(
            """
            CREATE TABLE IF NOT EXISTS standings (
                id INTEGER PRIMARY KEY AUTOINCREMENT,
                email_hash TEXT NOT NULL,
                display_name TEXT NOT NULL,
                mode TEXT NOT NULL,
                score INTEGER NOT NULL,
                rounds INTEGER NOT NULL DEFAULT 10,
                works_built INTEGER NOT NULL DEFAULT 0,
                advancements INTEGER NOT NULL DEFAULT 0,
                won INTEGER NOT NULL DEFAULT 0,
                created_at_ms INTEGER NOT NULL
            );
            CREATE INDEX IF NOT EXISTS idx_standings_mode_score
                ON standings (mode, score DESC, created_at_ms ASC);

            CREATE TABLE IF NOT EXISTS daily_quota (
                identity_hash TEXT NOT NULL,
                date_key TEXT NOT NULL,
                games_used INTEGER NOT NULL DEFAULT 0,
                updated_at_ms INTEGER NOT NULL,
                PRIMARY KEY (identity_hash, date_key)
            );

            CREATE TABLE IF NOT EXISTS rooms (
                code TEXT PRIMARY KEY,
                host_name TEXT NOT NULL,
                max_players INTEGER NOT NULL DEFAULT 2,
                status TEXT NOT NULL DEFAULT 'waiting',
                seed INTEGER NOT NULL,
                players_json TEXT NOT NULL,
                moves_json TEXT NOT NULL DEFAULT '[]',
                turn_seq INTEGER NOT NULL DEFAULT 0,
                created_at_ms INTEGER NOT NULL,
                updated_at_ms INTEGER NOT NULL
            );
            """
        )


def check_shared_supporter(email: str) -> tuple[bool, str]:
    """Query the shared FairPlay Radar / NewScid supporter SQLite service."""
    clean = email.strip().lower()
    if not clean:
        return False, ""
    try:
        url = f"{SUPPORTER_API_BASE}/v1/supporter?handle={urllib.parse.quote(clean)}&source=newscid"
        req = urllib.request.Request(url, headers={"Accept": "application/json", "User-Agent": "PegsOfUr/1.0"})
        with urllib.request.urlopen(req, timeout=2.0) as resp:
            if resp.status == 200:
                data = json.loads(resp.read().decode("utf-8"))
                if data.get("supported"):
                    return True, str(data.get("tierLabel") or "Supporter")
    except Exception:
        pass
    return False, ""


def get_daily_used(conn: sqlite3.Connection, identity_hash: str, date_key: str) -> int:
    row = conn.execute(
        "SELECT games_used FROM daily_quota WHERE identity_hash = ? AND date_key = ?",
        (identity_hash, date_key),
    ).fetchone()
    return int(row["games_used"]) if row else 0


def increment_daily_used(conn: sqlite3.Connection, identity_hash: str, date_key: str, now_ms: int) -> int:
    conn.execute(
        """
        INSERT INTO daily_quota (identity_hash, date_key, games_used, updated_at_ms)
        VALUES (?, ?, 1, ?)
        ON CONFLICT(identity_hash, date_key) DO UPDATE SET
            games_used = daily_quota.games_used + 1,
            updated_at_ms = excluded.updated_at_ms
        """,
        (identity_hash, date_key, now_ms),
    )
    return get_daily_used(conn, identity_hash, date_key)


def generate_room_code() -> str:
    alphabet = "ABCDEFGHJKLMNPQRSTUVWXYZ23456789"
    return "".join(secrets.choice(alphabet) for _ in range(6))


class PegsOfUrHandler(BaseHTTPRequestHandler):
    def _client_ip_hash(self) -> str:
        fwd = self.headers.get("X-Forwarded-For", "")
        ip = fwd.split(",")[0].strip() if fwd else (self.client_address[0] if self.client_address else "unknown")
        return hash_identity(ip)

    def _send_json(self, code: int, payload: dict) -> None:
        raw = json.dumps(payload).encode("utf-8")
        self.send_response(code)
        self.send_header("Content-Type", "application/json")
        self.send_header("Access-Control-Allow-Origin", "*")
        self.send_header("Access-Control-Allow-Methods", "GET, POST, OPTIONS")
        self.send_header("Access-Control-Allow-Headers", "Content-Type")
        self.send_header("Content-Length", str(len(raw)))
        self.end_headers()
        self.wfile.write(raw)

    def _read_json(self, max_bytes: int = 8192) -> dict | None:
        try:
            length = int(self.headers.get("Content-Length", "0"))
        except ValueError:
            return None
        if length <= 0 or length > max_bytes:
            return None
        try:
            return json.loads(self.rfile.read(length).decode("utf-8"))
        except Exception:
            return None

    def do_OPTIONS(self) -> None:
        self.send_response(204)
        self.send_header("Access-Control-Allow-Origin", "*")
        self.send_header("Access-Control-Allow-Methods", "GET, POST, OPTIONS")
        self.send_header("Access-Control-Allow-Headers", "Content-Type")
        self.end_headers()

    def do_GET(self) -> None:
        parsed = urlparse(self.path)
        path = parsed.path.rstrip("/")
        qs = parse_qs(parsed.query)
        ip_hash = self._client_ip_hash()
        date_key = today_utc_key()

        if path in ("", "/v1/health"):
            self._send_json(200, {"ok": True, "service": "Pegs of Ur Online & Standings API", "date": date_key})
            return

        if path == "/v1/account":
            if not check_rate_limit(ip_hash, "account", 60, 3600.0):
                self._send_json(429, {"error": "Rate limit exceeded"})
                return
            email = (qs.get("email", [""])[0] or "").strip().lower()
            is_store = (qs.get("store", [""])[0] or "").strip().lower() in ("1", "true", "yes")
            if email and not EMAIL_RE.match(email):
                self._send_json(400, {"error": "Invalid email format"})
                return
            ident = hash_identity(email) if email else ip_hash
            supported, tier = (True, "Microsoft Store") if is_store else check_shared_supporter(email)
            with get_db() as conn:
                used = get_daily_used(conn, ident, date_key)
            self._send_json(
                200,
                {
                    "ok": True,
                    "email": email,
                    "supported": supported,
                    "tierLabel": tier,
                    "date": date_key,
                    "dailyUsed": used,
                    "dailyLimit": -1 if supported else FREE_DAILY_ONLINE_LIMIT,
                    "remainingToday": -1 if supported else max(0, FREE_DAILY_ONLINE_LIMIT - used),
                    "unlimited": supported,
                },
            )
            return

        if path == "/v1/standings":
            mode = (qs.get("mode", ["solo"])[0] or "solo").strip().lower()
            if mode not in ("solo", "multi"):
                mode = "solo"
            try:
                limit = max(1, min(50, int((qs.get("limit", ["20"])[0] or "20"))))
            except ValueError:
                limit = 20
            with get_db() as conn:
                rows = conn.execute(
                    """
                    SELECT display_name, mode, score, rounds, works_built, advancements, won, created_at_ms
                    FROM standings
                    WHERE mode = ?
                    ORDER BY score DESC, works_built DESC, created_at_ms ASC
                    LIMIT ?
                    """,
                    (mode, limit),
                ).fetchall()
            entries = [
                {
                    "rank": idx + 1,
                    "displayName": r["display_name"],
                    "mode": r["mode"],
                    "score": int(r["score"]),
                    "rounds": int(r["rounds"]),
                    "worksBuilt": int(r["works_built"]),
                    "advancements": int(r["advancements"]),
                    "won": bool(r["won"]),
                    "createdAtMs": int(r["created_at_ms"]),
                }
                for idx, r in enumerate(rows)
            ]
            self._send_json(200, {"ok": True, "mode": mode, "entries": entries})
            return

        if path == "/v1/rooms":
            code = (qs.get("code", [""])[0] or "").strip().upper()
            if not ROOM_CODE_RE.match(code):
                self._send_json(400, {"error": "Invalid room code"})
                return
            with get_db() as conn:
                row = conn.execute("SELECT * FROM rooms WHERE code = ?", (code,)).fetchone()
            if not row:
                self._send_json(404, {"error": "Room not found"})
                return
            players = json.loads(row["players_json"])
            public_players = [
                {"seat": p["seat"], "displayName": p["displayName"], "joinedAtMs": p["joinedAtMs"]}
                for p in players
            ]
            self._send_json(
                200,
                {
                    "ok": True,
                    "code": row["code"],
                    "hostName": row["host_name"],
                    "maxPlayers": int(row["max_players"]),
                    "status": row["status"],
                    "seed": int(row["seed"]),
                    "turnSeq": int(row["turn_seq"]),
                    "players": public_players,
                    "moves": json.loads(row["moves_json"]),
                },
            )
            return

        self._send_json(404, {"error": "Not found"})

    def do_POST(self) -> None:
        parsed = urlparse(self.path)
        path = parsed.path.rstrip("/")
        now_ms = int(time.time() * 1000)
        date_key = today_utc_key()
        ip_hash = self._client_ip_hash()

        if path == "/v1/standings":
            if not check_rate_limit(ip_hash, "standings_post", 30, 3600.0):
                self._send_json(429, {"error": "Rate limit exceeded"})
                return
            body = self._read_json(4096)
            if not body:
                self._send_json(400, {"error": "Invalid JSON body"})
                return
            display_name = str(body.get("displayName") or "").strip()
            email = str(body.get("email") or "").strip().lower()
            mode = str(body.get("mode") or "solo").strip().lower()
            if mode not in ("solo", "multi"):
                mode = "solo"
            if not NAME_RE.match(display_name):
                self._send_json(400, {"error": "Display name must be 2-32 alphanumeric characters"})
                return
            if email and not EMAIL_RE.match(email):
                self._send_json(400, {"error": "Invalid email"})
                return
            try:
                score = int(body.get("score", 0))
                rounds = int(body.get("rounds", 10))
                works_built = int(body.get("worksBuilt", 0))
                advancements = int(body.get("advancements", 0))
                won = 1 if body.get("won") else 0
            except (TypeError, ValueError):
                self._send_json(400, {"error": "Invalid score fields"})
                return
            if score < 0 or score > 180 or rounds < 1 or rounds > 20 or works_built < 0 or works_built > 7 or advancements < 0 or advancements > 13:
                self._send_json(400, {"error": "Score values out of valid game bounds"})
                return

            email_hash = hash_identity(email) if email else ip_hash
            with get_db() as conn:
                conn.execute(
                    """
                    INSERT INTO standings (email_hash, display_name, mode, score, rounds, works_built, advancements, won, created_at_ms)
                    VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)
                    """,
                    (email_hash, display_name, mode, score, rounds, works_built, advancements, won, now_ms),
                )
            self._send_json(200, {"ok": True, "recorded": True, "mode": mode, "score": score})
            return

        if path == "/v1/rooms":
            if not check_rate_limit(ip_hash, "room_create", 25, 3600.0):
                self._send_json(429, {"error": "Rate limit exceeded"})
                return
            body = self._read_json(4096)
            if not body:
                self._send_json(400, {"error": "Invalid JSON body"})
                return
            display_name = str(body.get("displayName") or "Ur").strip()
            email = str(body.get("email") or "").strip().lower()
            is_store = bool(body.get("isStorePurchase"))
            if not NAME_RE.match(display_name):
                self._send_json(400, {"error": "Invalid display name"})
                return
            if email and not EMAIL_RE.match(email):
                self._send_json(400, {"error": "Invalid email"})
                return
            try:
                max_players = max(2, min(4, int(body.get("maxPlayers", 2))))
            except (TypeError, ValueError):
                max_players = 2

            ident = hash_identity(email) if email else ip_hash
            supported, _ = (True, "Microsoft Store") if is_store else check_shared_supporter(email)

            with get_db() as conn:
                used = get_daily_used(conn, ident, date_key)
                if not supported and used >= FREE_DAILY_ONLINE_LIMIT:
                    self._send_json(
                        403,
                        {
                            "ok": False,
                            "error": f"Daily free online limit ({FREE_DAILY_ONLINE_LIMIT}/day) reached. Support Pegs of Ur or use the Microsoft Store edition for unlimited online play.",
                            "dailyUsed": used,
                            "dailyLimit": FREE_DAILY_ONLINE_LIMIT,
                        },
                    )
                    return
                used = increment_daily_used(conn, ident, date_key, now_ms)
                code = generate_room_code()
                seat_token = secrets.token_hex(16)
                seed = secrets.randbelow(2**31 - 1) + 1
                players = [{"seat": 0, "displayName": display_name, "token": seat_token, "joinedAtMs": now_ms}]
                conn.execute(
                    """
                    INSERT INTO rooms (code, host_name, max_players, status, seed, players_json, moves_json, turn_seq, created_at_ms, updated_at_ms)
                    VALUES (?, ?, ?, 'waiting', ?, ?, '[]', 0, ?, ?)
                    """,
                    (code, display_name, max_players, seed, json.dumps(players), now_ms, now_ms),
                )
            self._send_json(
                200,
                {
                    "ok": True,
                    "code": code,
                    "seat": 0,
                    "seatToken": seat_token,
                    "seed": seed,
                    "maxPlayers": max_players,
                    "dailyUsed": used,
                    "dailyLimit": -1 if supported else FREE_DAILY_ONLINE_LIMIT,
                },
            )
            return

        if path == "/v1/rooms/join":
            if not check_rate_limit(ip_hash, "room_join", 40, 3600.0):
                self._send_json(429, {"error": "Rate limit exceeded"})
                return
            body = self._read_json(4096)
            if not body:
                self._send_json(400, {"error": "Invalid JSON body"})
                return
            code = str(body.get("code") or "").strip().upper()
            display_name = str(body.get("displayName") or "Byblos").strip()
            email = str(body.get("email") or "").strip().lower()
            is_store = bool(body.get("isStorePurchase"))
            if not ROOM_CODE_RE.match(code) or not NAME_RE.match(display_name):
                self._send_json(400, {"error": "Invalid room code or display name"})
                return
            ident = hash_identity(email) if email else ip_hash
            supported, _ = (True, "Microsoft Store") if is_store else check_shared_supporter(email)

            with get_db() as conn:
                row = conn.execute("SELECT * FROM rooms WHERE code = ?", (code,)).fetchone()
                if not row:
                    self._send_json(404, {"error": "Room not found"})
                    return
                players = json.loads(row["players_json"])
                if len(players) >= int(row["max_players"]):
                    self._send_json(409, {"error": "Room is full"})
                    return
                used = get_daily_used(conn, ident, date_key)
                if not supported and used >= FREE_DAILY_ONLINE_LIMIT:
                    self._send_json(
                        403,
                        {
                            "ok": False,
                            "error": f"Daily free online limit ({FREE_DAILY_ONLINE_LIMIT}/day) reached.",
                            "dailyUsed": used,
                            "dailyLimit": FREE_DAILY_ONLINE_LIMIT,
                        },
                    )
                    return
                used = increment_daily_used(conn, ident, date_key, now_ms)
                seat = len(players)
                seat_token = secrets.token_hex(16)
                players.append({"seat": seat, "displayName": display_name, "token": seat_token, "joinedAtMs": now_ms})
                status = "active" if len(players) >= int(row["max_players"]) else "waiting"
                conn.execute(
                    "UPDATE rooms SET players_json = ?, status = ?, updated_at_ms = ? WHERE code = ?",
                    (json.dumps(players), status, now_ms, code),
                )
            self._send_json(
                200,
                {
                    "ok": True,
                    "code": code,
                    "seat": seat,
                    "seatToken": seat_token,
                    "seed": int(row["seed"]),
                    "status": status,
                    "dailyUsed": used,
                    "dailyLimit": -1 if supported else FREE_DAILY_ONLINE_LIMIT,
                },
            )
            return

        if path == "/v1/rooms/move":
            body = self._read_json(4096)
            if not body:
                self._send_json(400, {"error": "Invalid JSON body"})
                return
            code = str(body.get("code") or "").strip().upper()
            seat_token = str(body.get("seatToken") or "").strip()
            action = str(body.get("action") or "").strip()
            payload = body.get("payload") or {}
            if not ROOM_CODE_RE.match(code) or not seat_token or not action:
                self._send_json(400, {"error": "Missing room code, seatToken, or action"})
                return
            with get_db() as conn:
                row = conn.execute("SELECT * FROM rooms WHERE code = ?", (code,)).fetchone()
                if not row:
                    self._send_json(404, {"error": "Room not found"})
                    return
                players = json.loads(row["players_json"])
                seat_match = next((p for p in players if p.get("token") == seat_token), None)
                if not seat_match:
                    self._send_json(403, {"error": "Invalid seat token"})
                    return
                moves = json.loads(row["moves_json"])
                seq = int(row["turn_seq"]) + 1
                moves.append(
                    {
                        "seq": seq,
                        "seat": seat_match["seat"],
                        "action": action[:40],
                        "payload": payload,
                        "tsMs": now_ms,
                    }
                )
                conn.execute(
                    "UPDATE rooms SET moves_json = ?, turn_seq = ?, status = 'active', updated_at_ms = ? WHERE code = ?",
                    (json.dumps(moves), seq, now_ms, code),
                )
            self._send_json(200, {"ok": True, "turnSeq": seq})
            return

        self._send_json(404, {"error": "Not found"})

    def log_message(self, format: str, *args) -> None:
        return


if __name__ == "__main__":
    init_db()
    server = ThreadingHTTPServer(("0.0.0.0", PORT), PegsOfUrHandler)
    print(f"[pegsofur-api] Listening on 0.0.0.0:{PORT} (DB: {DB_PATH})", flush=True)
    server.serve_forever()
