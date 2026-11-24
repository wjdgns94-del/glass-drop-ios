import Foundation

/// 컨테이너 없는 H.264(Annex-B, 시작 코드 00 00 01)를 NAL 단위로 자르는 도구.
/// 노트북은 프레임마다 NAL들 뒤에 AUD(00 00 00 01 09 F0)를 붙여요. AUD는 2바이트라 다음 시작 코드를 기다리지 않고 바로 완성으로 봐요.
struct AnnexBParser {
    private var buf: [UInt8] = []
    private var head = 0
    private static let maxBuffer = 32 * 1024 * 1024

    private func findStart(from: Int) -> Int? {
        var i = from
        let n = buf.count
        while i + 2 < n {
            if buf[i + 2] > 1 {
                i += 3
            } else if buf[i] == 0 && buf[i + 1] == 0 && buf[i + 2] == 1 {
                return i
            } else {
                i += 1
            }
        }
        return nil
    }

    /// 새로 온 바이트를 넣고, 다 완성된 NAL들을 돌려줘요. 너무 쌓이면 nil(깨진 영상).
    mutating func feed(_ data: Data) -> [[UInt8]]? {
        buf.append(contentsOf: data)
        var out: [[UInt8]] = []
        while true {
            guard let s0 = findStart(from: head) else {
                head = max(head, buf.count - 2)
                break
            }
            let p0 = s0 + 3
            if let s1 = findStart(from: p0) {
                var end = s1
                while end > p0 && buf[end - 1] == 0 { end -= 1 }
                if end > p0 { out.append(Array(buf[p0..<end])) }
                head = s1
                continue
            }
            if buf.count - p0 >= 2 && (buf[p0] & 0x1F) == 9 {
                out.append(Array(buf[p0..<(p0 + 2)]))
                head = p0 + 2
                continue
            }
            head = s0
            break
        }
        if head > 0 {
            buf.removeSubrange(0..<head)
            head = 0
        }
        if buf.count > AnnexBParser.maxBuffer { return nil }
        return out
    }
}
