import CoreBluetooth
import Foundation

/// 블루투스(CoreBluetooth)로 노트북을 찾고 값을 읽고 쓰는 담당. 모든 호출은 메인 스레드에서만 해요.
@MainActor
final class BLEClient: NSObject {
    var onState: ((CBManagerState) -> Void)?
    var onFound: (([FoundDevice]) -> Void)?
    var onNotify: ((CBUUID, Data) -> Void)?
    var onDisconnect: ((Error?) -> Void)?

    private var central: CBCentralManager!
    private var peripherals: [UUID: CBPeripheral] = [:]
    private var found: [UUID: FoundDevice] = [:]
    private var peripheral: CBPeripheral?
    private var characteristics: [CBUUID: CBCharacteristic] = [:]
    private var connectGeneration = 0

    private var connectCont: CheckedContinuation<Void, Error>?
    private var discoverCont: CheckedContinuation<Void, Error>?
    private var readConts: [CBUUID: CheckedContinuation<Data, Error>] = [:]
    private var writeConts: [CBUUID: CheckedContinuation<Void, Error>] = [:]
    private var notifyConts: [CBUUID: CheckedContinuation<Void, Error>] = [:]

    override init() {
        super.init()
        central = CBCentralManager(delegate: self, queue: .main)
    }

    var state: CBManagerState { central.state }
    var isConnected: Bool { peripheral?.state == .connected }

    // MARK: 찾기

    func startScan() {
        guard central.state == .poweredOn else { return }
        found.removeAll()
        onFound?([])
        central.scanForPeripherals(withServices: [Identifiers.service], options: nil)
    }

    func stopScan() {
        if central.isScanning { central.stopScan() }
    }

    // MARK: 연결

    func connect(_ id: UUID) async throws {
        guard let p = peripherals[id] else { throw AppError("노트북을 다시 찾아 주세요.") }
        stopScan()
        disconnect()
        peripheral = p
        p.delegate = self
        characteristics.removeAll()
        connectGeneration += 1
        let gen = connectGeneration

        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            connectCont = cont
            central.connect(p, options: nil)
            Task { @MainActor in
                try? await Task.sleep(nanoseconds: 15_000_000_000)
                if self.connectGeneration == gen, let c = self.connectCont {
                    self.connectCont = nil
                    self.central.cancelPeripheralConnection(p)
                    c.resume(throwing: AppError("노트북에 닿지 않아요. 블루투스가 켜져 있고 가까이 있는지 확인해 주세요."))
                }
            }
        }
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            discoverCont = cont
            p.discoverServices([Identifiers.service])
        }
    }

    func disconnect() {
        if let p = peripheral {
            central.cancelPeripheralConnection(p)
        }
        peripheral = nil
        characteristics.removeAll()
        failPending(AppError("연결을 끊었어요."))
    }

    private func failPending(_ error: Error) {
        let c1 = connectCont; connectCont = nil
        let c2 = discoverCont; discoverCont = nil
        let reads = readConts; readConts.removeAll()
        let writes = writeConts; writeConts.removeAll()
        let notifies = notifyConts; notifyConts.removeAll()
        c1?.resume(throwing: error)
        c2?.resume(throwing: error)
        reads.values.forEach { $0.resume(throwing: error) }
        writes.values.forEach { $0.resume(throwing: error) }
        notifies.values.forEach { $0.resume(throwing: error) }
    }

    // MARK: 읽기·쓰기

    func has(_ uuid: CBUUID) -> Bool { characteristics[uuid] != nil }

    func read(_ uuid: CBUUID) async throws -> Data {
        guard let p = peripheral, let c = characteristics[uuid] else {
            throw AppError("노트북과 블루투스로 연결되어 있지 않아요.")
        }
        guard readConts[uuid] == nil else { throw AppError("같은 항목을 이미 읽는 중이에요.") }
        return try await withCheckedThrowingContinuation { cont in
            readConts[uuid] = cont
            p.readValue(for: c)
        }
    }

    func write(_ uuid: CBUUID, _ data: Data) async throws {
        guard let p = peripheral, let c = characteristics[uuid] else {
            throw AppError("노트북과 블루투스로 연결되어 있지 않아요.")
        }
        guard writeConts[uuid] == nil else { throw AppError("같은 항목에 이미 쓰는 중이에요.") }
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            writeConts[uuid] = cont
            p.writeValue(data, for: c, type: .withResponse)
        }
    }

    /// 응답을 기다리지 않는 쓰기(안부 신호). 못 보내면 조용히 넘어가요.
    func writeNoResponse(_ uuid: CBUUID, _ data: Data) {
        guard let p = peripheral, let c = characteristics[uuid] else { return }
        if c.properties.contains(.writeWithoutResponse) {
            if p.canSendWriteWithoutResponse { p.writeValue(data, for: c, type: .withoutResponse) }
        } else if c.properties.contains(.write), writeConts[uuid] == nil {
            p.writeValue(data, for: c, type: .withResponse)
        }
    }

    func subscribe(_ uuid: CBUUID) async throws {
        guard let p = peripheral, let c = characteristics[uuid] else {
            throw AppError("알림 항목을 찾지 못했어요.")
        }
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            notifyConts[uuid] = cont
            p.setNotifyValue(true, for: c)
        }
    }

    // MARK: 델리게이트에서 넘어온 일 처리

    private func handleState(_ s: CBManagerState) { onState?(s) }

    private func handleDiscover(_ p: CBPeripheral, name: String?, rssi: Int) {
        peripherals[p.identifier] = p
        let shown = name ?? p.name ?? "노트북"
        found[p.identifier] = FoundDevice(id: p.identifier, name: shown, rssi: rssi)
        onFound?(found.values.sorted { $0.rssi > $1.rssi })
    }

    private func handleConnected() {
        let c = connectCont; connectCont = nil
        c?.resume()
    }

    private func handleFailedToConnect(_ error: Error?) {
        let c = connectCont; connectCont = nil
        c?.resume(throwing: error ?? AppError("노트북에 연결하지 못했어요."))
    }

    private func handleDisconnected(_ error: Error?) {
        peripheral = nil
        characteristics.removeAll()
        failPending(error ?? AppError("블루투스 연결이 끊겼어요."))
        onDisconnect?(error)
    }

    private func handleServices(_ p: CBPeripheral, _ error: Error?) {
        if let error = error {
            let c = discoverCont; discoverCont = nil
            c?.resume(throwing: error)
            return
        }
        guard let svc = p.services?.first(where: { $0.uuid == Identifiers.service }) else {
            let c = discoverCont; discoverCont = nil
            c?.resume(throwing: AppError("이 기기는 Glass Drop 노트북 앱이 아니에요."))
            return
        }
        p.discoverCharacteristics(nil, for: svc)
    }

    private func handleCharacteristics(_ service: CBService, _ error: Error?) {
        let c = discoverCont; discoverCont = nil
        if let error = error {
            c?.resume(throwing: error)
            return
        }
        for ch in service.characteristics ?? [] { characteristics[ch.uuid] = ch }
        c?.resume()
    }

    private func handleValue(_ uuid: CBUUID, _ value: Data?, _ error: Error?) {
        if let cont = readConts.removeValue(forKey: uuid) {
            if let error = error { cont.resume(throwing: error) } else { cont.resume(returning: value ?? Data()) }
            return
        }
        if error == nil, let value = value { onNotify?(uuid, value) }
    }

    private func handleWrite(_ uuid: CBUUID, _ error: Error?) {
        guard let cont = writeConts.removeValue(forKey: uuid) else { return }
        if let error = error { cont.resume(throwing: error) } else { cont.resume() }
    }

    private func handleNotifyState(_ uuid: CBUUID, _ error: Error?) {
        guard let cont = notifyConts.removeValue(forKey: uuid) else { return }
        if let error = error { cont.resume(throwing: error) } else { cont.resume() }
    }
}

extension BLEClient: CBCentralManagerDelegate {
    nonisolated func centralManagerDidUpdateState(_ central: CBCentralManager) {
        let s = central.state
        Task { @MainActor in self.handleState(s) }
    }

    nonisolated func centralManager(_ central: CBCentralManager, didDiscover peripheral: CBPeripheral,
                                    advertisementData: [String: Any], rssi RSSI: NSNumber) {
        let name = advertisementData[CBAdvertisementDataLocalNameKey] as? String
        let rssi = RSSI.intValue
        Task { @MainActor in self.handleDiscover(peripheral, name: name, rssi: rssi) }
    }

    nonisolated func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        Task { @MainActor in self.handleConnected() }
    }

    nonisolated func centralManager(_ central: CBCentralManager, didFailToConnect peripheral: CBPeripheral, error: Error?) {
        Task { @MainActor in self.handleFailedToConnect(error) }
    }

    nonisolated func centralManager(_ central: CBCentralManager, didDisconnectPeripheral peripheral: CBPeripheral, error: Error?) {
        Task { @MainActor in self.handleDisconnected(error) }
    }
}

extension BLEClient: CBPeripheralDelegate {
    nonisolated func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        Task { @MainActor in self.handleServices(peripheral, error) }
    }

    nonisolated func peripheral(_ peripheral: CBPeripheral, didDiscoverCharacteristicsFor service: CBService, error: Error?) {
        Task { @MainActor in self.handleCharacteristics(service, error) }
    }

    nonisolated func peripheral(_ peripheral: CBPeripheral, didUpdateValueFor characteristic: CBCharacteristic, error: Error?) {
        let uuid = characteristic.uuid
        let value = characteristic.value
        Task { @MainActor in self.handleValue(uuid, value, error) }
    }

    nonisolated func peripheral(_ peripheral: CBPeripheral, didWriteValueFor characteristic: CBCharacteristic, error: Error?) {
        let uuid = characteristic.uuid
        Task { @MainActor in self.handleWrite(uuid, error) }
    }

    nonisolated func peripheral(_ peripheral: CBPeripheral, didUpdateNotificationStateFor characteristic: CBCharacteristic, error: Error?) {
        let uuid = characteristic.uuid
        Task { @MainActor in self.handleNotifyState(uuid, error) }
    }
}
