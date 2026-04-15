# AmpBridge

AmpBridge is a focused local bridge for routing AMP traffic so that, in the verified scenarios below:

- AMP auth/internal/thread endpoints stay on `https://ampcode.com`
- AMP Anthropic provider traffic stays on `https://ampcode.com`
- AMP OpenAI provider traffic goes to the local provider backend on `http://127.0.0.1:8318`
- OpenAI Responses SSE is rewritten only when the upstream response is actually SSE
- streamed OpenAI Responses terminate cleanly on logical end (`[DONE]` or explicit terminal event)

## Current verified routing

Default ports:

- `8327` — AmpBridge
- `8318` — existing local provider backend
- `8317` — VibeProxy, if you still have it running

Route behavior:

1. `/auth/cli-login` and `/api/auth/cli-login` → redirect to `https://ampcode.com`
2. `/api/internal...` → official AMP backend
3. `/api/provider/anthropic/...` → official AMP backend
4. `/api/provider/openai/v1/responses...` → local provider backend, path rewritten to `/v1/responses...`, SSE rewrite enabled only for `text/event-stream`
5. `/api/provider/openai/...` → local provider backend, path rewritten by stripping `/api/provider/openai`
6. `/v1/...` and `/api/v1/...` → local provider backend unchanged
7. other `/api/provider/...` routes → `501 Unsupported provider`
8. unknown routes → official AMP backend

## Current protocol/runtime behavior

- Request parsing is raw-byte based instead of UTF-8-whole-request based.
- `Content-Length` and `Transfer-Encoding: chunked` request bodies are supported.
- conflicting request framing (`Transfer-Encoding` plus `Content-Length`, or mismatched repeated `Content-Length`) is rejected as bad request.
- OpenAI Responses SSE is rewritten for AMP compatibility.
- `[DONE]` now causes logical stream completion immediately; AmpBridge synthesizes a terminal event first when needed.
- non-streaming `/responses` JSON errors are preserved as JSON and are not mislabeled as SSE.

## How AmpBridge uses your existing local provider backend

Current chain:

```text
AMP CLI
  -> http://localhost:8327   (AmpBridge)
  -> http://127.0.0.1:8318   (existing local provider backend)
  -> your existing local tokens/subscription-backed auth
```

AmpBridge does not currently implement its own browser OAuth flow. It assumes the local provider backend on `8318` is already working.

## Development

```bash
cd ~/ampbridge
swift build
swift run ampbridge
```

Run AMP against the bridge explicitly:

```bash
AMP_URL=http://localhost:8327 amp --mode deep
```

One-shot execute example:

```bash
AMP_URL=http://localhost:8327 amp --mode deep --dangerously-allow-all -x "Reply with exactly: TEST"
```

## Verification evidence

Verification date: April 14, 2026 (America/Denver) / April 15, 2026 UTC during command runs below.

### 1. Bridge builds cleanly

```bash
swift build
```

Observed:

```text
Build complete! (1.17s)
```

### 2. Intended GPT/OpenAI path works through the bridge

Create a deep-mode thread through the bridge:

```bash
AMP_URL=http://localhost:8327 amp --no-color -m deep threads new
```

Observed:

```text
T-019d8ea1-0195-734b-a72b-03ebf504c654
```

Run a one-shot reply in that thread:

```bash
AMP_URL=http://localhost:8327 amp --no-color --no-ide --no-jetbrains --dangerously-allow-all -m deep threads continue T-019d8ea1-0195-734b-a72b-03ebf504c654 -x 'Reply with exactly: BRIDGE_ITEM3_ALPHA'
```

Observed output:

```text
BRIDGE_ITEM3_ALPHA
```

Observed AmpBridge logs:

```text
AmpBridge request: POST /api/provider/anthropic/v1/messages -> anthropicProvider
AmpBridge request: POST /api/provider/openai/v1/responses -> openAIResponses
AmpBridge SSE logical end reached for /api/provider/openai/v1/responses
```

### 3. Thread continuation still works

Continue the same thread with a follow-up that depends on prior context:

```bash
AMP_URL=http://localhost:8327 amp --no-color --no-ide --no-jetbrains --dangerously-allow-all -m deep threads continue T-019d8ea1-0195-734b-a72b-03ebf504c654 -x 'What exact token did you reply with previously? Reply with exactly that token and nothing else.'
```

Observed output:

```text
BRIDGE_ITEM3_ALPHA
```

Exported thread markdown:

```markdown
# BRIDGE_ITEM3_ALPHA

## User
Reply with exactly: BRIDGE_ITEM3_ALPHA

## Assistant
BRIDGE_ITEM3_ALPHA

## User
What exact token did you reply with previously? Reply with exactly that token and nothing else.

## Assistant
BRIDGE_ITEM3_ALPHA
```

### 4. Stream end no longer stalls silently

For real AMP deep-mode replies, AmpBridge logged logical end and the CLI returned normally.

Observed log excerpt:

```text
AmpBridge request: POST /api/provider/openai/v1/responses -> openAIResponses
AmpBridge SSE logical end reached for /api/provider/openai/v1/responses
```

A dedicated local mock probe also proved that the downstream client finished immediately after `[DONE]` even when the upstream socket stayed open for 8 more seconds; see commit history / local verification notes for the exact probe commands used during development.

### 5. Execute-mode web search / tool loop blocker

A real deep-mode search-oriented prompt through the bridge:

```bash
/usr/bin/time -p env AMP_URL=http://localhost:8327 amp --no-color --no-ide --no-jetbrains --dangerously-allow-all -m deep threads continue T-019d8ea2-6f90-74ed-87d7-d2241cda32c0 -x 'Use web search to answer this. What is the current price of Bitcoin in USD right now? Start with USED_WEB_SEARCH, include one source URL, and keep the answer under 3 sentences.'
```

Observed final output:

```text
USED_WEB_SEARCH Bitcoin is about `$74,500.40` USD right now, based on Coinbase’s live spot price feed. Source: https://api.coinbase.com/v2/prices/spot?currency=USD
real 19.80
```

Observed bridge logs during that run:

```text
AmpBridge request: POST /api/internal?webSearch2 -> internalAPI
AmpBridge request: POST /api/provider/openai/v1/responses -> openAIResponses
AmpBridge SSE logical end reached for /api/provider/openai/v1/responses
AmpBridge request: POST /api/provider/openai/v1/responses -> openAIResponses
AmpBridge SSE logical end reached for /api/provider/openai/v1/responses
```

However, exported thread markdown shows the built-in AMP `web_search` tool failed in execute mode and the agent fell back to `shell_command`:

```markdown
## Assistant
**Tool Use:** `web_search`

## User
**Tool Error:** ... Failed to perform web search: Amp Free is not available in execute mode or the Amp SDK.

## Assistant
The dedicated web search tool is unavailable in this environment, so I’m falling back to a live public market-data endpoint...
```

To confirm that this is not caused by AmpBridge, the same prompt was run directly against official AMP without the bridge:

```bash
/usr/bin/time -p amp --no-color --no-ide --no-jetbrains --dangerously-allow-all -m deep threads continue T-019d8ea4-bbc3-750b-9668-e3c652170643 -x 'Use web search to answer this. What is the current price of Bitcoin in USD right now? Start with USED_WEB_SEARCH, include one source URL, and keep the answer under 3 sentences.'
```

Observed official-AMP output:

```text
Error: 402 Execute mode (amp -x) and the Amp SDK require paid credits and cannot use Amp Free in non-interactive contexts. Add credits at https://ampcode.com/pay to continue.
real 2.25
```

Current conclusion:

- GPT/OpenAI deep-mode bridge path is working for the verified execute-mode scenarios above.
- same-thread continuation is working for the verified thread above.
- stream-end handling is working.
- execute-mode verification of built-in web search / tool flows remains blocked by AMP Free / paid-credit restrictions on the AMP side, so full built-in-search success is still not proven end-to-end through AmpBridge.

## Source files

- `Sources/AmpBridgeConfig.swift`
- `Sources/AmpBridgeServer.swift`
- `Sources/HTTPRequest.swift`
- `Sources/HTTPResponseWriter.swift`
- `Sources/OpenAIResponsesStreamRewriter.swift`
- `Sources/RouteClassifier.swift`
- `Sources/main.swift`
