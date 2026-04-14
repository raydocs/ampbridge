import Foundation

final class OpenAIResponsesStreamRewriter {
    private var pending = Data()
    private var stateByResponseID: [String: ResponseState] = [:]
    private var currentResponseID: String?

    func process(_ data: Data, isComplete: Bool) -> Data {
        pending.append(data)
        var output = Data()

        while let match = nextEventRange(in: pending) {
            let eventData = pending.subdata(in: 0..<match.upperBound)
            pending.removeSubrange(0..<match.upperBound)
            output.append(rewriteEventBlock(eventData))
        }

        if isComplete, !pending.isEmpty {
            output.append(rewriteEventBlock(pending))
            pending.removeAll(keepingCapacity: false)
        }

        if isComplete, let currentResponseID, let state = stateByResponseID[currentResponseID], !state.terminalSeen,
           let synthesized = synthesizeTerminalEvent(for: state) {
            output.append(synthesized)
        }

        return output
    }

    private func synthesizeTerminalEvent(for state: ResponseState) -> Data? {
        let sequenceNumber = state.lastSequenceNumber + 1
        if state.hasRenderableOutput {
            let response = state.buildCompletedResponse(from: [
                "id": state.responseID,
                "object": "response",
                "model": state.model as Any,
                "status": "completed",
                "output": [],
                "usage": state.usage as Any,
                "error": NSNull(),
                "incomplete_details": NSNull()
            ])
            let event: [String: Any] = [
                "type": "response.completed",
                "sequence_number": sequenceNumber,
                "response": response
            ]
            return encodeSSE(eventName: "response.completed", json: event)
        }

        let response: [String: Any] = [
            "id": state.responseID,
            "object": "response",
            "model": state.model as Any,
            "status": "incomplete",
            "output": [],
            "usage": state.usage as Any,
            "error": NSNull(),
            "incomplete_details": ["reason": "stream_ended_unexpectedly"]
        ]
        let event: [String: Any] = [
            "type": "response.incomplete",
            "sequence_number": sequenceNumber,
            "response": response
        ]
        return encodeSSE(eventName: "response.incomplete", json: event)
    }

    private func encodeSSE(eventName: String, json: [String: Any]) -> Data? {
        guard let data = try? JSONSerialization.data(withJSONObject: json),
              let text = String(data: data, encoding: .utf8) else { return nil }
        return Data("event: \(eventName)\ndata: \(text)\n\n".utf8)
    }

    private func ampCompatibleItem(_ item: [String: Any]) -> [String: Any] {
        guard let rawType = item["type"] as? String else {
            return item
        }

        let toolLikeTypes = Set(["function_call", "tool_use", "custom_tool_call"])
        guard toolLikeTypes.contains(rawType) else {
            return item
        }

        var mapped = item
        mapped["type"] = "function_call"

        if mapped["name"] == nil || ((mapped["name"] as? String)?.isEmpty ?? true) {
            if let name = item["name"] as? String, !name.isEmpty {
                mapped["name"] = name
            }
        }

        if let argumentsObject = item["arguments"] as? [String: Any],
           let data = try? JSONSerialization.data(withJSONObject: argumentsObject),
           let argumentsString = String(data: data, encoding: .utf8) {
            mapped["arguments"] = argumentsString
        }

        if mapped["input"] == nil {
            if let arguments = mapped["arguments"] as? String,
               let data = arguments.data(using: .utf8),
               let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                mapped["input"] = json
            } else if let arguments = item["arguments"] as? [String: Any] {
                mapped["input"] = arguments
            } else {
                mapped["input"] = [:]
            }
        }

        if mapped["id"] == nil, let callID = item["call_id"] {
            mapped["id"] = callID
        }

        if mapped["call_id"] == nil, let id = mapped["id"] as? String, !id.isEmpty {
            mapped["call_id"] = id
        }

        return mapped
    }

    private func nextEventRange(in data: Data) -> Range<Int>? {
        let bytes = [UInt8](data)
        if bytes.count < 2 { return nil }

        var i = 0
        while i < bytes.count - 1 {
            if bytes[i] == 0x0A && bytes[i + 1] == 0x0A { // \n\n
                return 0..<(i + 2)
            }
            if i < bytes.count - 3,
               bytes[i] == 0x0D, bytes[i + 1] == 0x0A,
               bytes[i + 2] == 0x0D, bytes[i + 3] == 0x0A { // \r\n\r\n
                return 0..<(i + 4)
            }
            i += 1
        }
        return nil
    }

    private func rewriteEventBlock(_ data: Data) -> Data {
        guard let text = String(data: data, encoding: .utf8) else { return data }

        let delimiter = text.hasSuffix("\r\n\r\n") ? "\r\n\r\n" : (text.hasSuffix("\n\n") ? "\n\n" : "")
        let body = delimiter.isEmpty ? text : String(text.dropLast(delimiter.count))
        let lines = body.replacingOccurrences(of: "\r\n", with: "\n").components(separatedBy: "\n")

        let dataLines = lines.filter { $0.hasPrefix("data:") }
        guard !dataLines.isEmpty else { return data }

        let payload = dataLines.map { line -> String in
            let idx = line.index(line.startIndex, offsetBy: 5)
            let raw = String(line[idx...])
            return raw.hasPrefix(" ") ? String(raw.dropFirst()) : raw
        }.joined(separator: "\n")

        guard payload != "[DONE]",
              let payloadData = payload.data(using: .utf8),
              var json = (try? JSONSerialization.jsonObject(with: payloadData)) as? [String: Any],
              let type = json["type"] as? String else {
            return data
        }

        applyEvent(type: type, json: json)

        if type == "response.output_item.added" || type == "response.output_item.done" {
            if var item = json["item"] as? [String: Any] {
                json["item"] = ampCompatibleItem(item)
            }
        }

        if type == "response.completed",
           let response = json["response"] as? [String: Any],
           let responseID = response["id"] as? String,
           let state = stateByResponseID[responseID] {
            json["response"] = state.buildCompletedResponse(from: response)
        }

        guard let rewrittenData = try? JSONSerialization.data(withJSONObject: json),
              let rewrittenJSON = String(data: rewrittenData, encoding: .utf8) else {
            return data
        }

        var rebuilt: [String] = []
        var replacedData = false
        for line in lines {
            if line.hasPrefix("data:") {
                if !replacedData {
                    rebuilt.append("data: \(rewrittenJSON)")
                    replacedData = true
                }
            } else {
                rebuilt.append(line)
            }
        }

        let finalText = rebuilt.joined(separator: "\n") + delimiter
        return Data(finalText.utf8)
    }

    private func applyEvent(type: String, json: [String: Any]) {
        switch type {
        case "response.created", "response.in_progress":
            guard let response = json["response"] as? [String: Any],
                  let responseID = response["id"] as? String else { return }
            let state = stateByResponseID[responseID] ?? ResponseState(responseID: responseID)
            currentResponseID = responseID
            state.model = response["model"] as? String
            state.status = response["status"] as? String
            state.usage = response["usage"]
            state.lastSequenceNumber = max(state.lastSequenceNumber, json["sequence_number"] as? Int ?? 0)
            stateByResponseID[responseID] = state

        case "response.output_item.added":
            guard let item = json["item"] as? [String: Any],
                  let itemID = item["id"] as? String,
                  let outputIndex = json["output_index"] as? Int else { return }
            let state = state(for: json, item: item)
            state.upsertItem(itemID: itemID, incoming: item, responseJSON: json["response"] as? [String: Any])
            state.outputIndexByItemID[itemID] = outputIndex
            if !state.orderedItemIDs.contains(itemID) {
                state.orderedItemIDs.append(itemID)
            }

        case "response.content_part.added":
            guard let itemID = json["item_id"] as? String,
                  let contentIndex = json["content_index"] as? Int,
                  let part = json["part"] as? [String: Any] else { return }
            let state = state(for: json, itemID: itemID)
            state.setContentPart(itemID: itemID, contentIndex: contentIndex, part: part)

        case "response.output_text.delta":
            guard let itemID = json["item_id"] as? String,
                  let contentIndex = json["content_index"] as? Int,
                  let delta = json["delta"] as? String else { return }
            let state = state(for: json, itemID: itemID)
            state.appendOutputText(itemID: itemID, contentIndex: contentIndex, delta: delta)

        case "response.output_text.done":
            guard let itemID = json["item_id"] as? String,
                  let contentIndex = json["content_index"] as? Int else { return }
            let finalText = json["text"] as? String
            let state = state(for: json, itemID: itemID)
            state.finishOutputText(itemID: itemID, contentIndex: contentIndex, finalText: finalText)

        case "response.function_call_arguments.delta":
            guard let itemID = json["item_id"] as? String,
                  let delta = json["delta"] as? String else { return }
            let state = state(for: json, itemID: itemID)
            state.appendFunctionArguments(itemID: itemID, delta: delta)

        case "response.function_call_arguments.done":
            guard let itemID = json["item_id"] as? String else { return }
            let arguments = json["arguments"] as? String
            let state = state(for: json, itemID: itemID)
            state.finishFunctionArguments(itemID: itemID, finalArguments: arguments)

        case "response.output_item.done":
            guard let item = json["item"] as? [String: Any],
                  let itemID = item["id"] as? String else { return }
            let state = state(for: json, item: item)
            state.upsertItem(itemID: itemID, incoming: item, responseJSON: json["response"] as? [String: Any])

        case "response.completed", "response.failed", "response.incomplete":
            guard let response = json["response"] as? [String: Any],
                  let responseID = response["id"] as? String else { return }
            let state = stateByResponseID[responseID] ?? ResponseState(responseID: responseID)
            currentResponseID = responseID
            state.status = response["status"] as? String
            state.usage = response["usage"]
            state.error = response["error"]
            state.incompleteDetails = response["incomplete_details"]
            state.backfillNamesFromCompletedResponse(response)
            state.terminalSeen = true
            state.lastSequenceNumber = max(state.lastSequenceNumber, json["sequence_number"] as? Int ?? 0)
            stateByResponseID[responseID] = state

        default:
            if let currentResponseID, let state = stateByResponseID[currentResponseID] {
                state.lastSequenceNumber = max(state.lastSequenceNumber, json["sequence_number"] as? Int ?? 0)
            }
            break
        }
    }

    private func state(for json: [String: Any], item: [String: Any]) -> ResponseState {
        if let response = json["response"] as? [String: Any],
           let responseID = response["id"] as? String {
            let state = stateByResponseID[responseID] ?? ResponseState(responseID: responseID)
            currentResponseID = responseID
            stateByResponseID[responseID] = state
            return state
        }
        if let currentResponseID,
           let state = stateByResponseID[currentResponseID] {
            return state
        }
        if let itemID = item["id"] as? String,
           let existing = stateByResponseID.values.first(where: { $0.itemsByID[itemID] != nil }) {
            return existing
        }
        let fallback = stateByResponseID["__fallback__"] ?? ResponseState(responseID: "__fallback__")
        stateByResponseID["__fallback__"] = fallback
        return fallback
    }

    private func state(for json: [String: Any], itemID: String) -> ResponseState {
        if let existing = stateByResponseID.values.first(where: { $0.itemsByID[itemID] != nil }) {
            return existing
        }
        if let response = json["response"] as? [String: Any],
           let responseID = response["id"] as? String {
            let state = stateByResponseID[responseID] ?? ResponseState(responseID: responseID)
            currentResponseID = responseID
            stateByResponseID[responseID] = state
            return state
        }
        if let currentResponseID,
           let state = stateByResponseID[currentResponseID] {
            return state
        }
        let fallback = stateByResponseID["__fallback__"] ?? ResponseState(responseID: "__fallback__")
        stateByResponseID["__fallback__"] = fallback
        return fallback
    }
}

private final class ResponseState {
    let responseID: String
    var model: String?
    var status: String?
    var usage: Any?
    var error: Any?
    var incompleteDetails: Any?
    var itemsByID: [String: [String: Any]] = [:]
    var outputIndexByItemID: [String: Int] = [:]
    var orderedItemIDs: [String] = []
    var terminalSeen = false
    var lastSequenceNumber = 0

    var hasRenderableOutput: Bool {
        orderedItemIDs.contains { id in
            guard let item = itemsByID[id] else { return false }
            let type = item["type"] as? String ?? ""
            if type == "message" {
                let content = item["content"] as? [[String: Any]] ?? []
                return content.contains { !(($0["text"] as? String) ?? "").isEmpty }
            }
            if type == "function_call" {
                return !((item["arguments"] as? String) ?? "").isEmpty || item["name"] != nil
            }
            return true
        }
    }

    init(responseID: String) {
        self.responseID = responseID
    }

    func upsertItem(itemID: String, incoming: [String: Any], responseJSON: [String: Any]?) {
        var merged = itemsByID[itemID] ?? [:]
        for (key, value) in incoming {
            if key == "content",
               let existingContent = merged["content"] as? [[String: Any]],
               let incomingContent = value as? [[String: Any]],
               !existingContent.isEmpty,
               incomingContent.isEmpty {
                continue
            }
            merged[key] = value
        }

        if (merged["name"] as? String)?.isEmpty ?? true {
            if let incomingName = incoming["name"] as? String, !incomingName.isEmpty {
                merged["name"] = incomingName
            } else if let inferredName = inferToolName(for: itemID, item: merged, responseJSON: responseJSON) {
                merged["name"] = inferredName
            }
        }

        itemsByID[itemID] = merged
    }

    func backfillNamesFromCompletedResponse(_ response: [String: Any]) {
        guard let output = response["output"] as? [[String: Any]] else { return }
        for item in output {
            guard let itemID = item["id"] as? String else { continue }
            upsertItem(itemID: itemID, incoming: item, responseJSON: response)
        }
    }

    func setContentPart(itemID: String, contentIndex: Int, part: [String: Any]) {
        ensureItemExists(itemID: itemID)
        var item = itemsByID[itemID] ?? [:]
        var content = item["content"] as? [[String: Any]] ?? []
        while content.count <= contentIndex { content.append([:]) }
        content[contentIndex] = mergedPart(existing: content[contentIndex], incoming: part)
        item["content"] = content
        itemsByID[itemID] = item
    }

    func appendOutputText(itemID: String, contentIndex: Int, delta: String) {
        ensureItemExists(itemID: itemID)
        var item = itemsByID[itemID] ?? [:]
        var content = item["content"] as? [[String: Any]] ?? []
        while content.count <= contentIndex { content.append(["type": "output_text", "text": "", "annotations": []]) }
        var part = content[contentIndex]
        let existingText = part["text"] as? String ?? ""
        if part["type"] == nil { part["type"] = "output_text" }
        if part["annotations"] == nil { part["annotations"] = [] }
        part["text"] = existingText + delta
        content[contentIndex] = part
        item["content"] = content
        itemsByID[itemID] = item
    }

    func finishOutputText(itemID: String, contentIndex: Int, finalText: String?) {
        ensureItemExists(itemID: itemID)
        guard var item = itemsByID[itemID] else { return }
        var content = item["content"] as? [[String: Any]] ?? []
        while content.count <= contentIndex { content.append(["type": "output_text", "text": "", "annotations": []]) }
        var part = content[contentIndex]
        if let finalText { part["text"] = finalText }
        if part["type"] == nil { part["type"] = "output_text" }
        if part["annotations"] == nil { part["annotations"] = [] }
        content[contentIndex] = part
        item["content"] = content
        itemsByID[itemID] = item
    }

    func appendFunctionArguments(itemID: String, delta: String) {
        ensureItemExists(itemID: itemID)
        var item = itemsByID[itemID] ?? [:]
        let existing = item["arguments"] as? String ?? ""
        item["arguments"] = existing + delta
        itemsByID[itemID] = item
    }

    func finishFunctionArguments(itemID: String, finalArguments: String?) {
        ensureItemExists(itemID: itemID)
        guard var item = itemsByID[itemID] else { return }
        if let finalArguments { item["arguments"] = finalArguments }
        itemsByID[itemID] = item
    }

    func buildCompletedResponse(from upstream: [String: Any]) -> [String: Any] {
        var response = upstream
        let upstreamOutput = response["output"] as? [[String: Any]] ?? []
        if !upstreamOutput.isEmpty {
            response["output"] = upstreamOutput.map { normalizeCompletedItem($0) }
            return response
        }

        let synthesizedOutput = orderedItemIDs
            .sorted { (outputIndexByItemID[$0] ?? .max) < (outputIndexByItemID[$1] ?? .max) }
            .compactMap { itemsByID[$0] }
            .filter { item in
                let type = item["type"] as? String ?? ""
                if type == "message" {
                    let content = item["content"] as? [[String: Any]] ?? []
                    return content.contains { (($0["text"] as? String) ?? "").isEmpty == false }
                }
                if type == "function_call" {
                    return ((item["arguments"] as? String) ?? "").isEmpty == false || item["name"] != nil
                }
                return true
            }

        if !synthesizedOutput.isEmpty {
            response["output"] = synthesizedOutput.map { normalizeCompletedItem($0) }
        }
        return response
    }

    private func normalizeCompletedItem(_ item: [String: Any]) -> [String: Any] {
        var normalized = item
        if let type = item["type"] as? String,
           ["function_call", "tool_use", "custom_tool_call"].contains(type) {
            normalized["type"] = "function_call"

            if let argumentsObject = item["arguments"] as? [String: Any],
               let data = try? JSONSerialization.data(withJSONObject: argumentsObject),
               let argumentsString = String(data: data, encoding: .utf8) {
                normalized["arguments"] = argumentsString
            }

            if normalized["input"] == nil {
                if let arguments = normalized["arguments"] as? String,
                   let data = arguments.data(using: .utf8),
                   let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                    normalized["input"] = json
                } else {
                    normalized["input"] = [:]
                }
            }

            if normalized["id"] == nil, let callID = item["call_id"] {
                normalized["id"] = callID
            }
            if normalized["call_id"] == nil, let id = normalized["id"] as? String, !id.isEmpty {
                normalized["call_id"] = id
            }
        }
        return normalized
    }

    private func mergedPart(existing: [String: Any], incoming: [String: Any]) -> [String: Any] {
        var merged = existing
        for (key, value) in incoming {
            if key == "text", let incomingText = value as? String {
                let existingText = merged["text"] as? String ?? ""
                merged["text"] = existingText.isEmpty ? incomingText : existingText
            } else {
                merged[key] = value
            }
        }
        if merged["annotations"] == nil { merged["annotations"] = [] }
        return merged
    }

    private func ensureItemExists(itemID: String) {
        if itemsByID[itemID] == nil {
            itemsByID[itemID] = [
                "id": itemID,
                "type": "message",
                "role": "assistant",
                "status": "completed",
                "phase": "final_answer",
                "content": []
            ]
        }
        if !orderedItemIDs.contains(itemID) {
            orderedItemIDs.append(itemID)
        }
    }

    private func inferToolName(for itemID: String, item: [String: Any], responseJSON: [String: Any]?) -> String? {
        if let name = item["name"] as? String, !name.isEmpty {
            return name
        }
        if let responseJSON,
           let output = responseJSON["output"] as? [[String: Any]],
           let match = output.first(where: { ($0["id"] as? String) == itemID }),
           let matchName = match["name"] as? String,
           !matchName.isEmpty {
            return matchName
        }
        if let responseJSON,
           let tools = responseJSON["tools"] as? [[String: Any]],
           tools.count == 1,
           let onlyToolName = tools.first?["name"] as? String,
           !onlyToolName.isEmpty {
            return onlyToolName
        }
        return nil
    }
}
