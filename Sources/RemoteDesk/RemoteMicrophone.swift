import AudioToolbox
@preconcurrency import CoreBluetooth
import CoreAudio
import Observation
import os
import OSLog
import RemoteCore

struct ATVVNotificationSetup {
    enum Channel { case control, audio }
    private var awaiting: Channel? = .control

    mutating func confirm(_ channel: Channel) -> Bool {
        guard channel == awaiting else { return false }
        awaiting = channel == .control ? .audio : nil
        return true
    }
}

/// The RC003 microphone is a separate BLE service on the paired HID device.
@MainActor @Observable
final class RemoteMicrophone: NSObject, @preconcurrency CBCentralManagerDelegate,
    @preconcurrency CBPeripheralDelegate {
    struct Requirements {
        var bluetoothAuthorized: @MainActor () -> Bool
        var loopbackAvailable: @MainActor () -> Bool

        static var system: Self {
            Self(bluetoothAuthorized: { RemoteMicrophone.isBluetoothAuthorized },
                 loopbackAvailable: { BlackHoleDevice.currentID() != nil })
        }
    }

    private enum Phase { case stopped, connecting, negotiating, ready, opening, streaming }
    private struct TransferTrace {
        let started = ContinuousClock.now
        var packets = 0
        var lastPacket: Duration = .zero
        var queuedSamples = 0
        var lastSignal: Duration?
        var discardedBytes = 0
    }
    private static let service = CBUUID(string: "AB5E0001-5A21-4F05-BC7D-AF01F617B664")
    private static let txID = CBUUID(string: "AB5E0002-5A21-4F05-BC7D-AF01F617B664")
    private static let audioID = CBUUID(string: "AB5E0003-5A21-4F05-BC7D-AF01F617B664")
    private static let controlID = CBUUID(string: "AB5E0004-5A21-4F05-BC7D-AF01F617B664")
    private static let log = Logger(subsystem: "com.xahecktech.infinite-remote-desk", category: "RemoteMicrophone")
    private(set) var status: String? {
        didSet {
            if let status, oldValue != status { Self.log.notice("\(status, privacy: .public)") }
        }
    }
    private(set) var isForwardingAudio = false
    private var phase = Phase.stopped
    var isConnected: Bool { phase == .ready || phase == .opening || phase == .streaming }
    private var target: UUID?
    @ObservationIgnored private var reconnect: Task<Void, Never>?
    @ObservationIgnored private var reconnectDelay = 1
    @ObservationIgnored private var central: CBCentralManager?
    @ObservationIgnored private var permissionCentral: CBCentralManager?
    @ObservationIgnored private var peripheral: CBPeripheral?
    @ObservationIgnored private var tx: CBCharacteristic?
    @ObservationIgnored private var notificationSetup = ATVVNotificationSetup()
    @ObservationIgnored private var audioCharacteristic: CBCharacteristic?
    @ObservationIgnored private var timeout: Task<Void, Never>?
    @ObservationIgnored private var drain: Task<Void, Never>?
    @ObservationIgnored private var pendingStart: (command: [UInt8], deadline: ContinuousClock.Instant)?
    @ObservationIgnored private var pendingStartExpiry: Task<Void, Never>?
    @ObservationIgnored private var streamID: UInt8?
    @ObservationIgnored private var awaitingAudioForPress = false
    @ObservationIgnored private var forwardedSignal = false
    @ObservationIgnored private var transferTrace: TransferTrace?
    @ObservationIgnored private var frameLength = 120
    @ObservationIgnored private var decoder = ATVVAudio()
    @ObservationIgnored private var encoded = Data()
    @ObservationIgnored private var pcm: [Int16] = []
    @ObservationIgnored private var output: LoopbackOutput?
    @ObservationIgnored var canStream: () -> Bool = { false }
    @ObservationIgnored var onBluetoothAuthorizationChanged: () -> Void = {}

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
        if phase == .ready {
            awaitingAudioForPress = true
            status = L10n.tr("正在等待遥控器音频…")
        }
        guard let pending = pendingStart else { return }
        guard ContinuousClock.now < pending.deadline else {
            clearPendingStart(stopping: true)
            return
        }
        clearPendingStart()
        receiveControl(pending.command)
    }

    func voicePressDidEnd() {
        Self.log.notice("Physical microphone key released")
        clearPendingStart(stopping: true)
        if phase == .opening {
            cancelRecording()
            status = L10n.tr("未收到遥控器音频，请按住语音键说话。")
        } else if phase == .ready, awaitingAudioForPress {
            status = L10n.tr("未收到遥控器音频，请按住语音键说话。")
        }
        awaitingAudioForPress = false
        if phase == .streaming { setTimeout(.seconds(1)) }
    }

    func cancelRecording(reason: String = "interrupted") {
        clearPendingStart(stopping: true)
        drain?.cancel()
        let hadPress = awaitingAudioForPress
        if hadPress || phase == .opening || phase == .streaming {
            Self.log.notice("Remote microphone capture canceled")
        }
        awaitingAudioForPress = false
        if phase == .opening || phase == .streaming {
            write([0x0D, streamID ?? 0])
            logTransferEnd(reason)
            finish()
        } else if phase == .ready, hadPress {
            status = L10n.tr("遥控器收音已取消。")
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
        audioCharacteristic = nil
        notificationSetup = ATVVNotificationSetup()
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
            if CBCentralManager.authorization != .notDetermined {
                permissionCentral = nil
                onBluetoothAuthorizationChanged()
            }
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
              audio.properties.contains(.notify),
              let control = characteristics.first(where: { $0.uuid == Self.controlID }),
              control.properties.contains(.notify) else {
            disconnect(message: L10n.tr("遥控器语音服务不完整。"))
            return
        }
        self.tx = tx
        audioCharacteristic = audio
        // RC003 can complete negotiation but send silent audio when the audio
        // subscription is installed first. Wait for the control CCCD to succeed.
        peripheral.setNotifyValue(true, for: control)
    }

    func peripheral(_ peripheral: CBPeripheral, didUpdateNotificationStateFor characteristic: CBCharacteristic, error: Error?) {
        guard peripheral === self.peripheral else { return }
        guard error == nil, characteristic.isNotifying else {
            retryConnection(message: L10n.tr("无法订阅遥控器音频。"))
            return
        }
        guard phase == .connecting else { return }
        if characteristic.uuid == Self.controlID, notificationSetup.confirm(.control),
           let audioCharacteristic {
            Self.log.notice("ATVV control notifications enabled; subscribing to audio")
            peripheral.setNotifyValue(true, for: audioCharacteristic)
        } else if characteristic.uuid == Self.audioID, notificationSetup.confirm(.audio) {
            Self.log.notice("ATVV audio notifications enabled; negotiating audio format")
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
            guard bytes[2] == 2 else {
                write([0x0D, bytes[3]])
                finish(message: L10n.tr("遥控器音频格式不受支持。"))
                return
            }
            guard output.start() else {
                write([0x0D, bytes[3]])
                finish(message: L10n.tr("无法向 BlackHole 2ch 输出遥控器音频。"))
                return
            }
            self.output = output
            streamID = bytes[3]
            phase = .streaming
            decoder = ATVVAudio()
            transferTrace = TransferTrace()
            status = L10n.tr("正在等待遥控器音频…")
            Self.log.notice("ATVV stream opened; waiting for audio frames")
            setTimeout(.seconds(3))
        case 0x0A where phase == .streaming:
            if decoder.sync(bytes) {
                transferTrace?.discardedBytes += encoded.count
                encoded.removeAll(keepingCapacity: true)
            }
        case 0x00 where phase == .streaming || phase == .opening:
            guard flushAudio() else { return }
            logTransferEnd("remote close")
            finishTransfer()
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
        transferTrace?.packets += 1
        if let started = transferTrace?.started { transferTrace?.lastPacket = started.duration(to: .now) }
        encoded.append(data)
        while encoded.count >= frameLength {
            pcm += decoder.decode(encoded.prefix(frameLength))
            encoded.removeFirst(frameLength)
        }
        if pcm.count >= 960 { flushAudio() }
    }

    @discardableResult
    private func flushAudio() -> Bool {
        guard !pcm.isEmpty else { return true }
        let wrote = output?.write(pcm) == true
        if wrote {
            transferTrace?.queuedSamples += pcm.count
            if pcm.contains(where: { abs(Int($0)) >= 32 }) {
                if let started = transferTrace?.started { transferTrace?.lastSignal = started.duration(to: .now) }
                if !forwardedSignal {
                    forwardedSignal = true
                    Self.log.notice("Non-silent PCM from the remote was forwarded to BlackHole")
                }
            }
        }
        pcm.removeAll(keepingCapacity: true)
        guard wrote else {
            cancelRecording(reason: "loopback write failed")
            status = L10n.tr("无法向 BlackHole 2ch 输出遥控器音频。")
            return false
        }
        if !isForwardingAudio {
            isForwardingAudio = true
            status = L10n.tr("正在向 BlackHole 2ch 传送遥控器音频…")
            if awaitingAudioForPress { setTimeout(.seconds(60)) }
        }
        return true
    }

    private func finishTransfer() {
        let sent = isForwardingAudio
        finish(message: L10n.tr(sent
            ? "上次收音已传送到 BlackHole 2ch。"
            : "未收到遥控器音频，请按住语音键说话。"))
    }

    private func logTransferEnd(_ reason: String) {
        guard let trace = transferTrace else { return }
        let elapsed = trace.started.duration(to: .now)
        let lastSignal = trace.lastSignal.map { String(describing: $0) } ?? "none"
        let returned = output?.completedSamples ?? 0
        Self.log.notice("ATVV transfer ended (\(reason, privacy: .public)): elapsed=\(String(describing: elapsed), privacy: .public) keyHeld=\(self.canStream(), privacy: .public) packets=\(trace.packets, privacy: .public) lastPacket=\(String(describing: trace.lastPacket), privacy: .public) lastSignal=\(lastSignal, privacy: .public) queuedSamples=\(trace.queuedSamples, privacy: .public) returnedSamples=\(returned, privacy: .public) syncDiscardedBytes=\(trace.discardedBytes, privacy: .public)")
    }

    private func finish(message: String? = nil) {
        timeout?.cancel()
        streamID = nil
        awaitingAudioForPress = false
        isForwardingAudio = false
        forwardedSignal = false
        transferTrace = nil
        encoded.removeAll(keepingCapacity: true)
        pcm.removeAll(keepingCapacity: true)
        phase = .ready
        status = message ?? L10n.tr(BlackHoleDevice.currentID() == nil
            ? "麦克风已连接，但未检测到 BlackHole 2ch。"
            : "遥控器麦克风已就绪 · BlackHole 2ch")
    }

    private func setTimeout(_ duration: Duration) {
        timeout?.cancel()
        timeout = Task { [weak self] in
            try? await Task.sleep(for: duration)
            guard !Task.isCancelled, let self else { return }
            if phase == .streaming || phase == .opening {
                let sent = isForwardingAudio
                cancelRecording(reason: "stream timeout")
                status = L10n.tr(sent
                    ? "上次收音已传送到 BlackHole 2ch。"
                    : "未收到遥控器音频，请按住语音键说话。")
            }
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
    static let uid = "BlackHole2ch_UID"

    static func currentID() -> AudioDeviceID? {
        let deviceUID = uid as CFString
        var qualifier = Unmanaged.passUnretained(deviceUID).toOpaque()
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
    private struct BufferState {
        var pending: [Int16] = []
        var queuedByBuffer: [AudioQueueBufferRef: Int] = [:]
        var completedSamples = 0
        var stopped = false
        var enqueueFailed = false
    }

    private typealias BufferPool = OSAllocatedUnfairLock<BufferState>

    private final class Playback {
        let queue: AudioQueueRef
        let device: AudioDeviceID
        let buffers: BufferPool
        var initialBuffers: [AudioQueueBufferRef] = []
        var started = false

        init(queue: AudioQueueRef, device: AudioDeviceID, buffers: BufferPool) {
            self.queue = queue
            self.device = device
            self.buffers = buffers
        }

        deinit {
            buffers.withLockUnchecked { $0.stopped = true }
            AudioQueueDispose(queue, true)
        }
    }

    private var playback: Playback?
    private nonisolated static let bufferSamples = 320 // 20 ms at 16 kHz
    private static let maximumPendingSamples = 8_000
    private static let bufferCallbacks = DispatchQueue(label: "com.xahecktech.infinite-remote-desk.loopback-buffers")

    var completedSamples: Int {
        playback?.buffers.withLockUnchecked { $0.completedSamples } ?? 0
    }

    func start() -> Bool {
        stop()
        guard let device = BlackHoleDevice.currentID() else { return false }
        var format = AudioStreamBasicDescription(mSampleRate: 16_000, mFormatID: kAudioFormatLinearPCM,
            mFormatFlags: kLinearPCMFormatFlagIsSignedInteger | kLinearPCMFormatFlagIsPacked,
            mBytesPerPacket: 2, mFramesPerPacket: 1, mBytesPerFrame: 2,
            mChannelsPerFrame: 1, mBitsPerChannel: 16, mReserved: 0)
        let pool = BufferPool(uncheckedState: BufferState())
        var created: AudioQueueRef?
        // AudioQueueDispose can wait for buffer callbacks. Let them run even
        // when the main actor is closing the stream.
        let returnBuffer: @Sendable (AudioQueueRef, AudioQueueBufferRef) -> Void = { queue, buffer in
            pool.withLockUnchecked {
                $0.completedSamples += $0.queuedByBuffer.removeValue(forKey: buffer) ?? 0
            }
            Self.enqueue(buffer, on: queue, from: pool)
        }
        let result = AudioQueueNewOutputWithDispatchQueue(&created, &format, 0, Self.bufferCallbacks, returnBuffer)
        guard result == noErr, let queue = created else { return false }
        let session = Playback(queue: queue, device: device, buffers: pool)
        // Bind this queue before starting it so AVAudioEngine graph changes
        // and changes to the system's default output do not reroute the mic.
        let deviceUID = BlackHoleDevice.uid as CFString
        var uid = Unmanaged.passUnretained(deviceUID)
        let bindResult = withExtendedLifetime(deviceUID) {
            AudioQueueSetProperty(queue, kAudioQueueProperty_CurrentDevice, &uid, UInt32(MemoryLayout.size(ofValue: uid)))
        }
        guard bindResult == noErr else { return false }
        let bytes = UInt32(Self.bufferSamples * MemoryLayout<Int16>.stride)
        for _ in 0..<3 {
            var buffer: AudioQueueBufferRef?
            guard AudioQueueAllocateBuffer(queue, bytes, &buffer) == noErr, let buffer else { return false }
            session.initialBuffers.append(buffer)
        }
        playback = session
        return true
    }

    func write(_ pcm: [Int16]) -> Bool {
        guard let playback, BlackHoleDevice.currentID() == playback.device else { return false }
        let accepted = playback.buffers.withLockUnchecked { state in
            guard !state.enqueueFailed, state.pending.count + pcm.count <= Self.maximumPendingSamples else { return false }
            state.pending.append(contentsOf: pcm)
            return true
        }
        guard accepted else { return false }
        if !playback.started {
            for buffer in playback.initialBuffers {
                guard Self.enqueue(buffer, on: playback.queue, from: playback.buffers) else { return false }
            }
            playback.initialBuffers.removeAll()
            guard AudioQueueStart(playback.queue, nil) == noErr else { return false }
            playback.started = true
        }
        return true
    }

    @discardableResult
    private nonisolated static func enqueue(_ buffer: AudioQueueBufferRef, on queue: AudioQueueRef,
                                           from pool: BufferPool) -> Bool {
        let shouldEnqueue = pool.withLockUnchecked { state in
            guard !state.stopped, !state.enqueueFailed else { return false }
            let count = min(state.pending.count, bufferSamples)
            let sampleBytes = MemoryLayout<Int16>.stride
            let destination = UnsafeMutableRawBufferPointer(start: buffer.pointee.mAudioData,
                                                            count: bufferSamples * sampleBytes)
            // Keep the queue fed when BLE packets arrive late. An empty playback
            // queue can stay silent even after it accepts the next real buffer.
            destination.initializeMemory(as: UInt8.self, repeating: 0)
            if count > 0 {
                state.pending.withUnsafeBytes { source in
                    if let address = source.baseAddress {
                        buffer.pointee.mAudioData.copyMemory(from: address, byteCount: count * sampleBytes)
                    }
                }
            }
            state.pending.removeFirst(count)
            state.queuedByBuffer[buffer] = count
            buffer.pointee.mAudioDataByteSize = UInt32(destination.count)
            return true
        }
        guard shouldEnqueue else { return false }
        guard AudioQueueEnqueueBuffer(queue, buffer, 0, nil) == noErr else {
            pool.withLockUnchecked { $0.enqueueFailed = true }
            return false
        }
        return true
    }

    func stop() {
        playback = nil
    }
}
