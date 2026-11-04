"""Transcript formatting, token-aware chunking and tree reduction."""

from __future__ import annotations

import logging
from datetime import datetime
from typing import Iterable, Sequence
from zoneinfo import ZoneInfo

from model import Model

log = logging.getLogger(__name__)


def format_ts(ts_ms: int, tz: ZoneInfo) -> str:
    return datetime.fromtimestamp(ts_ms / 1000, tz).strftime("%Y-%m-%d %H:%M")


def format_line(row, tz: ZoneInfo) -> str:
    body = " ".join(str(row["body"]).split())
    if len(body) > 1200:
        body = body[:1197] + "..."
    sender = str(row["sender_name"] or row["sender"])
    return f"[{format_ts(int(row['ts']), tz)}] {sender}: {body}"


def chunk_lines(
    lines: Sequence[str],
    max_tokens: int,
    estimate_tokens,
) -> list[str]:
    """Split at line boundaries, keeping each chunk under max_tokens."""
    chunks: list[str] = []
    current: list[str] = []
    size = 0
    for line in lines:
        cost = estimate_tokens(line) + 1
        if current and size + cost > max_tokens:
            chunks.append("\n".join(current))
            current = []
            size = 0
        current.append(line)
        size += cost
    if current:
        chunks.append("\n".join(current))
    return chunks


def reduce_notes(
    model: Model,
    notes: list[str],
    *,
    target_tokens: int,
    label: str,
) -> str:
    """Collapse chunk notes until they fit, asking the model to merge batches."""
    system = model.prompt("reduce")
    merged = [note.strip() for note in notes if note.strip()]
    if not merged:
        return ""

    while len(merged) > 1:
        combined = "\n\n".join(merged)
        if model.estimate_tokens(combined) <= target_tokens:
            return combined

        batches = chunk_lines(merged, target_tokens, model.estimate_tokens)
        if len(batches) <= 1:
            break
        next_round: list[str] = []
        for index, batch in enumerate(batches, 1):
            log.info("reducing %s notes batch %d/%d", label, index, len(batches))
            summary = model.generate(
                system=system,
                prompt=(
                    f"Chat: {label}\n"
                    "Merge these notes. Keep every concrete fact, speaker, time "
                    "and any request aimed at Rui. Drop repetition. Use bullets.\n\n"
                    f"{batch}"
                ),
                max_tokens=900,
            )
            next_round.append(summary.strip())
        merged = next_round

    combined = "\n".join(merged)
    if model.estimate_tokens(combined) > target_tokens:
        # Last resort: hard truncation, keeping the head of the notes.
        limit = max(1000, int(target_tokens * model.chars_per_token))
        combined = combined[:limit] + "\n[...notes truncated...]"
    return combined


def format_lines(rows: Iterable, tz: ZoneInfo) -> list[str]:
    return [format_line(row, tz) for row in rows]

