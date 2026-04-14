import Foundation
import Network

final class HTTPResponseWriter {
    func sendRedirect(on connection: NWConnection, location: String) {
        let headers = "HTTP/1.1 302 Found\r\n" +
        "Location: \(location)\r\n" +
        "Content-Length: 0\r\n" +
        "Connection: close\r\n\r\n"
        connection.send(content: headers.data(using: .utf8), completion: .contentProcessed { _ in
            connection.cancel()
        })
    }

    func sendError(on connection: NWConnection, statusCode: Int, message: String) {
        let bodyData = message.data(using: .utf8) ?? Data()
        let headers = "HTTP/1.1 \(statusCode) \(message)\r\n" +
        "Content-Type: text/plain\r\n" +
        "Content-Length: \(bodyData.count)\r\n" +
        "Connection: close\r\n\r\n"
        var responseData = Data(headers.utf8)
        responseData.append(bodyData)
        connection.send(content: responseData, completion: .contentProcessed { _ in
            connection.cancel()
        })
    }

    func sendRaw(on connection: NWConnection, data: Data, close: Bool = false) {
        connection.send(content: data, completion: .contentProcessed { _ in
            if close {
                connection.send(content: nil, isComplete: true, completion: .contentProcessed({ _ in
                    connection.cancel()
                }))
            }
        })
    }
}
