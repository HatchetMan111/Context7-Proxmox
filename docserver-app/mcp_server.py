"""MCP-Server (Streamable HTTP) mit Context7-kompatiblen Tool-Namen.

Wird von app.py als Sub-App unter /mcp gemountet, damit KI-Clients
(ZCode, Cursor, Claude Desktop, …) DocServer wie Context7 nutzen können.
"""

from __future__ import annotations

from mcp.server.fastmcp import FastMCP

import database as db

mcp = FastMCP("DocServer")


@mcp.tool(
    name="resolve-library-id",
    description=(
        "Findet lokale Dokumentations-Libraries anhand eines Namens. "
        "Gibt Treffer mit ID, Name und Seitenzahl zurück (wie Context7)."
    ),
)
def resolve_library_id(library_name: str) -> str:
    term = library_name.strip()
    all_libs = db.list_libraries()
    matches = [
        lib for lib in all_libs
        if term.lower() in lib["name"].lower()
        or term.lower() in (lib["description"] or "").lower()
    ]
    if not matches:
        names = ", ".join(lib["name"] for lib in all_libs) or "(keine vorhanden)"
        return f"Keine Library für '{term}' gefunden. Verfügbare Libraries: {names}"
    lines = [f"Gefundene Libraries für '{term}':"]
    for lib in matches:
        lines.append(
            f"- ID: {lib['id']} | Name: {lib['name']} | Chunks: {lib['chunks']} "
            f"| Beschreibung: {lib['description'] or '-'}"
        )
    lines.append("Nutze die ID mit query-docs, um Dokumentation abzufragen.")
    return "\n".join(lines)


@mcp.tool(
    name="query-docs",
    description=(
        "Durchsucht die Dokumentation einer Library (ID oder Name, siehe "
        "resolve-library-id) nach einem Thema und liefert Textabschnitte "
        "inklusive Quell-URLs zurück."
    ),
)
def query_docs(library_id: str, query: str) -> str:
    lib = db.resolve_library(library_id)
    if lib is None:
        return (
            f"Library '{library_id}' nicht gefunden. "
            "Erst resolve-library-id aufrufen, um die ID zu ermitteln."
        )
    results = db.search(query, library_id=lib["id"], limit=8)
    if not results:
        return (
            f"Keine Treffer für '{query}' in '{lib['name']}'. "
            f"({db.count_chunks(lib['id'])} Chunks indexiert – ggf. Sync auslösen "
            "oder anderen Suchbegriff verwenden.)"
        )
    lines = [f"Dokumentation '{lib['name']}' zu '{query}':\n"]
    for i, r in enumerate(results, 1):
        src = f" (Quelle: {r['url']})" if r["url"] else ""
        head = f" › {r['heading']}" if r["heading"] else ""
        lines.append(f"[{i}] {r['title']}{head}{src}\n{r['snippet']}\n")
    return "\n".join(lines)
