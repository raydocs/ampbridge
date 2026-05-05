# Optimize: AmpBridge bridge/local latency

**Metric:** Primary `timeToFirstTokenMs` from AMP `[openai-responses]` logs for bridge/local `amp --mode deep --effort medium --execute` prompt. Secondary: `timeToFirstByteMs`, `totalElapsedMs`, AMP command wall seconds.
**Stop criterion:** Reduce median bridge/local `timeToFirstTokenMs` by at least 20% from multi-run baseline, or stop when Oracle says gains have plateaued / risk is not worth it. Must not switch steady-state use to AMP paid credits; optimize local bridge/provider route only.
**Scope:** `Sources/AmpBridgeServer.swift` OpenAI Responses SSE proxy/forwarding path, adjacent stream rewriting/tests, and support measurement files only.
**Environment:** macOS local repo `/Users/ruirui/Downloads/GitHub/ampbridge`; no `AGENTS.md` present; README says `swift build`, `swift test`, run bridge with `swift run ampbridge`, switch with `Scripts/amp-mode` / `amp-mode`.

## Runs

| # | Change | Samples | Median TTFT | Median TTFB | Median stream total | Median wall | Notes |
|---|---|---:|---:|---:|---:|---:|---|
| baseline | — | 3 | 2700 ms | 1603 ms | 4702 ms | 8.279 s | bridge/local only; samples TTFT `[2700, 1918, 3919]`, TTFB `[1603, 1315, 1929]`, total `[4702, 4565, 6155]`, wall `[8.279, 7.843, 9.975]`; model `gpt-5.5`, effort `medium`; eventCount not treated as tokens. |
| 1 | Chunk-oriented upstream streaming via URLSessionDataDelegate in bridge/local proxy path | 3 | 1486 ms | 946 ms | 787 ms | 3.460 s | Non-comparable: used shorter prompt `Reply with exactly: LATENCY_PROBE`; bridge/local only; samples TTFT `[1486, 1556, 1292]`, TTFB `[996, 946, 906]`, total `[787, 929, 642]`, wall `[3.520, 3.460, 3.020]`; eventCount `[12, 12, 12]` counted as events only, not tokens. |
| 1b | Corrected measurement for chunk-oriented upstream streaming | 3 | 1844 ms | 943 ms | 4268 ms | 6.710 s | Comparable to baseline prompt: `请输出一段约300个汉字的中文短文，主题是：本地代理延迟测试。不要使用列表，不要解释，只输出正文。`; bridge/local only; samples TTFT `[1844, 1759, 2008]`, TTFB `[1027, 943, 912]`, total `[4907, 4268, 4229]`, wall `[7.860, 6.710, 6.690]`; eventCount `[193, 181, 155]` counted as events only, not tokens. |
| 1c | Resource-safety hardening for chunk-stream adapter | 1 | 1701 ms | 1089 ms | 4632 ms | 7.790 s | Smoke only after hardening; same Chinese baseline prompt; bridge/local only; samples TTFT `[1701]`, TTFB `[1089]`, total `[4632]`, wall `[7.790]`; eventCount `[199]` counted as events only, not tokens. |
| 1d | Final review cleanup smoke | 1 | 1902 ms | 1212 ms | 4261 ms | 7.505 s | Smoke after Oracle review fixes (centralized cancellation cleanup, cancellation-as-error, suspend/resume outside lock, removed dead session); same Chinese baseline prompt; bridge/local only; eventCount `[167]` counted as events only, not tokens. |
| 1e | Final review-cleaned code, 3-sample measurement | 3 | 1902 ms | 1165 ms | 4810 ms | 7.505 s | Final comparable row after review fixes; same Chinese baseline prompt; bridge/local only; samples TTFT `[1902, 2067, 1826]`, TTFB `[1212, 1165, 687]`, total `[4261, 5750, 4810]`, wall `[7.505, 9.156, 7.216]`; eventCount `[167, 198, 176]` counted as events only, not tokens. |
