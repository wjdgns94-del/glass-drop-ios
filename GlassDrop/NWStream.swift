import Foundation
import Network

/// TCP 연결 하나를 async/await로 쓰기 쉽게 감싼 것. 영상과 클립보드가 같이 써요.
final class NWStream {
    private let conn: NWConnection
    private let queue = DispatchQueue(label: "glassdrop.nwstream")

    init(host: String, port: UInt16) {
        let params = NWParameters.tcp
        if let tcp = params.defaultProtocolStack.transportProtocol as? NWProtocolTCP.Options {
            tcp.noDelay = true
        }
        conn = NWConnection(host: NWEndpoint.Host(host), port: NWEndpoint.Port(rawValue: port)!, using: params)
    }

    func open(timeout: TimeInterval) async throws {
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            var done = false
            conn.stateUpdateHandler = { [weak self] state in
                guard !done else { return }
                switch state {
                case .ready:
                    done = true
                    cont.resume()
                case .failed(let e):
                    done = true
                    cont.resume(throwing: e)
                case .cancelled:
                    done = true
                    cont.resume(throwing: AppError("연결이 취소됐어요."))
                case .waiting(let e):
                    // 네트워크가 막혀 있으면 waiting에 머물러요. 제한시간까지 기다려요.
                    _ = e
                    _ = self
                default:
                    break
                }
            }
            conn.start(queue: queue)
            queue.asyncAfter(deadline: .now() + timeout) { [weak self] in
                guard !done else { return }
                done = true
                self?.conn.cancel()
                cont.resume(throwing: AppError("노트북에 닿지 않아요. 같은 와이파이인지, 노트북 앱이 켜져 있는지 확인해 주세요."))
            }
        }
        conn.stateUpdateHandler = nil
    }

    func send(_ data: Data) async throws {
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            conn.send(content: data, completion: .contentProcessed { error in
                if let error = error { cont.resume(throwing: error) } else { cont.resume() }
            })
        }
    }

    /// 1바이트 이상 오면 돌려줘요. 상대가 닫으면 nil.
    func receiveSome(max: Int = 262_144) async throws -> Data? {
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Data?, Error>) in
            conn.receive(minimumIncompleteLength: 1, maximumLength: max) { data, _, isComplete, error in
                if let error = error {
                    cont.resume(throwing: error)
                } else if let data = data, !data.isEmpty {
                    cont.resume(returning: data)
                } else if isComplete {
                    cont.resume(returning: nil)
                } else {
                    cont.resume(returning: Data())
                }
            }
        }
    }

    func receiveExactly(_ n: Int) async throws -> Data {
        if n == 0 { return Data() }
        var out = Data()
        while out.count < n {
            guard let chunk = try await receiveSome(max: n - out.count) else {
                throw AppError("노트북이 연결을 닫았어요.")
            }
            out.append(chunk)
        }
        return out
    }

    func close() {
        conn.cancel()
    }
}
