import Foundation

struct HTTPRequest {
    let method: String
    let path: String
    let version: String
    let headers: [(String, String)]
    let body: Data

    var bodyString: String {
        String(data: body, encoding: .utf8) ?? ""
    }
}

enum HTTPRequestParser {
    static func parse(data: Data) -> HTTPRequest? {
        guard let requestString = String(data: data, encoding: .utf8),
              let bodyStartRange = requestString.range(of: "\r\n\r\n") else {
            return nil
        }

        let lines = requestString.components(separatedBy: "\r\n")
        guard let requestLine = lines.first else { return nil }
        let parts = requestLine.components(separatedBy: " ")
        guard parts.count >= 3 else { return nil }

        var headers: [(String, String)] = []
        for line in lines.dropFirst() {
            if line.isEmpty { break }
            guard let separatorIndex = line.firstIndex(of: ":") else { continue }
            let name = String(line[..<separatorIndex]).trimmingCharacters(in: .whitespaces)
            let valueStart = line.index(after: separatorIndex)
            let value = String(line[valueStart...]).trimmingCharacters(in: .whitespaces)
            headers.append((name, value))
        }

        let bodyStart = requestString.distance(from: requestString.startIndex, to: bodyStartRange.upperBound)
        let bodySlice = requestString[requestString.index(requestString.startIndex, offsetBy: bodyStart)...]
        let bodyData = Data(bodySlice.utf8)

        return HTTPRequest(
            method: parts[0],
            path: parts[1],
            version: parts[2],
            headers: headers,
            body: bodyData
        )
    }
}
