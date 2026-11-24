import CoreBluetooth
import SwiftUI
import UIKit

/// 앱 전체의 상태와 흐름(찾기 → 페어링 → 화면 받기 → 클립보드·공유)을 맡는 곳.
@MainActor
final class SessionModel: ObservableObject {
    enum Phase { case idle, connecting, streaming }

    @Published var phase: Phase = .idle {
        didSet { UIApplication.shared.isIdleTimerDisabled = (phase == .streaming) }
    }
    @Published var status = "노트북을 찾는 중이에요…"
    @Published var errorText: String?
    @Published var devices: [FoundDevice] = []
    @Published var bluetoothNote: String?
    @Published var sharing = SharingState()
    @Published var pointerSide: PointerSide?
    @Published var hasFirstFrame = false
    @Published var showControls = true
    @Published var clipNote: String?
    @Published var bleLinked = false
    @Published var laptopName = ""

    let surface = VideoSurface()
    private let ble = BLEClient()
    private var connectTask: Task<Void, Never>?
    private var videoTask: Task<Void, Never>?
    private var awakeTask: Task<Void, Never>?
    private var currentVideo: VideoClient?
    private var lastAddress: VideoAddress?
    private var retries = 0
    private var appActive = true
    private var resumeAfterBackground = false

    init() {
        surface.onFirstFrame = { [weak self] in self?.firstFrameArrived() }
        ble.onState = { [weak self] state in self?.bluetoothStateChanged(state) }
        ble.onFound = { [weak self] list in self?.devices = list }
        ble.onNotify = { [weak self] uuid, data in self?.handleNotify(uuid, data) }
        ble.onDisconnect = { [weak self] _ in self?.bleDropped() }
    }

    // MARK: 찾기

    func startScan() {
        ble.startScan()
    }

    private func bluetoothStateChanged(_ state: CBManagerState) {
        switch state {
        case .poweredOn:
            bluetoothNote = nil
            if phase == .idle { ble.startScan() }
        case .poweredOff: bluetoothNote = "블루투스가 꺼져 있어요. 켜 주세요."
        case .unauthorized: bluetoothNote = "설정에서 Glass Drop의 블루투스를 허용해 주세요."
        case .unsupported: bluetoothNote = "이 기기는 블루투스를 지원하지 않아요."
        default: break
        }
    }

    // MARK: 연결 시작

    func connect(to id: UUID) {
        let shownName = devices.first(where: { $0.id == id })?.name ?? ""
        stopEverything()
        laptopName = shownName
        errorText = nil
        phase = .connecting
        connectTask = Task { await self.runBLEConnect(id) }
    }

    func connectManual(host: String, token: String) {
        guard let addr = VideoAddress.manual(host: host, token: token) else {
            errorText = "주소나 열쇠 모양이 맞지 않아요. 열쇠는 영문·숫자 32글자예요."
            return
        }
        stopEverything()
        errorText = nil
        lastAddress = addr
        bleLinked = false
        phase = .connecting
        status = "노트북 화면에 연결하는 중이에요…"
        retries = 0
        startVideo()
    }

    func disconnect() {
        stopEverything()
        phase = .idle
        errorText = nil
        ble.startScan()
    }

    private func stopEverything() {
        connectTask?.cancel(); connectTask = nil
        videoTask?.cancel(); videoTask = nil
        awakeTask?.cancel(); awakeTask = nil
        currentVideo?.stop(); currentVideo = nil
        ble.disconnect()
        ble.stopScan()
        bleLinked = false
        pointerSide = nil
        sharing = SharingState()
        hasFirstFrame = false
        clipNote = nil
        laptopName = ""
        resumeAfterBackground = false
    }

    private func fail(_ message: String) {
        stopEverything()
        errorText = message
        phase = .idle
        ble.startScan()
    }

    private func runBLEConnect(_ id: UUID) async {
        do {
            status = "노트북에 연결하는 중이에요…"
            try await ble.connect(id)
            bleLinked = true

            status = "노트북에 인사하는 중이에요…"
            try await sendHello()

            if let tag = try? await ble.read(Identifiers.nameTag) {
                let value = String(decoding: tag, as: UTF8.self)
                if !Identifiers.acceptedNameTags.contains(value) {
                    throw AppError("이 기기는 Glass Drop 노트북 앱이 아니에요.")
                }
            }
            for uuid in [Identifiers.sharing, Identifiers.pointerSide, Identifiers.clipboardNudge] {
                try? await ble.subscribe(uuid)
            }
            startAwakeLoop()
            retries = 0
            startVideo()
        } catch {
            if Task.isCancelled { return }
            fail(friendlyBLEMessage(error))
        }
    }

    private func sendHello() async throws {
        let idiom = UIDevice.current.userInterfaceIdiom
        let bounds = UIScreen.main.bounds
        let hello = PairingHello(device: UIDevice.current.name,
                                 kind: idiom == .phone ? "phone" : "pad",
                                 width: Int(bounds.width), height: Int(bounds.height),
                                 ip: localIPv4(), staleMap: false, pair: true, beacons: 1)
        let data = try JSONEncoder().encode(hello)
        var attempt = 0
        while true {
            do {
                try await ble.write(Identifiers.hello, data)
                return
            } catch {
                if isPairingInProgress(error), attempt < 40, !Task.isCancelled {
                    attempt += 1
                    status = "페어링 중이에요. 노트북과 이 기기에 뜬 숫자가 같으면 [페어링]을 눌러 주세요."
                    try await Task.sleep(nanoseconds: 1_500_000_000)
                    continue
                }
                throw error
            }
        }
    }

    private func startAwakeLoop() {
        awakeTask?.cancel()
        awakeTask = Task {
            while !Task.isCancelled {
                self.ble.writeNoResponse(Identifiers.awake, Data([self.appActive ? 1 : 0]))
                try? await Task.sleep(nanoseconds: 4_000_000_000)
            }
        }
    }

    // MARK: 영상

    private func startVideo() {
        videoTask?.cancel()
        videoTask = Task { await self.videoLoop() }
    }

    private func videoLoop() async {
        while !Task.isCancelled {
            do {
                let addr: VideoAddress
                if bleLinked && ble.isConnected {
                    status = "화면 주소를 받는 중이에요…"
                    let d = try await ble.read(Identifiers.videoAddress)
                    guard let a = VideoAddress.parse(String(decoding: d, as: UTF8.self)) else {
                        throw AppError("노트북이 보낸 화면 주소를 읽지 못했어요.")
                    }
                    addr = a
                } else if let a = lastAddress {
                    addr = a
                } else {
                    throw AppError("노트북 주소를 몰라요. 처음부터 다시 연결해 주세요.")
                }
                lastAddress = addr
                status = "노트북 화면에 연결하는 중이에요…"
                hasFirstFrame = false
                surface.reset()
                let client = VideoClient(address: addr, surface: surface)
                currentVideo = client
                try await client.run(onConnected: { [weak self] in
                    Task { @MainActor in self?.videoSocketOpened() }
                })
                if Task.isCancelled { return }
                throw AppError("노트북이 화면 전송을 멈췄어요.")
            } catch {
                if Task.isCancelled { return }
                let ns = error as NSError
                if ns.domain == "CBATTErrorDomain" && !isPairingInProgress(error) {
                    fail(friendlyBLEMessage(error))
                    return
                }
                retries += 1
                if retries > 3 {
                    let msg = (error as? AppError)?.text ?? "화면 연결이 끊겼어요."
                    fail(msg + " 같은 와이파이인지 확인하고 다시 연결해 주세요.")
                    return
                }
                phase = .connecting
                status = "연결이 끊겨서 다시 연결하는 중이에요… (\(retries)/3)"
                try? await Task.sleep(nanoseconds: 1_500_000_000)
            }
        }
    }

    private func videoSocketOpened() {
        phase = .streaming
        status = "노트북이 화면을 준비하고 있어요…"
        Task {
            try? await Task.sleep(nanoseconds: 12_000_000_000)
            if self.phase == .streaming && !self.hasFirstFrame {
                self.status = "화면이 오지 않아요. 노트북 앱이 켜져 있는지 확인해 주세요."
            }
        }
    }

    private func firstFrameArrived() {
        hasFirstFrame = true
        retries = 0
        status = ""
        Task {
            try? await Task.sleep(nanoseconds: 4_000_000_000)
            if self.hasFirstFrame { self.showControls = false }
        }
    }

    private func bleDropped() {
        guard bleLinked else { return }
        bleLinked = false
        awakeTask?.cancel(); awakeTask = nil
        if phase == .streaming {
            clipNote = "블루투스가 끊겼어요. 화면은 계속 나오지만 클립보드·공유는 쓸 수 없어요."
        }
    }

    // MARK: 앱이 앞/뒤로 갈 때

    func scenePhaseChanged(_ p: ScenePhase) {
        switch p {
        case .active:
            appActive = true
            if resumeAfterBackground {
                resumeAfterBackground = false
                phase = .connecting
                status = "다시 연결하는 중이에요…"
                retries = 0
                startVideo()
            }
        case .inactive:
            appActive = false
            ble.writeNoResponse(Identifiers.awake, Data([0]))
        case .background:
            appActive = false
            ble.writeNoResponse(Identifiers.awake, Data([0]))
            if phase != .idle && (videoTask != nil) {
                resumeAfterBackground = true
                videoTask?.cancel(); videoTask = nil
                currentVideo?.stop(); currentVideo = nil
            }
        @unknown default:
            break
        }
    }

    // MARK: 알림 (공유 상태, 포인터 위치, 클립보드 알림)

    private func handleNotify(_ uuid: CBUUID, _ data: Data) {
        if uuid == Identifiers.sharing, data.count >= 2 {
            sharing.mask = data[data.startIndex]
            sharing.sensitivity = data[data.startIndex + 1]
        } else if uuid == Identifiers.pointerSide, data.count >= 2 {
            pointerSide = PointerSide(onTablet: data[data.startIndex] != 0,
                                      tabletOnLeft: data[data.startIndex + 1] != 0)
        } else if uuid == Identifiers.clipboardNudge, let k = data.first {
            Task { await self.pullFromNudge(kind: Character(UnicodeScalar(k))) }
        }
    }

    // MARK: 공유 스위치

    func setShare(_ bit: UInt8, _ on: Bool) {
        sharing.set(bit, on)
        if bit == SharingState.mouse || bit == SharingState.keyboard {
            // 마우스·키보드는 한 묶음이에요.
            sharing.set(SharingState.mouse, on)
            sharing.set(SharingState.keyboard, on)
        }
        pushSharing()
    }

    func pushSharing() {
        guard bleLinked else { return }
        let s = sharing
        let payload = Data([s.mask, min(30, max(4, s.sensitivity)), s.windowsShortcuts ? 1 : 0])
        Task {
            do { try await self.ble.write(Identifiers.sharing, payload) }
            catch { self.clipNote = friendlyBLEMessage(error) }
        }
    }

    // MARK: 클립보드

    private func clipInfo() async throws -> ClipChannelInfo {
        guard bleLinked else { throw AppError("클립보드는 블루투스로 연결했을 때만 쓸 수 있어요.") }
        let d = try await ble.read(Identifiers.clipboardChannel)
        let info = try JSONDecoder().decode(ClipChannelInfo.self, from: d)
        let build = Int(Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "0") ?? 0
        if info.minApp > build { throw AppError("노트북 앱이 더 새 버전의 Glass Drop을 요구해요. 앱을 업데이트해 주세요.") }
        return info
    }

    /// 버튼: 노트북 클립보드를 이 기기로 가져와요.
    func pullClipboard() async {
        do {
            let info = try await clipInfo()
            let t = try await ClipClient.request(info, op: "X")
            if t.status == 0, !t.body.isEmpty {
                UIPasteboard.general.string = String(decoding: t.body, as: UTF8.self)
                clipNote = "노트북의 글을 가져왔어요."
                return
            }
            let g = try await ClipClient.request(info, op: "G")
            if g.status == 0, let img = UIImage(data: g.body) {
                UIPasteboard.general.image = img
                clipNote = "노트북의 그림을 가져왔어요."
            } else {
                clipNote = "노트북 클립보드가 비어 있어요."
            }
        } catch {
            clipNote = friendlyBLEMessage(error)
        }
    }

    /// 노트북이 "클립보드가 바뀌었어요" 하고 알려줄 때 자동으로 가져와요. t=짧은 글, L=긴 글, i=그림.
    private func pullFromNudge(kind: Character) async {
        guard sharing.has(SharingState.clipToTablet) else { return }
        do {
            switch kind {
            case "t":
                let d = try await ble.read(Identifiers.clipboard)
                if !d.isEmpty { UIPasteboard.general.string = String(decoding: d, as: UTF8.self) }
            case "L":
                let r = try await ClipClient.request(try await clipInfo(), op: "X")
                if r.status == 0 { UIPasteboard.general.string = String(decoding: r.body, as: UTF8.self) }
            case "i":
                let r = try await ClipClient.request(try await clipInfo(), op: "G")
                if r.status == 0, let img = UIImage(data: r.body) { UIPasteboard.general.image = img }
            default:
                return
            }
            clipNote = "노트북에서 클립보드가 넘어왔어요."
        } catch {
            clipNote = friendlyBLEMessage(error)
        }
    }

    /// 버튼: 이 기기의 클립보드를 노트북으로 보내요. (붙여넣기 허용 창이 뜰 수 있어요)
    func pushClipboard() async {
        do {
            let pb = UIPasteboard.general
            if let s = pb.string, !s.isEmpty {
                let bytes = Data(s.utf8)
                if bytes.count <= 512 {
                    guard bleLinked else { throw AppError("클립보드는 블루투스로 연결했을 때만 쓸 수 있어요.") }
                    try await ble.write(Identifiers.clipboard, bytes)
                } else {
                    guard bytes.count <= ClipClient.maxText else { throw AppError("글이 너무 길어요. (1MB까지)") }
                    let r = try await ClipClient.request(try await clipInfo(), op: "T", body: bytes)
                    try checkReply(r)
                }
                clipNote = "글을 노트북으로 보냈어요."
            } else if let img = pb.image {
                var data = img.pngData() ?? Data()
                if data.count > ClipClient.maxImage { data = img.jpegData(compressionQuality: 0.85) ?? Data() }
                guard !data.isEmpty, data.count <= ClipClient.maxImage else { throw AppError("그림이 너무 커요. (32MB까지)") }
                let r = try await ClipClient.request(try await clipInfo(), op: "P", body: data)
                try checkReply(r)
                clipNote = "그림을 노트북으로 보냈어요."
            } else {
                clipNote = "보낼 글이나 그림이 클립보드에 없어요."
            }
        } catch {
            clipNote = friendlyBLEMessage(error)
        }
    }

    private func checkReply(_ r: ClipClient.Reply) throws {
        switch r.status {
        case 0: return
        case 2: throw AppError("노트북이 열쇠를 받아 주지 않았어요. 다시 연결해 주세요.")
        default: throw AppError("노트북이 받지 못했어요. (비었거나 너무 커요)")
        }
    }
}
