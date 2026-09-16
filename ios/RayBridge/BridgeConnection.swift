import Foundation
import CryptoKit
import Security

// Trust is limited to the exact certificate fingerprint paired from the Mac.
final class CertificatePin: NSObject, URLSessionDelegate, @unchecked Sendable {
    let fingerprint: String
    init(fingerprint: String) { self.fingerprint = fingerprint }
    func urlSession(_ session: URLSession, didReceive challenge: URLAuthenticationChallenge,
                    completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
        guard challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust,
              let trust = challenge.protectionSpace.serverTrust,
              let certificates = SecTrustCopyCertificateChain(trust) as? [SecCertificate],
              let certificate = certificates.first else {
            completionHandler(.cancelAuthenticationChallenge, nil); return
        }
        let digest = SHA256.hash(data: SecCertificateCopyData(certificate) as Data)
            .map { String(format: "%02x", $0) }.joined()
        guard digest == fingerprint else { completionHandler(.cancelAuthenticationChallenge, nil); return }
        completionHandler(.useCredential, URLCredential(trust: trust))
    }
}

@MainActor
final class BridgeConnection {
    var onMessage: (([String: Any]) -> Void)?
    var onError: ((Error) -> Void)?
    private var session: URLSession?
    private var socket: URLSessionWebSocketTask?
    private var receiver: Task<Void, Never>?
    private var timeout: Task<Void, Never>?
    private var ready = false

    func connect(_ pairing: Pairing) {
        disconnect()
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 15
        config.waitsForConnectivity = false
        let session = URLSession(configuration: config, delegate: CertificatePin(fingerprint: pairing.fingerprint), delegateQueue: nil)
        self.session = session
        var request = URLRequest(url: pairing.url)
        request.setValue("Bearer \(pairing.token)", forHTTPHeaderField: "Authorization")
        let socket = session.webSocketTask(with: request)
        socket.maximumMessageSize = 1_000_000
        self.socket = socket
        socket.resume()
        timeout = Task { [weak self] in
            try? await Task.sleep(for: .seconds(15))
            guard !Task.isCancelled, let self, !self.ready else { return }
            self.disconnect()
            self.onError?(RecoverableSessionError(message: "The Mac did not answer. Check Wi-Fi and that RayBridge is open on your Mac."))
        }
        receiver = Task { [weak self] in
            do {
                while !Task.isCancelled {
                    let message = try await socket.receive()
                    guard !Task.isCancelled, self?.socket === socket else { return }
                    let data: Data
                    switch message { case .string(let text): data = Data(text.utf8)
                    case .data(let bytes): data = bytes
                    @unknown default: continue }
                    guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { continue }
                    if object["type"] as? String == "ready" { self?.ready = true; self?.timeout?.cancel() }
                    self?.onMessage?(object)
                }
            } catch {
                guard !Task.isCancelled else { return }
                self?.disconnect()
                let code = (error as? URLError)?.code
                if (socket.response as? HTTPURLResponse)?.statusCode == 503 {
                    self?.onError?(RecoverableSessionError(message: "The Mac bridge is temporarily unavailable."))
                    return
                }
                switch code {
                case .timedOut, .cannotFindHost, .cannotConnectToHost, .networkConnectionLost, .notConnectedToInternet:
                    self?.onError?(RecoverableSessionError(message: "Connection to your Mac was lost."))
                default:
                    self?.onError?(BridgeError.message("The Mac connection could not be established. Check the Mac app and your pairing in Setup."))
                }
            }
        }
    }
    func send(_ value: [String: Any]) async throws {
        guard let socket, ready else { throw BridgeError.message("Connect to your Mac first.") }
        let data = try JSONSerialization.data(withJSONObject: value)
        try await socket.send(.string(String(decoding: data, as: UTF8.self)))
    }
    func disconnect() {
        ready = false; timeout?.cancel(); receiver?.cancel(); socket?.cancel(with: .goingAway, reason: nil)
        session?.invalidateAndCancel(); session = nil; socket = nil
    }
}
