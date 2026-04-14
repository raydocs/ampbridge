# AmpBridge

Minimal AMP bridge focused on two provider paths:

- Claude for AMP smart mode
- OpenAI for AMP deep mode

Goals:

- Keep AMP management/auth requests pointed at `ampcode.com`
- Keep Anthropic provider requests available for smart mode
- Intercept OpenAI Responses API for deep mode
- Rebuild `response.completed.response.output` from streamed deltas when needed
- Avoid the extra multi-provider complexity of VibeProxy

Planned request routing:

1. `/auth/cli-login` -> redirect to `https://ampcode.com`
2. `/api/internal?...` -> forward to `https://ampcode.com`
3. `/api/provider/anthropic/v1/messages` -> local Claude OAuth-backed upstream
4. `/api/provider/openai/v1/responses` -> local OpenAI OAuth-backed upstream with SSE rewrite
5. Other provider paths -> reject by default

Current status:

- Initial project scaffold created
- OpenAI Responses stream rewriter ported in
- Route model documented
- Request parser / response writer helpers added
- Runnable server/runtime implementation still in progress

## Note on current VibeProxy AMP behavior

From tracing AMP traffic through VibeProxy, the stable request pattern looks like:

1. `/api/internal?...`
2. `/api/provider/anthropic/v1/messages`
3. `/api/provider/openai/v1/responses`
4. back to `/api/provider/anthropic/v1/messages`
5. `/api/internal?setThreadMeta`

Interpretation:

- `internal` = AMP product/session/thread backend
- `anthropic/messages` = smart/runtime/tool orchestration shell
- `openai/responses` = deep reasoning path

Observed bug in existing VibeProxy behavior:

- OpenAI deep path was dropping final `response.output` in `response.completed`
- This broke AMP final response bubbles even when streamed text was visible
- Claude smart mode appears to have a separate issue where thread state can stop updating correctly after routing through local Claude OAuth, likely due to runtime/provider adaptation rather than AMP internal APIs themselves

## Why this project exists

AMP deep mode mixes multiple request types:

- `internal` product/session APIs
- `anthropic/messages` runtime/tooling requests
- `openai/responses` deep reasoning requests

For local OAuth usage, the critical broken edge was OpenAI Responses final output assembly:

- `response.output_text.delta` streamed correctly
- `response.completed.response.output` sometimes arrived empty
- AMP then showed thinking/stream content but lost the final response bubble

This project isolates and fixes that specific path instead of maintaining a general-purpose provider router.

## Development

```bash
cd ~/ampbridge
swift build
swift run ampbridge
```

## How AmpBridge uses your existing subscription

AmpBridge currently does **not** implement its own OpenAI/Claude browser OAuth flow.
Instead, it reuses the local provider backend you already have on this machine.

Current chain:

```text
AMP CLI
  -> http://localhost:8327   (AmpBridge)
  -> http://127.0.0.1:8318   (existing local provider backend)
  -> your existing OAuth/subscription tokens
```

What each layer does:

- **AmpBridge (8327)**
  - Accepts AMP requests
  - Routes AMP auth/internal requests to `ampcode.com`
  - Routes Anthropic provider requests to AMP official backend
  - Routes OpenAI Responses requests to the local provider backend
  - Rewrites/repairs OpenAI Responses SSE output for AMP compatibility

- **Local provider backend (8318)**
  - Uses the existing token files already stored on your machine
  - Actually consumes your OpenAI/Codex/Claude subscription-backed OAuth
  - In the current setup, this is the same backend used by VibeProxy/CLIProxyAPI

- **Local token store**
  - Existing tokens are typically stored under:
    - `~/.cli-proxy-api/*.json`

So today, AmpBridge reuses your existing subscription by forwarding provider traffic to `8318`.
It does **not** yet replace the token-login system.

### Testing AmpBridge directly

To test AmpBridge without disturbing the current VibeProxy setup on `8317`, point AMP to `8327` explicitly:

```bash
AMP_URL=http://localhost:8327 amp --mode deep
```

For a one-shot command:

```bash
AMP_URL=http://localhost:8327 amp --mode deep --dangerously-allow-all -x "Reply with exactly: TEST"
```

### Current default ports

- `8327` — AmpBridge
- `8318` — existing local provider backend (token/OAuth consumer)
- `8317` — current VibeProxy app (if running)

### Important current limitation

AmpBridge currently depends on the existing provider backend on port `8318`.
That means:
- if `8318` is not running, provider requests will fail
- if the token files under `~/.cli-proxy-api/` are missing or expired, provider requests will fail

A future phase may let AmpBridge read token files directly or replace the local provider backend entirely, but that is **not** implemented yet.

## Architecture sketch

- `AmpBridgeConfig.swift` — ports, upstream URLs, enabled routes (default listen port: `8327`)
- `RouteClassifier.swift` — classify incoming AMP paths
- `OpenAIResponsesStreamRewriter.swift` — SSE state machine and final output reconstruction
- `AmpBridgeServer.swift` — bridge server skeleton
- `main.swift` — startup entrypoint
