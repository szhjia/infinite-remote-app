import AudioToolbox
import AVFoundation
@preconcurrency import CoreBluetooth
import CoreAudio
import Observation
import RemoteCore

/// The RC003 microphone is a separate BLE service on the paired HID device.
@MainActor @Observable
final class RemoteMicrophone: NSObject, @preconcurrency CBCentralManagerDelegate,
    @preconcurrency CBPeripheralDelegate {
    private enum Phase { case stopped, connecting, negotiating, ready, opening, streaming }
    private static let service = CBUUID(string: "AB5E0001-5A21-4F05-BC7D-AF01F617B664")
    private static let txID = CBUUID(string: "AB5E0002-5A21-4F05-BC7D-AF01F617B664")
    private static let audioID = CBUUID(string: "AB5E0003-5A21-4F05-BC7D-AF01F617B664")
    private static let controlID = CBUUID(string: "AB5E0004-5A21-4F05-BC7D-AF01F617B664")
    private(set) var status: String?
    private var phase = Phase.stopped
    private var target: UUID?
    @ObservationIgnored private var reconnect: Task<Void, Never>?
    @ObservationIgnored private var reconnectDelay = 1
    @ObservationIgnored private var central: CBCentralManager?
    @ObservationIgnored private var permissionCentral: CBCentralManager?
    @ObservationIgnored private var peripheral: CBPeripheral?
    @ObservationIgnored private var tx: CBCharacteristic?
    @ObservationIgnored private var subscribed: Set<CBUUID> = []
    @ObservationIgnored private var timeout: Task<Void, Never>?
    @ObservationIgnored private var drain: Task<Void, Never>?
    @ObservationIgnored private var pendingStart: (command: [UInt8], deadline: ContinuousClock.Instant)?
    @ObservationIgnored private var pendingStartExpiry: Task<Void, Never>?
    @ObservationIgnored private var streamID: UInt8?
    @ObservationIgnored private var frameLength = 120
    @ObservationIgnored private var decoder = ATVVAudio()
    @ObservationIgnored private var encoded = Data()
    @ObservationIgnored private var pcm: [Int16] = []
    @ObservationIgnored private var output: LoopbackOutput?
    @ObservationIgnored var canStream: () -> Bool = { false }

    static var isBluetoothAuthorized: Bool { CBCentralManager.authorization == .allowedAlways }

    func requestBluetoothAuthorization() -> Bool {
        guard CBCentralManager.authorization == .notDetermined else { return false }
        if permissionCentral == nil {
            permissionCentral = CBCentralManager(delegate: self, queue: .main,
                                                 options: [CBCentralManagerOptionShowPowerAlertKey: false])
        }
        return true
    }

    func connect(_ identifier: UUID?, enabled: Bool) {
        let selected = enabled ? identifier : nil
        guard let selected else {
            if target != nil { disconnect() }
            target = nil
            status = enabled ? L10n.tr("无法确认所选遥控器的蓝牙身份。") : nil
            return
        }
        guard selected != target else { return }
        disconnect()
        target = selected
        reconnectDelay = 1
        startConnection()
    }

    private func startConnection() {
        status = L10n.tr("正在连接遥控器麦克风…")
        phase = .connecting
        central = CBCentralManager(delegate: self, queue: .main,
                                   options: [CBCentralManagerOptionShowPowerAlertKey: false])
    }

    func voicePressDidBegin() {
        guard let pending = pendingStart else { return }
        guard ContinuousClock.now < pending.deadline else {
            clearPendingStart(stopping: true)
            return
        }
        clearPendingStart()
        receiveControl(pending.command)
    }

    func voicePressDidEnd() {
        clearPendingStart(stopping: true)
        if phase == .opening { cancelRecording() }
        if phase == .streaming { setTimeout(.seconds(1)) }
    }

    func cancelRecording() {
        clearPendingStart(stopping: true)
        drain?.cancel()
        if phase == .opening || phase == .streaming {
            write([0x0D, streamID ?? 0])
            finish()
        }
        output?.stop()
    }

    private func disconnect(message: String? = nil, keepCentral: Bool = false) {
        reconnect?.cancel()
        reconnect = nil
        cancelRecording()
        timeout?.cancel()
        if let peripheral {
            peripheral.delegate = nil
            central?.cancelPeripheralConnection(peripheral)
        }
        if !keepCentral {
            central?.delegate = nil
            central = nil
        }
        peripheral = nil
        tx = nil
        subscribed.removeAll()
        phase = .stopped
        status = message
    }

    private func retryConnection(message: String) {
        disconnect(message: message)
        guard let target else { return }
        let delay = reconnectDelay
        reconnectDelay = min(delay * 2, 8)
        reconnect = Task { [weak self] in
            try? await Task.sleep(for: .seconds(delay))
            guard !Task.isCancelled, let self, self.target == target else { return }
            reconnect = nil
            startConnection()
        }
    }

    func centralManagerDidUpdateState(_ central: CBCentralManager) {
        if central === permissionCentral {
            if CBCentralManager.authorization != .notDetermined { permissionCentral = nil }
            return
        }
        guard central === self.central, let target else { return }
        switch central.state {
        case .poweredOn:
            guard peripheral == nil else { return }
            guard let match = central.retrievePeripherals(withIdentifiers: [target]).first(where: { $0.identifier == target }) else {
                retryConnection(message: L10n.tr("找不到所选遥控器的麦克风。"))
                return
            }
            phase = .connecting
            status = L10n.tr("正在连接遥控器麦克风…")
            peripheral = match
            match.delegate = self
            central.connect(match)
            setTimeout(.seconds(8))
        case .unauthorized:
            disconnect(message: L10n.tr("遥控器麦克风需要蓝牙权限。"), keepCentral: true)
        case .poweredOff, .unsupported, .resetting:
            disconnect(message: L10n.tr("蓝牙暂不可用。"), keepCentral: true)
        default: break
        }
    }

    func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        guard central === self.central, peripheral === self.peripheral else { return }
        peripheral.discoverServices([Self.service])
    }

    func centralManager(_ central: CBCentralManager, didFailToConnect peripheral: CBPeripheral, error: Error?) {
        if central === self.central, peripheral === self.peripheral {
            retryConnection(message: L10n.tr("遥控器麦克风连接失败。"))
        }
    }

    func centralManager(_ central: CBCentralManager, didDisconnectPeripheral peripheral: CBPeripheral, error: Error?) {
        if central === self.central, peripheral === self.peripheral {
            retryConnection(message: L10n.tr("遥控器麦克风已断开。"))
        }
    }

    func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        guard peripheral === self.peripheral else { return }
        guard error == nil else {
            retryConnection(message: L10n.tr("遥控器麦克风连接失败。"))
            return
        }
        guard let service = peripheral.services?.first(where: { $0.uuid == Self.service }) else {
            disconnect(message: L10n.tr("遥控器没有公开 ATVV 语音服务。"))
            return
        }
        peripheral.discoverCharacteristics([Self.txID, Self.audioID, Self.controlID], for: service)
    }

    func peripheral(_ peripheral: CBPeripheral, didDiscoverCharacteristicsFor service: CBService, error: Error?) {
        guard peripheral === self.peripheral else { return }
        guard error == nil else {
            retryConnection(message: L10n.tr("遥控器麦克风连接失败。"))
            return
        }
        let characteristics = service.characteristics ?? []
        guard let tx = characteristics.first(where: { $0.uuid == Self.txID }),
              tx.properties.contains(.write) || tx.properties.contains(.writeWithoutResponse),
              let audio = characteristics.first(where: { $0.uuid == Self.audioID }),
              let control = characteristics.first(where: { $0.uuid == Self.controlID }) else {
            disconnect(message: L10n.tr("遥控器语音服务不完整。"))
            return
        }
        self.tx = tx
        peripheral.setNotifyValue(true, for: audio)
        peripheral.setNotifyValue(true, for: control)
    }

    func peripheral(_ peripheral: CBPeripheral, didUpdateNotificationStateFor characteristic: CBCharacteristic, error: Error?) {
        guard peripheral === self.peripheral else { return }
        guard error == nil, characteristic.isNotifying else {
            retryConnection(message: L10n.tr("无法订阅遥控器音频。"))
            return
        }
        subscribed.insert(characteristic.uuid)
        if subscribed == [Self.audioID, Self.controlID], phase == .connecting {
            phase = .negotiating
            write([0x0A, 1, 0, 0, 3, 3])
        }
    }

    func peripheral(_ peripheral: CBPeripheral, didWriteValueFor characteristic: CBCharacteristic, error: Error?) {
        if peripheral === self.peripheral, error != nil {
            retryConnection(message: L10n.tr("遥控器语音命令发送失败。"))
        }
    }

    func peripheral(_ peripheral: CBPeripheral, didUpdateValueFor characteristic: CBCharacteristic, error: Error?) {
        guard peripheral === self.peripheral else { return }
        guard error == nil else {
            retryConnection(message: L10n.tr("无法读取遥控器音频。"))
            return
        }
        guard let data = characteristic.value, !data.isEmpty else { return }
        if characteristic.uuid == Self.controlID { receiveControl(Array(data)) }
        else if characteristic.uuid == Self.audioID, phase == .streaming { receiveAudio(data) }
    }

    private func receiveControl(_ bytes: [UInt8]) {
        switch bytes[0] {
        case 0x0B where phase == .negotiating:
            guard let length = ATVVAudio.frameLength(bytes) else {
                disconnect(message: L10n.tr("遥控器音频格式不受支持。"))
                return
            }
            frameLength = length
            reconnectDelay = 1
            finish()
        case 0x08 where phase == .ready:
            guard canStream() else {
                deferStart(bytes)
                return
            }
            phase = .opening
            write([0x0C, 0])
            setTimeout(.seconds(3))
        case 0x04 where (phase == .opening || phase == .ready) && bytes.count >= 4:
            guard canStream() else {
                if phase == .ready { deferStart(bytes) }
                else {
                    write([0x0D, bytes[3]])
                    finish()
                }
                return
            }
            drain?.cancel()
            let output = self.output ?? LoopbackOutput()
            guard bytes[2] == 2, output.start() else {
                write([0x0D, bytes[3]])
                finish()
                status = L10n.tr("无法向 BlackHole 2ch 输出遥控器音频。")
                return
            }
            self.output = output
            streamID = bytes[3]
            phase = .streaming
            decoder = ATVVAudio()
            status = L10n.tr("正在向 BlackHole 2ch 传送遥控器音频…")
            setTimeout(.seconds(60))
        case 0x0A where phase == .streaming:
            if decoder.sync(bytes) { encoded.removeAll(keepingCapacity: true) }
        case 0x00 where phase == .streaming || phase == .opening:
            flushAudio()
            finish()
            drain = Task { [weak self] in
                try? await Task.sleep(for: .seconds(1))
                if !Task.isCancelled { self?.output?.stop() }
            }
        case 0x00:
            clearPendingStart()
        default: break
        }
    }

    private func deferStart(_ command: [UInt8]) {
        // BLE can report the same button before IOHID. Hold only the control
        // packet for a short interval. Audio is accepted only after the HID press.
        if pendingStart != nil {
            if command[0] == 0x04 { pendingStart?.command = command }
            return
        }
        let deadline = ContinuousClock.now.advanced(by: .milliseconds(250))
        pendingStart = (command, deadline)
        pendingStartExpiry = Task { [weak self] in
            try? await Task.sleep(until: deadline, clock: .continuous)
            if !Task.isCancelled { self?.clearPendingStart(stopping: true) }
        }
    }

    private func clearPendingStart(stopping: Bool = false) {
        if stopping, let command = pendingStart?.command, command[0] == 0x04 { write([0x0D, command[3]]) }
        pendingStart = nil
        pendingStartExpiry?.cancel()
        pendingStartExpiry = nil
    }

    private func receiveAudio(_ data: Data) {
        encoded.append(data)
        while encoded.count >= frameLength {
            pcm += decoder.decode(encoded.prefix(frameLength))
            encoded.removeFirst(frameLength)
        }
        if pcm.count >= 960 { flushAudio() }
    }

    private func flushAudio() {
        guard !pcm.isEmpty else { return }
        let wrote = output?.write(pcm) == true
        pcm.removeAll(keepingCapacity: true)
        if !wrote {
            cancelRecording()
            status = L10n.tr("无法向 BlackHole 2ch 输出遥控器音频。")
        }
    }

    private func finish() {
        timeout?.cancel()
        streamID = nil
        encoded.removeAll(keepingCapacity: true)
        pcm.removeAll(keepingCapacity: true)
        phase = .ready
        status = L10n.tr("遥控器麦克风已就绪 · BlackHole 2ch")
    }

    private func setTimeout(_ duration: Duration) {
        timeout?.cancel()
        timeout = Task { [weak self] in
            try? await Task.sleep(for: duration)
            guard !Task.isCancelled, let self else { return }
            if phase == .streaming || phase == .opening { cancelRecording() }
            else { retryConnection(message: L10n.tr("遥控器麦克风连接超时。")) }
        }
    }

    private func write(_ bytes: [UInt8]) {
        guard let tx, let peripheral else { return }
        let type: CBCharacteristicWriteType = tx.properties.contains(.writeWithoutResponse) ? .withoutResponse : .withResponse
        peripheral.writeValue(Data(bytes), for: tx, type: type)
    }
}

enum BlackHoleDevice {
    static func currentID() -> AudioDeviceID? {
        let uid = "BlackHole2ch_UID" as CFString
        var qualifier = Unmanaged.passUnretained(uid).toOpaque()
        var address = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyTranslateUIDToDevice,
                                                 mScope: kAudioObjectPropertyScopeGlobal,
                                                 mElement: kAudioObjectPropertyElementMain)
        var device: AudioDeviceID = kAudioObjectUnknown
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address,
                                         UInt32(MemoryLayout.size(ofValue: qualifier)), &qualifier, &size, &device) == noErr,
              device != kAudioObjectUnknown else { return nil }
        return device
    }
}

/// Sends mono PCM to the specific loopback device without changing system defaults.
@MainActor
private final class LoopbackOutput {
    private let engine = AVAudioEngine()
    private let player = AVAudioPlayerNode()
    private let format = AVAudioFormat(standardFormatWithSampleRate: 16_000, channels: 1)!
    private var device: AudioDeviceID = kAudioObjectUnknown
    private var configured = false

    func start() -> Bool {
        stop()
        guard let id = BlackHoleDevice.currentID(), let unit = engine.outputNode.audioUnit else { return false }
        device = id
        let size = UInt32(MemoryLayout<AudioDeviceID>.size)
        guard AudioUnitSetProperty(unit, kAudioOutputUnitProperty_CurrentDevice, kAudioUnitScope_Global,
                                   0, &device, size) == noErr else { return false }
        if !configured {
            engine.attach(player)
            engine.connect(player, to: engine.mainMixerNode, format: format)
            configured = true
        }
        do {
            try engine.start()
            return true
        } catch {
            stop()
            return false
        }
    }

    func write(_ pcm: [Int16]) -> Bool {
        var current: AudioDeviceID = kAudioObjectUnknown
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        guard engine.isRunning, let unit = engine.outputNode.audioUnit,
              AudioUnitGetProperty(unit, kAudioOutputUnitProperty_CurrentDevice, kAudioUnitScope_Global,
                                   0, &current, &size) == noErr, current == device,
              let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(pcm.count)),
              let channel = buffer.floatChannelData?[0] else { return false }
        buffer.frameLength = AVAudioFrameCount(pcm.count)
        for (index, sample) in pcm.enumerated() { channel[index] = Float(sample) / 32768 }
        player.scheduleBuffer(buffer)
        if !player.isPlaying { player.play() }
        return true
    }

    func stop() {
        if configured { player.stop() }
        engine.stop()
    }
}
