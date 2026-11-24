import Foundation

/// 클립보드 TCP 채널(포트 61652). 한 연결에 요청 1개. 길이는 big-endian.
enum ClipClient {
    struct Reply {
        let status: UInt8
        let body: Data
    }

    static let maxText = 1 << 20
    static let maxImage = 32 << 20

    static func request(_ info: ClipChannelInfo, op: Character, body: Data = Data()) async throws -> Reply {
        let port = UInt16(clamping: info.port)
        let s = NWStream(host: info.host, port: port == 0 ? Identifiers.clipPort : port)
        defer { s.close() }
        try await s.open(timeout: 8)
        // 응답이 너무 늦으면 연결을 닫아 기다림을 끝내요.
        DispatchQueue.global().asyncAfter(deadline: .now() + 45) { s.close() }

        var out = Data(info.token.utf8)
        out.append(op.asciiValue ?? 0)
        var len = UInt32(body.count).bigEndian
        withUnsafeBytes(of: &len) { out.append(contentsOf: $0) }
        out.append(body)
        try await s.send(out)

        let header = try await s.receiveExactly(5)
        let status = header[header.startIndex]
        let length = header.suffix(4).reduce(0) { ($0 << 8) | Int($1) }
        guard length <= maxImage else { throw AppError("받을 데이터가 너무 커요.") }
        let payload = try await s.receiveExactly(length)
        return Reply(status: status, body: payload)
    }
}
