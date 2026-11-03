# kiro-gateway package

Packages [jwadow/kiro-gateway](https://github.com/jwadow/kiro-gateway) at the
last upstream commit (`a5292ca`, 2026-05-18). The project is no longer
maintained, so `patches/kiro-gateway-fixes.patch` is a combined diff of the
open pull requests that matter for an OpenCode client. It is applied on top of
the upstream tree.

## Included fixes

| PR | Change |
| --- | --- |
| [#294](https://github.com/jwadow/kiro-gateway/pull/294) | Accept inline `system` turns in Anthropic `messages` |
| [#293](https://github.com/jwadow/kiro-gateway/pull/293) | Fetch `ListAvailableModels` from `q.{region}.amazonaws.com` instead of the runtime host |
| [#292](https://github.com/jwadow/kiro-gateway/pull/292) | Surface Kiro's own reason for `INVALID_MODEL_ID` |
| [#288](https://github.com/jwadow/kiro-gateway/pull/288) | Send Anthropic `ping` / OpenAI SSE keepalives while tool input is buffered (fixes long tool calls) |
| [#286](https://github.com/jwadow/kiro-gateway/pull/286) | Preserve image attachments when adjacent messages are merged |
| [#280](https://github.com/jwadow/kiro-gateway/pull/280) | Match the upstream metering event so credits are not lost |
| [#276](https://github.com/jwadow/kiro-gateway/pull/276) | Do not use the SSO JSON region as the Kiro API host |
| [#268](https://github.com/jwadow/kiro-gateway/pull/268) | Report OpenAI stream errors in-band |
| [#257](https://github.com/jwadow/kiro-gateway/pull/257) | Include the profile ARN in MCP web-search requests |
| [#241](https://github.com/jwadow/kiro-gateway/pull/241) | Resolve the `ToolReferenceContentBlock` forward reference (422 on tool results) |
| [#232](https://github.com/jwadow/kiro-gateway/pull/232) | Resolve top-level `oneOf`/`allOf`/`anyOf` in tool schemas |
| [#225](https://github.com/jwadow/kiro-gateway/pull/225) | Merge dict `tool_input` fragments instead of concatenating them |
| [#182](https://github.com/jwadow/kiro-gateway/pull/182) | Truncate long MCP tool names instead of rejecting the request |
| [#169](https://github.com/jwadow/kiro-gateway/pull/169) | Drop invalid `required` values from tool schemas |

The only manual conflict was in `kiro/streaming_openai.py` between #288 and
#280 (both touch the streaming import list and generator); the resolution
keeps both the keepalive interval and the credits setting. Tests from the PRs
are not applied, so no test-only changes are shipped.

## Local fix: transient model-capacity 429s

Kiro periodically returns `429 INSUFFICIENT_MODEL_CAPACITY` when a model is
temporarily at capacity. The account manager treated every 429 as an account
failure, applied exponential cooldown (1m, 2m, 4m, ... up to a day), and soon
returned `503 No available accounts for this model` even though both accounts
were healthy and merely rate-limited.

`patches/account-capacity-429.patch`:

- does not increment the circuit-breaker failure count for a 429 whose reason
  is `INSUFFICIENT_MODEL_CAPACITY`, so the next request can retry immediately;
- returns the last real upstream error (for example the 429) instead of a
  generic 503 when at least one account was actually tried.

The existing in-request exponential backoff (1s, 2s, 4s) still applies.

## Refreshing the patch

```sh
git clone https://github.com/jwadow/kiro-gateway /tmp/kiro-gateway
cd /tmp/kiro-gateway
git checkout a5292ca
# apply the PR branches/diffs you want, then:
git diff > /etc/nixos/pkgs/kiro-gateway/patches/kiro-gateway-fixes.patch
```
