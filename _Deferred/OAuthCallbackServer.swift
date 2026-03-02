import Foundation
import Network

/// A minimal local HTTP server that listens on 127.0.0.1 for OAuth callbacks.
/// Spotify allows HTTP redirects to localhost, so the macOS client catches the
/// callback here and forwards the authorization code to the remote NeedleDrop server.
final class OAuthCallbackServer: @unchecked Sendable {
    static let port: UInt16 = 21453
    static let redirectURI = "http://127.0.0.1:\(port)/callback"

    private var listener: NWListener?
    private var continuation: CheckedContinuation<String, Error>?

    enum CallbackError: Error, LocalizedError {
        case serverStartFailed
        case noCodeReceived
        case cancelled

        var errorDescription: String? {
            switch self {
            case .serverStartFailed: return "Could not start local OAuth server"
            case .noCodeReceived: return "No authorization code in callback"
            case .cancelled: return "OAuth flow cancelled"
            }
        }
    }

    /// Start the server and wait for Spotify to redirect with an auth code.
    /// Returns the authorization code string.
    func waitForCallback() async throws -> String {
        try await withCheckedThrowingContinuation { continuation in
            self.continuation = continuation

            do {
                let params = NWParameters.tcp
                let listener = try NWListener(using: params, on: NWEndpoint.Port(rawValue: Self.port)!)
                self.listener = listener

                listener.newConnectionHandler = { [weak self] connection in
                    self?.handleConnection(connection)
                }

                listener.stateUpdateHandler = { [weak self] state in
                    if case .failed = state {
                        self?.continuation?.resume(throwing: CallbackError.serverStartFailed)
                        self?.continuation = nil
                        self?.stop()
                    }
                }

                listener.start(queue: .global(qos: .userInitiated))
            } catch {
                continuation.resume(throwing: CallbackError.serverStartFailed)
                self.continuation = nil
            }
        }
    }

    /// Stop the listener and clean up.
    func stop() {
        listener?.cancel()
        listener = nil
    }

    // MARK: - Private

    private func handleConnection(_ connection: NWConnection) {
        connection.start(queue: .global(qos: .userInitiated))

        // Read the HTTP request (the first chunk is enough for our purposes)
        connection.receive(minimumIncompleteLength: 1, maximumLength: 8192) { [weak self] data, _, _, _ in
            guard let self, let data, let request = String(data: data, encoding: .utf8) else {
                connection.cancel()
                return
            }

            // Parse the request line: "GET /callback?code=XXXX HTTP/1.1"
            let code = self.extractCode(from: request)
            let responseHTML: String
            let statusLine: String

            if code != nil {
                statusLine = "HTTP/1.1 200 OK"
                responseHTML = """
                <html><body style="font-family:system-ui;text-align:center;padding:60px">
                <h2>&#9989; Spotify Connected</h2>
                <p>You can close this window and return to NeedleDrop.</p>
                </body></html>
                """
            } else {
                statusLine = "HTTP/1.1 400 Bad Request"
                responseHTML = """
                <html><body style="font-family:system-ui;text-align:center;padding:60px">
                <h2>&#10060; Authorization Failed</h2>
                <p>No authorization code received. Please try again.</p>
                </body></html>
                """
            }

            let httpResponse = """
            \(statusLine)\r
            Content-Type: text/html\r
            Content-Length: \(responseHTML.utf8.count)\r
            Connection: close\r
            \r
            \(responseHTML)
            """

            connection.send(content: httpResponse.data(using: .utf8), completion: .contentProcessed { _ in
                connection.cancel()
            })

            // Resume the continuation with the code (or error)
            if let code {
                self.continuation?.resume(returning: code)
            } else {
                self.continuation?.resume(throwing: CallbackError.noCodeReceived)
            }
            self.continuation = nil

            // Stop accepting new connections
            self.stop()
        }
    }

    private func extractCode(from request: String) -> String? {
        // Get the first line: "GET /callback?code=ABC&state=XYZ HTTP/1.1"
        guard let firstLine = request.split(separator: "\r\n").first ?? request.split(separator: "\n").first else {
            return nil
        }

        // Extract the path: "/callback?code=ABC&state=XYZ"
        let parts = firstLine.split(separator: " ")
        guard parts.count >= 2 else { return nil }
        let path = String(parts[1])

        // Parse query parameters
        guard let urlComponents = URLComponents(string: "http://localhost\(path)"),
              let queryItems = urlComponents.queryItems else {
            return nil
        }

        return queryItems.first(where: { $0.name == "code" })?.value
    }
}
