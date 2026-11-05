# kiro-gateway package

Packages our fork,
[ruihuang17/kiro-gateway](https://github.com/ruihuang17/kiro-gateway) (branch
`homelab`): upstream `jwadow/kiro-gateway` at its last commit (`a5292ca`,
2026-05-18) plus the fixes a coding client needs.

Upstream is no longer maintained, so the changes live as two commits on the
fork instead of as a patch file here:

| Commit | Change |
| --- | --- |
| `Carry the open upstream PRs that matter for a coding client` | Combined PRs #169, #182, #225, #232, #241, #257, #268, #276, #280, #286, #288, #292, #293, #294 |
| `Do not open the circuit breaker on transient capacity 429s` | Local fix: `429 INSUFFICIENT_MODEL_CAPACITY` no longer cools the account down, and the real upstream error is returned |

The stream keepalive from #288 was needed by OpenCode's idle watchdog; the
#288/#280 conflict in `kiro/streaming_openai.py` is resolved in the fork by
keeping both the keepalive interval and the credits setting.

## Refreshing

```sh
git clone https://github.com/ruihuang17/kiro-gateway /tmp/kiro-gateway
cd /tmp/kiro-gateway
git checkout homelab
git fetch upstream main && git rebase upstream/main
git push --force-with-lease
```

Then bump `rev` and `hash` in `default.nix`:

```sh
nix flake prefetch github:ruihuang17/kiro-gateway/<rev> --json
```

This derivation still supplies what the fork does not: the Python environment
(fastapi, httpx, loguru, python-dotenv, tiktoken, uvicorn) and the
`cl100k_base` tiktoken cache, so the service never downloads it at runtime.
