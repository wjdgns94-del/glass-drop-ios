import CoreBluetooth

/// 노트북 앱과 반드시 같아야 하는 값. 출처: dumoni2/IDENTIFIERS.md (새 값만 사용)
enum Identifiers {
    static let service = CBUUID(string: "6505afe5-b438-41a3-b1fa-688162513e74")
    static let nameTag = CBUUID(string: "269074fb-d579-4b49-8a0e-3ccdf6cc80d0")
    static let hello = CBUUID(string: "36c37db8-5237-4238-b435-f622916f9cb5")
    static let videoAddress = CBUUID(string: "83564ce8-2c07-4c4a-8bdb-5bbab68b7594")
    static let clipboard = CBUUID(string: "c2b71205-c14a-4dca-be11-27395eaa72a2")
    static let clipboardChannel = CBUUID(string: "04e34802-87ba-4789-9134-265b56d5410d")
    static let clipboardNudge = CBUUID(string: "d3117c2a-c8b9-4382-a0fc-ada40d11f09a")
    static let pointerSide = CBUUID(string: "eada358f-5f29-4ecb-afd2-8f729581e2ea")
    static let sharing = CBUUID(string: "47f35e13-2673-4817-bb5e-dc5d1726fb82")
    static let awake = CBUUID(string: "d5c86418-0ee6-40c1-9f5c-3016916898ec")
    static let beacon = CBUUID(string: "0d3d833c-5046-491a-895a-f7c2283322bc")

    /// 이름표 특성이 돌려주는 글자. 현재 값은 glassdrop (PROTOCOL.md, 2026-11-24 이름 변경).
    /// 이름 바꾸기 전 빌드의 노트북 앱과 시험할 수 있게 임시 이름표도 받아 줘요.
    static let nameTagValue = "glassdrop"
    static let acceptedNameTags: Set<String> = [nameTagValue, "dumoni2"]

    static let videoPort: UInt16 = 51968
    static let clipPort: UInt16 = 61652
}
