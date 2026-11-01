"""OpenRouter chat-completions client for the final digest synthesis.

The on-device 8k model is used for event detection and chunk notes. The final
digest needs better role/agency handling, so it goes to a hosted model. Only
one transcript per scheduled digest leaves lime.
"""

from __future__ import annotations

import json
import logging
import re
import time
import urllib.error
import urllib.request

from model import ModelError

log = logging.getLogger(__name__)


class CloudError(ModelError):
    pass


class CloudModel:
    def __init__(
        self,
        *,
        api_base: str,
        api_key: str,
        model: str,
        timeout_seconds: int = 120,
        max_tokens: int = 1800,
        max_input_tokens: int = 60000,
        http_referer: str = "",
        title: str = "",
    ):
        self.api_base = api_base.rstrip("/")
        self.api_key = api_key
        self.model = model
        self.timeout = timeout_seconds
        self.max_tokens = max_tokens
        self.max_input_tokens = max_input_tokens
        self.http_referer = http_referer
        self.title = title

    def generate_json(
        self,
        *,
        system: str,
        prompt: str,
        schema_text: str,
        max_tokens: int | None = None,
    ) -> dict:
        system_with_schema = (
            system
            + "\n\nReturn ONLY a JSON object that validates against this "
            "JSON Schema:\n"
            + schema_text
        )
        messages = [
            {"role": "system", "content": system_with_schema},
            {"role": "user", "content": prompt},
        ]
        body = {
            "model": self.model,
            "messages": messages,
            "temperature": 0,
            "max_tokens": max_tokens or self.max_tokens,
            "response_format": {"type": "json_object"},
        }

        try:
            response = self._post(body)
        except CloudError as exc:
            # Some OpenRouter endpoints reject response_format; retry plainly
            # and rely on the schema in the system prompt.
            if "response_format" in str(exc).lower():
                body.pop("response_format", None)
                response = self._post(body)
            else:
                raise

        content = self._content(response)
        data = _parse_json(content)
        if data is None:
            log.warning("cloud synthesis returned invalid JSON; asking for repair")
            repair_messages = messages + [
                {"role": "assistant", "content": content[:4000]},
                {
                    "role": "user",
                    "content": "That was not valid JSON. Return the same answer as "
                    "one valid JSON object only.",
                },
            ]
            repair_body = dict(body)
            repair_body["messages"] = repair_messages
            response = self._post(repair_body)
            content = self._content(response)
            data = _parse_json(content)

        if data is None:
            raise CloudError(f"cloud model returned invalid JSON: {content[:300]}")
        if not isinstance(data, dict):
            raise CloudError(
                f"cloud model returned {type(data).__name__}, expected an object"
            )

        usage = response.get("usage") or {}
        log.info(
            "cloud synthesis %s: prompt=%s completion=%s total=%s tokens",
            self.model,
            usage.get("prompt_tokens", "?"),
            usage.get("completion_tokens", "?"),
            usage.get("total_tokens", "?"),
        )
        return data

    # -- transport ---------------------------------------------------------

    def _post(self, body: dict) -> dict:
        url = self.api_base + "/chat/completions"
        headers = {
            "Authorization": f"Bearer {self.api_key}",
            "Content-Type": "application/json",
            "User-Agent": "imessage-digest/1.0",
        }
        if self.http_referer:
            headers["HTTP-Referer"] = self.http_referer
        if self.title:
            headers["X-Title"] = self.title
        data = json.dumps(body).encode()

        last_error: Exception | None = None
        for attempt in range(1, 4):
            request = urllib.request.Request(url, data=data, headers=headers, method="POST")
            try:
                with urllib.request.urlopen(request, timeout=self.timeout) as response:
                    raw = response.read().decode()
            except urllib.error.HTTPError as exc:
                raw = exc.read().decode(errors="replace")
                if exc.code == 429:
                    wait = 10
                    try:
                        wait = float(json.loads(raw).get("retry_after", 10))
                    except Exception:
                        pass
                    log.warning("OpenRouter rate limit; sleeping %.0fs", wait)
                    time.sleep(wait)
                    last_error = CloudError(f"OpenRouter 429: {raw[:400]}")
                    continue
                if exc.code >= 500 and attempt < 3:
                    last_error = CloudError(f"OpenRouter {exc.code}: {raw[:400]}")
                    time.sleep(3 * attempt)
                    continue
                raise CloudError(f"OpenRouter {exc.code}: {raw[:500]}") from exc
            except urllib.error.URLError as exc:
                last_error = CloudError(f"OpenRouter connection failed: {exc}")
                if attempt < 3:
                    time.sleep(3 * attempt)
                    continue
                raise last_error from exc
            try:
                return json.loads(raw)
            except json.JSONDecodeError as exc:
                raise CloudError(
                    f"OpenRouter returned non-JSON: {raw[:300]}"
                ) from exc
        raise last_error or CloudError("OpenRouter request failed")

    @staticmethod
    def _content(response: dict) -> str:
        choices = response.get("choices") or []
        if not choices:
            raise CloudError(f"OpenRouter returned no choices: {str(response)[:400]}")
        message = choices[0].get("message") or {}
        content = message.get("content")
        if isinstance(content, list):
            content = "".join(
                str(part.get("text", ""))
                for part in content
                if isinstance(part, dict)
            )
        if not isinstance(content, str) or not content.strip():
            raise CloudError("OpenRouter returned an empty message")
        if choices[0].get("finish_reason") == "length":
            log.warning("cloud synthesis hit max_tokens; digest may be truncated")
        return content


def _parse_json(text: str) -> dict | None:
    text = text.strip()
    if text.startswith("```") and text.endswith("```"):
        lines = text.splitlines()
        if len(lines) >= 2:
            text = "\n".join(lines[1:-1]).strip()
    try:
        value = json.loads(text)
        return value if isinstance(value, dict) else None
    except json.JSONDecodeError:
        pass
    # Last resort: take the outermost object.
    match = re.search(r"\{.*\}", text, re.DOTALL)
    if not match:
        return None
    try:
        value = json.loads(match.group(0))
        return value if isinstance(value, dict) else None
    except json.JSONDecodeError:
        return None
