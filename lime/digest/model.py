"""apfel subprocess wrapper around Apple's on-device Foundation Model."""

from __future__ import annotations

import json
import logging
import re
import subprocess
import time
from pathlib import Path

log = logging.getLogger(__name__)


class ModelError(RuntimeError):
    pass


class Model:
    def __init__(
        self,
        binary: str,
        timeout_seconds: int,
        prompts_dir: Path,
        schemas_dir: Path,
    ):
        self.binary = binary
        self.timeout = timeout_seconds
        self.prompts_dir = prompts_dir
        self.schemas_dir = schemas_dir
        self._token_ratio = 0.25  # tokens per character fallback

    # -- prompts -----------------------------------------------------------

    def prompt(self, name: str) -> str:
        return (self.prompts_dir / f"{name}.md").read_text(encoding="utf-8").strip()

    def schema(self, name: str) -> str:
        return str(self.schemas_dir / f"{name}.json")

    # -- generation --------------------------------------------------------

    def generate(
        self,
        *,
        system: str,
        prompt: str,
        schema: str | None = None,
        max_tokens: int = 1400,
        temperature: float = 0.0,
    ) -> str:
        args = [
            self.binary,
            "--system",
            system,
            "--max-tokens",
            str(max_tokens),
            "--temperature",
            str(temperature),
        ]
        if schema:
            args += ["--schema", schema]
        # `--` prevents a prompt that starts with "-" from being parsed as a flag.
        args += ["--", prompt]

        last_error = ""
        for attempt in (1, 2):
            try:
                completed = subprocess.run(
                    args,
                    stdin=subprocess.DEVNULL,
                    capture_output=True,
                    text=True,
                    timeout=self.timeout,
                    check=False,
                )
            except subprocess.TimeoutExpired as exc:
                last_error = f"apfel timed out after {self.timeout}s"
                log.warning("%s (attempt %d)", last_error, attempt)
                if attempt == 1:
                    continue
                raise ModelError(last_error) from exc

            if completed.returncode == 0 and completed.stdout.strip():
                return _clean(completed.stdout)

            stderr = (completed.stderr or "").strip().splitlines()
            # apfel prints a harmless "piped input was empty" note when stdin is
            # not a TTY; keep only real failures.
            detail = " | ".join(
                line
                for line in stderr
                if "piped input was empty" not in line
            )[-500:]
            last_error = (
                f"apfel exit {completed.returncode}: "
                f"{detail or (completed.stdout or '').strip()[:200] or 'empty output'}"
            )
            log.warning("%s (attempt %d)", last_error, attempt)
            if attempt == 1:
                time.sleep(2)

        raise ModelError(last_error)

    def generate_json(
        self,
        *,
        system: str,
        prompt: str,
        schema: str,
        max_tokens: int = 1200,
        temperature: float = 0.0,
    ) -> dict:
        text = self.generate(
            system=system,
            prompt=prompt,
            schema=schema,
            max_tokens=max_tokens,
            temperature=temperature,
        )
        try:
            value = json.loads(text)
        except json.JSONDecodeError as exc:
            raise ModelError(f"model returned invalid JSON: {text[:300]}") from exc
        if not isinstance(value, dict):
            raise ModelError(f"model returned {type(value).__name__}, expected object")
        return value

    # -- token accounting --------------------------------------------------

    def count_tokens(self, text: str) -> int:
        """Ask apfel for an exact count; returns 0 if counting is unavailable."""
        if not text.strip() or len(text) > 200_000:
            return 0
        try:
            completed = subprocess.run(
                [self.binary, "--count-tokens", text],
                stdin=subprocess.DEVNULL,
                capture_output=True,
                text=True,
                timeout=60,
                check=False,
            )
        except (subprocess.TimeoutExpired, OSError):
            return 0
        if completed.returncode != 0:
            return 0
        match = re.search(r"(\d+)\s*/\s*\d+\s+tokens", completed.stdout)
        return int(match.group(1)) if match else 0

    def calibrate(self, text: str) -> None:
        """Set the tokens-per-character ratio from a representative transcript."""
        tokens = self.count_tokens(text)
        if tokens and text:
            self._token_ratio = tokens / len(text)
            log.info(
                "token calibration: %d tokens / %d chars = %.3f",
                tokens,
                len(text),
                self._token_ratio,
            )

    @property
    def chars_per_token(self) -> float:
        return 1.0 / self._token_ratio if self._token_ratio > 0 else 4.0

    def estimate_tokens(self, text: str) -> int:
        return max(1, int(len(text) * self._token_ratio))


def _clean(text: str) -> str:
    text = text.strip()
    if text.startswith("```") and text.endswith("```"):
        lines = text.splitlines()
        if len(lines) >= 2:
            text = "\n".join(lines[1:-1]).strip()
    return text
