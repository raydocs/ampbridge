import Foundation

struct HTTPRequest {
    let method: String
    let path: String
    let version: String
    let headers: [(String, String)]
    let body: Data

    func headerValue(named name: String) -> String? {
        headers.first { header, _ in
            header.caseInsensitiveCompare(name) == .orderedSame
        }?.1
    }

    var bodyString: String {
        String(data: body, encoding: .utf8) ?? ""
    }
}

enum HTTPRequestParser {
    private enum BodyFraming {
        case none
        case contentLength(Int)
        case chunked
    }

    private enum ChunkedBodyInspection {
        case incomplete
        case malformed
        case complete(Data)
    }

    private static let headerDelimiter = Data([13, 10, 13, 10])
    private static let lineDelimiter = Data([13, 10])

    static func isCompleteRequest(_ data: Data) -> Bool {
        guard let (head, body) = splitHeadAndBody(data) else {
            return false
        }
        guard let (_, _, _, headers) = parseRequestHead(head) else {
            return true
        }
        guard let framing = bodyFraming(for: headers) else {
            return true
        }

        switch framing {
        case .none:
            return true
        case .contentLength(let length):
            return body.count >= length
        case .chunked:
            switch inspectChunkedBody(body) {
            case .incomplete:
                return false
            case .malformed, .complete:
                return true
            }
        }
    }

    static func parse(data: Data) -> HTTPRequest? {
        guard let (head, body) = splitHeadAndBody(data),
              let (method, path, version, headers) = parseRequestHead(head),
              let framing = bodyFraming(for: headers) else {
            return nil
        }

        let parsedBody: Data
        switch framing {
        case .none:
            parsedBody = Data()
        case .contentLength(let length):
            guard body.count >= length else { return nil }
            parsedBody = Data(body.prefix(length))
        case .chunked:
            guard let decoded = decodeChunkedBody(body) else { return nil }
            parsedBody = decoded
        }

        return HTTPRequest(
            method: method,
            path: path,
            version: version,
            headers: headers,
            body: parsedBody
        )
    }

    static func splitHeadAndBody(_ data: Data) -> (head: Data, body: Data)? {
        guard let delimiterRange = data.range(of: headerDelimiter) else {
            return nil
        }

        return (
            head: data.subdata(in: data.startIndex..<delimiterRange.lowerBound),
            body: Data(data[delimiterRange.upperBound..<data.endIndex])
        )
    }

    static func parseRequestHead(_ head: Data) -> (method: String, path: String, version: String, headers: [(String, String)])? {
        guard let headString = String(data: head, encoding: .utf8) else {
            return nil
        }

        let lines = headString.components(separatedBy: "\r\n")
        guard let requestLine = lines.first, !requestLine.isEmpty else {
            return nil
        }

        let parts = requestLine.split(separator: " ", omittingEmptySubsequences: true)
        guard parts.count == 3 else {
            return nil
        }

        var headers: [(String, String)] = []
        for line in lines.dropFirst() {
            guard !line.isEmpty else { continue }
            guard let separatorIndex = line.firstIndex(of: ":") else {
                return nil
            }
            let name = String(line[..<separatorIndex]).trimmingCharacters(in: .whitespaces)
            let valueStart = line.index(after: separatorIndex)
            let value = String(line[valueStart...]).trimmingCharacters(in: .whitespaces)
            headers.append((name, value))
        }

        return (
            method: String(parts[0]),
            path: String(parts[1]),
            version: String(parts[2]),
            headers: headers
        )
    }

    private static func bodyFraming(for headers: [(String, String)]) -> BodyFraming? {
        let transferEncodingValues = headers
            .filter { $0.0.caseInsensitiveCompare("Transfer-Encoding") == .orderedSame }
            .map(\.1)
        let contentLengthValues = headers
            .filter { $0.0.caseInsensitiveCompare("Content-Length") == .orderedSame }
            .map { $0.1.trimmingCharacters(in: .whitespacesAndNewlines) }

        if !transferEncodingValues.isEmpty {
            if !contentLengthValues.isEmpty {
                return nil
            }

            let encodings = transferEncodingValues
                .flatMap { $0.split(separator: ",") }
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }
            guard !encodings.isEmpty, encodings.last == "chunked" else {
                return nil
            }
            return .chunked
        }

        if !contentLengthValues.isEmpty {
            guard Set(contentLengthValues).count == 1,
                  let firstValue = contentLengthValues.first,
                  let length = Int(firstValue),
                  length >= 0 else {
                return nil
            }
            return .contentLength(length)
        }

        return BodyFraming.none
    }

    static func decodeChunkedBody(_ body: Data) -> Data? {
        switch inspectChunkedBody(body) {
        case .complete(let output):
            return output
        case .incomplete, .malformed:
            return nil
        }
    }

    private static func inspectChunkedBody(_ body: Data) -> ChunkedBodyInspection {
        var index = body.startIndex
        var output = Data()

        while true {
            guard let sizeLineRange = body.range(of: lineDelimiter, options: [], in: index..<body.endIndex) else {
                return .incomplete
            }

            let sizeLineData = body.subdata(in: index..<sizeLineRange.lowerBound)
            guard let sizeLine = String(data: sizeLineData, encoding: .utf8) else {
                return .malformed
            }

            let sizeComponent = sizeLine
                .split(separator: ";", maxSplits: 1, omittingEmptySubsequences: false)
                .first
                .map(String.init) ?? ""
            let trimmedSize = sizeComponent.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmedSize.isEmpty, let chunkSize = Int(trimmedSize, radix: 16) else {
                return .malformed
            }

            index = sizeLineRange.upperBound

            if chunkSize == 0 {
                while true {
                    guard let trailerLineRange = body.range(of: lineDelimiter, options: [], in: index..<body.endIndex) else {
                        return .incomplete
                    }

                    let trailerLineData = body.subdata(in: index..<trailerLineRange.lowerBound)
                    guard trailerLineData.isEmpty || String(data: trailerLineData, encoding: .utf8) != nil else {
                        return .malformed
                    }

                    index = trailerLineRange.upperBound
                    if trailerLineData.isEmpty {
                        return .complete(output)
                    }
                }
            }

            guard let chunkEnd = body.index(index, offsetBy: chunkSize, limitedBy: body.endIndex),
                  let terminatorEnd = body.index(chunkEnd, offsetBy: 2, limitedBy: body.endIndex) else {
                return .incomplete
            }

            let carriageReturnIndex = chunkEnd
            let newlineIndex = body.index(after: carriageReturnIndex)
            guard body[carriageReturnIndex] == 13, body[newlineIndex] == 10 else {
                return .malformed
            }

            output.append(body.subdata(in: index..<chunkEnd))
            index = terminatorEnd
        }
    }
}
