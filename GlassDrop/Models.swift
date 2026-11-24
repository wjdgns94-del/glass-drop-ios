import Foundation
import Darwin

struct AppError: LocalizedError {
    let text: String
    init(_ text: String) { self.text = text }
    var errorDescription: String? { text }
}

struct PairingHello: Codable {
    var device: String
    var kind: String?
    var width: Int
    var height: Int
    var ip: String?
    var staleMap: Bool
    var pair: Bool
    var beacons: Int
}

struct ClipChannelInfo: Codable {
    let host: String
    let port: Int
    let token: String
    let ui: String?
    let agent: String
    let minApp: Int
}

struct VideoAddress: Equatable {
    var host: String
    var port: UInt16
    var token: String

    static func isToken(_ s: String) -> Bool {
        s.count == 32 && s.allSatisfy { $0.isHexDigit }
    }

    /// "IP:포트:열쇠" 글자를 읽어요.
    static func parse(_ raw: String) -> VideoAddress? {
        let parts = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            .split(separator: ":", omittingEmptySubsequences: false).map(String.init)
        guard parts.count == 3, let port = UInt16(parts[1]), isToken(parts[2]), !parts[0].isEmpty else { return nil }
        return VideoAddress(host: parts[0], port: port, token: parts[2])
    }

    /// 직접 입력: 주소 칸에 전체를 붙여 넣거나, 주소와 열쇠를 따로 넣어요.
    static func manual(host: String, token: String) -> VideoAddress? {
        let h = host.trimmingCharacters(in: .whitespacesAndNewlines)
        let t = token.trimmingCharacters(in: .whitespacesAndNewlines)
        if let full = parse(h) { return full }
        guard !h.isEmpty, isToken(t), !h.contains(":") else { return nil }
        return VideoAddress(host: h, port: Identifiers.videoPort, token: t)
    }
}

struct SharingState: Equatable {
    var mask: UInt8 = 0
    var sensitivity: UInt8 = 10
    var windowsShortcuts = false

    static let mouse: UInt8 = 1
    static let keyboard: UInt8 = 2
    static let clipToTablet: UInt8 = 4
    static let clipFromTablet: UInt8 = 8
    static let inputReady: UInt8 = 16

    func has(_ bit: UInt8) -> Bool { mask & bit != 0 }
    mutating func set(_ bit: UInt8, _ on: Bool) {
        if on { mask |= bit } else { mask &= ~bit }
    }
}

struct PointerSide: Equatable {
    var onTablet: Bool
    var tabletOnLeft: Bool
}

struct FoundDevice: Identifiable, Equatable {
    let id: UUID
    var name: String
    var rssi: Int
}

/// 노트북 앱이 돌려주는 오류 번호를 쉬운 말로 바꿔요.
func friendlyBLEMessage(_ error: Error) -> String {
    if let e = error as? AppError { return e.text }
    let ns = error as NSError
    if ns.domain == "CBATTErrorDomain" {
        switch ns.code {
        case 128: return "페어링 중이에요. 노트북과 이 기기에 뜬 숫자가 같은지 확인해 주세요."
        case 129: return "노트북에서 연결을 거절했어요. 잠시 뒤에 다시 눌러 주세요."
        case 130: return "노트북에서 연결 허용이 필요해요. [연결]을 다시 눌러 주세요."
        case 131: return "다른 기기가 이미 노트북 화면을 쓰고 있어요."
        case 132: return "노트북에 화면 드라이버가 설치되어 있지 않아요."
        case 133: return "노트북 방화벽이 막고 있어요."
        case 134: return "노트북이 배터리 절약 모드예요. 끄고 다시 해 주세요."
        case 17: return "노트북에 자리가 없어요. 동시에 2대까지만 연결돼요."
        case 5, 15: return "페어링이 필요해요. 화면에 뜨는 안내를 따라 주세요."
        default: break
        }
    }
    if ns.domain == "CBErrorDomain" {
        return "블루투스 연결이 끊겼거나 실패했어요. 노트북과 가까이에서 다시 해 주세요."
    }
    return "연결에 실패했어요. (\(ns.localizedDescription))"
}

func isPairingInProgress(_ error: Error) -> Bool {
    let ns = error as NSError
    guard ns.domain == "CBATTErrorDomain" else { return false }
    return [128, 5, 15].contains(ns.code)
}

func localIPv4() -> String? {
    var result: String?
    var ifaddr: UnsafeMutablePointer<ifaddrs>?
    guard getifaddrs(&ifaddr) == 0, let first = ifaddr else { return nil }
    defer { freeifaddrs(ifaddr) }
    var cursor: UnsafeMutablePointer<ifaddrs>? = first
    while let p = cursor {
        let ifa = p.pointee
        if let sa = ifa.ifa_addr, sa.pointee.sa_family == UInt8(AF_INET) {
            let name = String(cString: ifa.ifa_name)
            if name.hasPrefix("en") {
                var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
                if getnameinfo(sa, socklen_t(sa.pointee.sa_len), &host, socklen_t(host.count), nil, 0, NI_NUMERICHOST) == 0 {
                    result = String(cString: host)
                    break
                }
            }
        }
        cursor = ifa.ifa_next
    }
    return result
}
