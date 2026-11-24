import Foundation

/// 영상 TCP 연결 한 번. 열쇠(토큰 32글자)를 보내고, 오는 H.264를 풀어 화면에 올려요.
/// 끝나면(상대가 닫거나 오류) 반환하거나 던져요. 취소하면 조용히 끝나요.
final class VideoClient {
    private let address: VideoAddress
    private let surface: VideoSurface
    private var stream: NWStream?
    private(set) var fatalReason: String?

    init(address: VideoAddress, surface: VideoSurface) {
        self.address = address
        self.surface = surface
    }

    func stop() { stream?.close() }

    /// 영상 연결이 열려 열쇠까지 보냈을 때 불려요.
    func run(onConnected: @escaping () -> Void) async throws {
        let s = NWStream(host: address.host, port: address.port)
        stream = s
        try await s.open(timeout: 8)
        try await s.send(Data(address.token.lowercased().utf8))
        onConnected()

        let decoder = H264Decoder(surface: surface)
        decoder.onFatal = { [weak self] reason in
            self?.fatalReason = reason
            self?.stream?.close()
        }
        var parser = AnnexBParser()
        var accessUnit: [[UInt8]] = []
        defer { decoder.invalidate() }

        while !Task.isCancelled {
            guard let chunk = try await s.receiveSome() else { break }
            if chunk.isEmpty { continue }
            guard let nals = parser.feed(chunk) else {
                throw AppError("영상 데이터가 깨졌어요.")
            }
            for nal in nals {
                guard let first = nal.first else { continue }
                if first & 0x1F == 9 {
                    // AUD = 프레임 끝 표시. 연결 유지용 빈 AUD는 건너뛰어요.
                    if !accessUnit.isEmpty {
                        decoder.decode(accessUnit: accessUnit)
                        accessUnit.removeAll(keepingCapacity: true)
                    }
                } else {
                    accessUnit.append(nal)
                }
            }
        }
        if let reason = fatalReason { throw AppError(reason) }
    }
}
