"""SQLite + FTS5 Datenhaltung für DocServer.

Alle Funktionen öffnen je einen kurzlebigen Verbindung (thread-sicher) und
nutzen WAL-Modus, damit parallele Leser und der Sync-Worker sich nicht blockieren.
"""

from __future__ import annotations

import re
import sqlite3
import threading
import time
from pathlib import Path

from config import DATA_DIR

DB_PATH = Path(DATA_DIR) / "docserver.db"

# Serialisiert Schreibzugriffe aus Sync-Worker + Web-Requests.
_write_lock = threading.Lock()

_SCHEMA = """
CREATE TABLE IF NOT EXISTS libraries (
    id          INTEGER PRIMARY KEY AUTOINCREMENT,
    name        TEXT NOT NULL UNIQUE,
    description TEXT NOT NULL DEFAULT '',
    created_at  TEXT NOT NULL
);

CREATE TABLE IF NOT EXISTS sources (
    id         INTEGER PRIMARY KEY AUTOINCREMENT,
    library_id INTEGER NOT NULL REFERENCES libraries(id) ON DELETE CASCADE,
    type       TEXT NOT NULL,               -- url | sitemap | file
    location   TEXT NOT NULL,               -- URL oder Dateipfad
    status     TEXT NOT NULL DEFAULT 'pending',  -- pending | syncing | ok | error
    pages      INTEGER NOT NULL DEFAULT 0,
    error      TEXT NOT NULL DEFAULT '',
    last_sync  TEXT NOT NULL DEFAULT ''
);

CREATE TABLE IF NOT EXISTS chunks (
    id         INTEGER PRIMARY KEY AUTOINCREMENT,
    library_id INTEGER NOT NULL,
    source_id  INTEGER NOT NULL,
    title      TEXT NOT NULL DEFAULT '',
    url        TEXT NOT NULL DEFAULT '',
    heading    TEXT NOT NULL DEFAULT '',
    content    TEXT NOT NULL
);

CREATE VIRTUAL TABLE IF NOT EXISTS chunks_fts USING fts5(
    title, heading, content, tokenize = 'unicode61 remove_diacritics 2'
);

CREATE INDEX IF NOT EXISTS idx_chunks_source ON chunks(source_id);
CREATE INDEX IF NOT EXISTS idx_chunks_library ON chunks(library_id);
CREATE INDEX IF NOT EXISTS idx_sources_library ON sources(library_id);
"""


def _connect() -> sqlite3.Connection:
    DB_PATH.parent.mkdir(parents=True, exist_ok=True)
    conn = sqlite3.connect(DB_PATH, timeout=30)
    conn.row_factory = sqlite3.Row
    conn.execute("PRAGMA journal_mode=WAL")
    conn.execute("PRAGMA foreign_keys=ON")
    return conn


def init_db() -> None:
    with _connect() as conn:
        conn.executescript(_SCHEMA)


def now() -> str:
    return time.strftime("%Y-%m-%d %H:%M:%S")


# ---------------------------------------------------------------- Libraries

def add_library(name: str, description: str = "") -> int:
    with _write_lock, _connect() as conn:
        cur = conn.execute(
            "INSERT INTO libraries (name, description, created_at) VALUES (?, ?, ?)",
            (name.strip(), description.strip(), now()),
        )
        return int(cur.lastrowid)


def get_library(library_id: int) -> sqlite3.Row | None:
    with _connect() as conn:
        return conn.execute(
            "SELECT * FROM libraries WHERE id = ?", (library_id,)
        ).fetchone()


def list_libraries() -> list[sqlite3.Row]:
    with _connect() as conn:
        return conn.execute(
            """
            SELECT l.*,
                   (SELECT COUNT(*) FROM chunks c WHERE c.library_id = l.id) AS chunks,
                   (SELECT COUNT(DISTINCT s.id) FROM sources s
                     WHERE s.library_id = l.id AND s.status = 'ok') AS sources_ok,
                   (SELECT COUNT(*) FROM sources s WHERE s.library_id = l.id) AS sources_total,
                   COALESCE((SELECT MAX(s.last_sync) FROM sources s
                     WHERE s.library_id = l.id AND s.last_sync != ''), '') AS last_sync
            FROM libraries l ORDER BY l.name COLLATE NOCASE
            """
        ).fetchall()


def delete_library(library_id: int) -> None:
    with _write_lock, _connect() as conn:
        conn.execute(
            "DELETE FROM chunks_fts WHERE rowid IN "
            "(SELECT id FROM chunks WHERE library_id = ?)", (library_id,)
        )
        conn.execute("DELETE FROM chunks WHERE library_id = ?", (library_id,))
        conn.execute("DELETE FROM sources WHERE library_id = ?", (library_id,))
        conn.execute("DELETE FROM libraries WHERE id = ?", (library_id,))


def get_library_by_name(name: str) -> sqlite3.Row | None:
    with _connect() as conn:
        return conn.execute(
            "SELECT * FROM libraries WHERE name = ? COLLATE NOCASE", (name,)
        ).fetchone()


def resolve_library(term: str) -> sqlite3.Row | None:
    """Findet eine Library exakt per Name oder per numerischer ID."""
    term = term.strip()
    with _connect() as conn:
        row = conn.execute(
            "SELECT * FROM libraries WHERE name = ? COLLATE NOCASE", (term,)
        ).fetchone()
        if row is None and term.isdigit():
            row = conn.execute(
                "SELECT * FROM libraries WHERE id = ?", (int(term),)
            ).fetchone()
        return row


# ---------------------------------------------------------------- Sources

def add_source(library_id: int, type_: str, location: str) -> int:
    with _write_lock, _connect() as conn:
        cur = conn.execute(
            "INSERT INTO sources (library_id, type, location) VALUES (?, ?, ?)",
            (library_id, type_, location.strip()),
        )
        return int(cur.lastrowid)


def get_source(source_id: int) -> sqlite3.Row | None:
    with _connect() as conn:
        return conn.execute(
            "SELECT * FROM sources WHERE id = ?", (source_id,)
        ).fetchone()


def list_sources(library_id: int) -> list[sqlite3.Row]:
    with _connect() as conn:
        return conn.execute(
            "SELECT * FROM sources WHERE library_id = ? ORDER BY id", (library_id,)
        ).fetchall()


def delete_source(source_id: int) -> None:
    with _write_lock, _connect() as conn:
        conn.execute(
            "DELETE FROM chunks_fts WHERE rowid IN "
            "(SELECT id FROM chunks WHERE source_id = ?)", (source_id,)
        )
        conn.execute("DELETE FROM chunks WHERE source_id = ?", (source_id,))
        conn.execute("DELETE FROM sources WHERE id = ?", (source_id,))


def set_source_status(source_id: int, status: str, error: str = "",
                      pages: int | None = None) -> None:
    with _write_lock, _connect() as conn:
        if pages is not None:
            conn.execute(
                "UPDATE sources SET status=?, error=?, pages=?, last_sync=? WHERE id=?",
                (status, error, pages, now(), source_id),
            )
        else:
            conn.execute(
                "UPDATE sources SET status=?, error=? WHERE id=?",
                (status, error, source_id),
            )


# ---------------------------------------------------------------- Chunks / Index

def replace_source_chunks(source_id: int, library_id: int,
                          entries: list[dict]) -> None:
    """Ersetzt alle Chunks einer Quelle (atomar innerhalb einer Transaktion)."""
    with _write_lock, _connect() as conn:
        conn.execute(
            "DELETE FROM chunks_fts WHERE rowid IN "
            "(SELECT id FROM chunks WHERE source_id = ?)", (source_id,)
        )
        conn.execute("DELETE FROM chunks WHERE source_id = ?", (source_id,))
        for e in entries:
            cur = conn.execute(
                "INSERT INTO chunks (library_id, source_id, title, url, heading, content) "
                "VALUES (?, ?, ?, ?, ?, ?)",
                (library_id, source_id, e.get("title", ""), e.get("url", ""),
                 e.get("heading", ""), e.get("content", "")),
            )
            conn.execute(
                "INSERT INTO chunks_fts (rowid, title, heading, content) VALUES (?, ?, ?, ?)",
                (cur.lastrowid, e.get("title", ""), e.get("heading", ""),
                 e.get("content", "")),
            )


def count_chunks(library_id: int | None = None) -> int:
    with _connect() as conn:
        if library_id is None:
            return conn.execute("SELECT COUNT(*) FROM chunks").fetchone()[0]
        return conn.execute(
            "SELECT COUNT(*) FROM chunks WHERE library_id = ?", (library_id,)
        ).fetchone()[0]


def _fts_query(user_query: str) -> str:
    """Baut eine sichere FTS5-Query: Tokens als Phrase, verknüpft per OR."""
    tokens = re.findall(r"[\w]+", user_query, re.UNICODE)
    if not tokens:
        return ""
    return " OR ".join(f'"{t}"' for t in tokens)


def search(query: str, library_id: int | None = None, limit: int = 12) -> list[dict]:
    fts = _fts_query(query)
    if not fts:
        return []
    sql = """
        SELECT c.id, c.library_id, c.source_id, c.title, c.url, c.heading,
               snippet(chunks_fts, 2, '[[', ']]', ' … ', 24) AS snippet,
               bm25(chunks_fts) AS rank, l.name AS library_name
        FROM chunks_fts
        JOIN chunks c ON c.id = chunks_fts.rowid
        JOIN libraries l ON l.id = c.library_id
        WHERE chunks_fts MATCH ?
    """
    params: list = [fts]
    if library_id is not None:
        sql += " AND c.library_id = ?"
        params.append(library_id)
    sql += " ORDER BY rank LIMIT ?"
    params.append(limit)
    with _connect() as conn:
        rows = conn.execute(sql, params).fetchall()
    return [dict(r) for r in rows]
