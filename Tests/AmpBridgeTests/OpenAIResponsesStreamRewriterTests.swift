import Foundation
import Testing
@testable import AmpBridge

struct OpenAIResponsesStreamRewriterTests {
    @Test
    func syntheticSearchRegressionKeepsStreamOpenUntilDone() throws {
        let fixture = try loadFixture(named: "search-export-regression.synthetic")
        let blocks = fixture
            .replacingOccurrences(of: "\r\n", with: "\n")
            .components(separatedBy: "\n\n")
            .filter { !$0.isEmpty }

        let firstChunk = blocks.prefix(4).joined(separator: "\n\n") + "\n\n"
        let secondChunk = blocks.dropFirst(4).joined(separator: "\n\n") + "\n\n"

        let rewriter = OpenAIResponsesStreamRewriter()

        let earlyResult = rewriter.process(Data(firstChunk.utf8), isTransportComplete: false)
        #expect(!earlyResult.shouldCloseDownstream, "An early response.completed must not close the downstream stream before later authoritative content or [DONE].")

        let earlyOutput = try #require(String(data: earlyResult.output, encoding: .utf8))
        let earlyEvents = try parseSSE(earlyOutput)
        #expect(earlyEvents.compactMap(\.type) == [
            "response.created",
            "response.output_item.added",
            "response.content_part.added",
            "response.completed"
        ])

        let finalResult = rewriter.process(Data(secondChunk.utf8), isTransportComplete: false)
        #expect(finalResult.shouldCloseDownstream, "[DONE] should be the close signal when the transport is still open.")

        let finalOutput = try #require(String(data: finalResult.output, encoding: .utf8))
        let finalEvents = try parseSSE(finalOutput)
        #expect(finalEvents.contains(where: { $0.type == "response.content_part.done" }))
        #expect(finalEvents.contains(where: { $0.type == "response.completed" }))
        #expect(finalEvents.contains(where: { $0.isDone }))
        #expect(finalOutput.contains("Final assistant conclusion."))
    }

    @Test
    func syntheticSearchRegressionRefreshesCompletedOutputWithFinalConclusion() throws {
        let fixture = try loadFixture(named: "search-export-regression.synthetic")
        let rewriter = OpenAIResponsesStreamRewriter()
        let result = rewriter.process(Data(fixture.utf8), isTransportComplete: true)
        let output = try #require(String(data: result.output, encoding: .utf8))
        let outputEvents = try parseSSE(output)

        #expect(result.shouldCloseDownstream)
        #expect(outputEvents.contains(where: { $0.isDone }))

        let completedEvents = outputEvents.filter { $0.type == "response.completed" }
        #expect(completedEvents.count == 2, "The original early terminal event is preserved, then refreshed at stream end once late authoritative content arrives.")

        let completed = try #require(completedEvents.last)
        let response = try #require(completed.json?["response"] as? [String: Any])
        let items = try #require(response["output"] as? [[String: Any]])
        #expect(items.count == 1)

        let content = try #require(items[0]["content"] as? [[String: Any]])
        #expect(content.count == 1)
        #expect(content[0]["text"] as? String == "## Findings\nFinal assistant conclusion.")
        #expect(output.contains("Final assistant conclusion."))
    }

    @Test
    func transportEOFWithoutDoneSynthesizesCompletedFromLateFinalAnswer() throws {
        let stream = makeSSE([
            ("response.created", [
                "type": "response.created",
                "sequence_number": 1,
                "response": baseResponse(id: "resp_eof", status: "in_progress", output: [])
            ]),
            ("response.output_item.added", [
                "type": "response.output_item.added",
                "sequence_number": 2,
                "output_index": 0,
                "item": [
                    "id": "msg_eof",
                    "type": "message",
                    "role": "assistant",
                    "status": "in_progress",
                    "content": []
                ],
                "response": ["id": "resp_eof"]
            ]),
            ("response.content_part.done", [
                "type": "response.content_part.done",
                "sequence_number": 3,
                "item_id": "msg_eof",
                "content_index": 0,
                "part": [
                    "type": "output_text",
                    "text": "Final answer from EOF.",
                    "annotations": []
                ]
            ])
        ])

        let rewriter = OpenAIResponsesStreamRewriter()
        let result = rewriter.process(Data(stream.utf8), isTransportComplete: true)
        let output = try #require(String(data: result.output, encoding: .utf8))
        let outputEvents = try parseSSE(output)

        #expect(result.shouldCloseDownstream)
        #expect(!outputEvents.contains(where: { $0.isDone }))

        let completed = try #require(outputEvents.last(where: { $0.type == "response.completed" }))
        let response = try #require(completed.json?["response"] as? [String: Any])
        let items = try #require(response["output"] as? [[String: Any]])
        let content = try #require(items.first?["content"] as? [[String: Any]])
        #expect(content.first?["text"] as? String == "Final answer from EOF.")
    }

    @Test
    func thinkingOnlyLateContentDoesNotRefreshIntoCompletedConclusion() throws {
        let stream = makeSSE([
            ("response.created", [
                "type": "response.created",
                "sequence_number": 1,
                "response": baseResponse(id: "resp_thinking", status: "in_progress", output: [])
            ]),
            ("response.output_item.added", [
                "type": "response.output_item.added",
                "sequence_number": 2,
                "output_index": 0,
                "item": [
                    "id": "msg_thinking",
                    "type": "message",
                    "role": "assistant",
                    "status": "in_progress",
                    "content": []
                ],
                "response": ["id": "resp_thinking"]
            ]),
            ("response.completed", [
                "type": "response.completed",
                "sequence_number": 3,
                "response": baseResponse(id: "resp_thinking", status: "completed", output: [], usage: ["total_tokens": 9])
            ]),
            ("response.content_part.done", [
                "type": "response.content_part.done",
                "sequence_number": 4,
                "item_id": "msg_thinking",
                "content_index": 0,
                "part": [
                    "type": "reasoning",
                    "text": "Hidden chain of thought",
                    "annotations": []
                ]
            ])
        ])

        let rewriter = OpenAIResponsesStreamRewriter()
        let result = rewriter.process(Data(stream.utf8), isTransportComplete: true)
        let output = try #require(String(data: result.output, encoding: .utf8))
        let outputEvents = try parseSSE(output)

        #expect(result.shouldCloseDownstream)
        #expect(!outputEvents.contains(where: { $0.isDone }))
        #expect(outputEvents.filter { $0.type == "response.completed" }.count == 1)

        let terminal = try #require(outputEvents.last(where: { $0.type == "response.incomplete" }))
        let response = try #require(terminal.json?["response"] as? [String: Any])
        #expect(response["status"] as? String == "incomplete")
        #expect((response["output"] as? [[String: Any]] ?? []).isEmpty)
    }
}

private struct SSEEvent {
    let type: String?
    let json: [String: Any]?
    let isDone: Bool
}

private func baseResponse(id: String, status: String, output: [[String: Any]], usage: [String: Any]? = nil) -> [String: Any] {
    [
        "id": id,
        "object": "response",
        "model": "gpt-5",
        "status": status,
        "output": output,
        "usage": usage ?? NSNull(),
        "error": NSNull(),
        "incomplete_details": NSNull()
    ]
}

private func makeSSE(_ events: [(String, [String: Any])]) -> String {
    events.map { eventName, payload in
        let data = try! JSONSerialization.data(withJSONObject: payload)
        let json = String(decoding: data, as: UTF8.self)
        return "event: \(eventName)\ndata: \(json)\n\n"
    }.joined()
}

private func loadFixture(named name: String) throws -> String {
    let bundle = Bundle.module
    let url = bundle.url(forResource: name, withExtension: "sse", subdirectory: "Fixtures")
        ?? bundle.url(forResource: name, withExtension: "sse")
    let resolvedURL = try #require(url)
    return try String(contentsOf: resolvedURL, encoding: .utf8)
}

private func parseSSE(_ text: String) throws -> [SSEEvent] {
    let normalized = text.replacingOccurrences(of: "\r\n", with: "\n")
    return try normalized
        .components(separatedBy: "\n\n")
        .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
        .filter { !$0.isEmpty }
        .map(parseSSEBlock)
}

private func parseSSEBlock(_ block: String) throws -> SSEEvent {
    let payload = block
        .split(separator: "\n")
        .filter { $0.hasPrefix("data:") }
        .map { line -> String in
            let raw = line.dropFirst(5)
            return raw.first == " " ? String(raw.dropFirst()) : String(raw)
        }
        .joined(separator: "\n")

    if payload == "[DONE]" {
        return SSEEvent(type: nil, json: nil, isDone: true)
    }

    let data = try #require(payload.data(using: .utf8))
    let object = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
    return SSEEvent(type: object["type"] as? String, json: object, isDone: false)
}
