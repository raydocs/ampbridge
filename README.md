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
- Server/runtime implementation still in progress

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

## Architecture sketch

- `AmpBridgeConfig.swift` — ports, upstream URLs, enabled routes
- `RouteClassifier.swift` — classify incoming AMP paths
- `OpenAIResponsesStreamRewriter.swift` — SSE state machine and final output reconstruction
- `AmpBridgeServer.swift` — bridge server skeleton
- `main.swift` — startup entrypoint
