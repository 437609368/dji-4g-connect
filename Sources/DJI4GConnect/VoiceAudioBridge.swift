import AudioToolbox
import CoreAudio
import Foundation

/// Bridges the QDC507 USB audio pair to the Mac's default microphone and speaker.
/// The modem exposes an 8 kHz AC input and AS output; the Mac devices are often
/// 48 kHz, so the bridge performs a small linear resample in the audio callbacks.
final class VoiceAudioBridge {
    private final class FIFO {
        private var values: [Float]
        private var readIndex = 0
        private let lock = NSLock()

        init(capacity: Int) { values = []; values.reserveCapacity(capacity) }

        func reset() {
            lock.lock(); defer { lock.unlock() }
            values.removeAll(keepingCapacity: true)
            readIndex = 0
        }

        func append(_ source: UnsafePointer<Float>, count: Int) {
            guard count > 0 else { return }
            lock.lock(); defer { lock.unlock() }
            values.append(contentsOf: UnsafeBufferPointer(start: source, count: count))
            compactIfNeeded()
        }

        func readResampled(into destination: UnsafeMutablePointer<Float>, count: Int, sourceRate: Double, destinationRate: Double) {
            guard count > 0 else { return }
            lock.lock(); defer { lock.unlock() }
            let ratio = max(0.01, sourceRate / destinationRate)
            for index in 0..<count {
                let sourceIndex = Int(Double(index) * ratio)
                destination[index] = sourceIndex < values.count - readIndex ? values[readIndex + sourceIndex] : 0
            }
            let consumed = min(values.count - readIndex, Int(ceil(Double(count) * ratio)))
            readIndex += max(0, consumed)
            compactIfNeeded()
        }

        private func compactIfNeeded() {
            if readIndex > 4096 || readIndex > values.count / 2 {
                values.removeFirst(readIndex)
                readIndex = 0
            }
            if values.count > 96_000 {
                values.removeFirst(values.count - 48_000)
                readIndex = min(readIndex, values.count)
            }
        }
    }

    private var moduleInputUnit: AudioUnit?
    private var moduleOutputUnit: AudioUnit?
    private var hostInputUnit: AudioUnit?
    private var hostOutputUnit: AudioUnit?
    private let moduleToHost = FIFO(capacity: 16_000)
    private let hostToModule = FIFO(capacity: 96_000)
    private var moduleInputRate = 8_000.0
    private var moduleOutputRate = 8_000.0
    private var hostInputRate = 48_000.0
    private var hostOutputRate = 48_000.0
    private(set) var isRunning = false

    func start() -> String? {
        stop()

        guard let moduleInput = findDevice(names: ["AC Interface", "AC Interface"], input: true),
              let moduleOutput = findDevice(names: ["AS Interface", "AS Interface"], input: false),
              let hostInput = defaultDevice(input: true),
              let hostOutput = defaultDevice(input: false) else {
            return "未找到完整的 USB 音频输入/输出设备"
        }

        moduleInputRate = nominalRate(moduleInput)
        moduleOutputRate = nominalRate(moduleOutput)
        hostInputRate = nominalRate(hostInput)
        hostOutputRate = nominalRate(hostOutput)

        do {
            self.moduleInputUnit = try makeInputUnit(device: moduleInput, rate: moduleInputRate, callback: Self.moduleInputCallback)
            self.moduleOutputUnit = try makeOutputUnit(device: moduleOutput, rate: moduleOutputRate, callback: Self.moduleOutputCallback)
            self.hostInputUnit = try makeInputUnit(device: hostInput, rate: hostInputRate, callback: Self.hostInputCallback)
            self.hostOutputUnit = try makeOutputUnit(device: hostOutput, rate: hostOutputRate, callback: Self.hostOutputCallback)

            let units = [moduleInputUnit, moduleOutputUnit, hostInputUnit, hostOutputUnit].compactMap { $0 }
            for unit in units {
                let status = AudioUnitInitialize(unit)
                guard status == noErr else { throw AudioBridgeError(status: status, operation: "初始化音频设备") }
            }
            moduleToHost.reset()
            hostToModule.reset()
            for unit in units {
                let status = AudioOutputUnitStart(unit)
                guard status == noErr else { throw AudioBridgeError(status: status, operation: "启动音频设备") }
            }
            isRunning = true
            return nil
        } catch {
            stop()
            return error.localizedDescription
        }
    }

    func stop() {
        let units = [moduleInputUnit, moduleOutputUnit, hostInputUnit, hostOutputUnit].compactMap { $0 }
        for unit in units { AudioOutputUnitStop(unit) }
        for unit in units {
            AudioUnitUninitialize(unit)
            AudioComponentInstanceDispose(unit)
        }
        moduleInputUnit = nil
        moduleOutputUnit = nil
        hostInputUnit = nil
        hostOutputUnit = nil
        moduleToHost.reset()
        hostToModule.reset()
        isRunning = false
    }

    private enum AudioBridgeError: LocalizedError {
        case status(OSStatus, String)

        init(status: OSStatus, operation: String) { self = .status(status, operation) }

        var errorDescription: String? {
            switch self {
            case let .status(status, operation): return "\(operation)失败（\(status)）"
            }
        }
    }

    private func makeInputUnit(device: AudioDeviceID, rate: Double, callback: AURenderCallback) throws -> AudioUnit {
        let unit = try makeHALUnit(device: device, rate: rate, input: true)
        var callbackStruct = AURenderCallbackStruct(inputProc: callback, inputProcRefCon: Unmanaged.passUnretained(self).toOpaque())
        let status = AudioUnitSetProperty(unit, kAudioOutputUnitProperty_SetInputCallback, kAudioUnitScope_Global, 1, &callbackStruct, UInt32(MemoryLayout<AURenderCallbackStruct>.size))
        guard status == noErr else { throw AudioBridgeError(status: status, operation: "配置音频输入回调") }
        return unit
    }

    private func makeOutputUnit(device: AudioDeviceID, rate: Double, callback: AURenderCallback) throws -> AudioUnit {
        let unit = try makeHALUnit(device: device, rate: rate, input: false)
        var callbackStruct = AURenderCallbackStruct(inputProc: callback, inputProcRefCon: Unmanaged.passUnretained(self).toOpaque())
        let status = AudioUnitSetProperty(unit, kAudioUnitProperty_SetRenderCallback, kAudioUnitScope_Input, 0, &callbackStruct, UInt32(MemoryLayout<AURenderCallbackStruct>.size))
        guard status == noErr else { throw AudioBridgeError(status: status, operation: "配置音频输出回调") }
        return unit
    }

    private func makeHALUnit(device: AudioDeviceID, rate: Double, input: Bool) throws -> AudioUnit {
        var description = AudioComponentDescription(componentType: kAudioUnitType_Output,
                                                    componentSubType: kAudioUnitSubType_HALOutput,
                                                    componentManufacturer: kAudioUnitManufacturer_Apple,
                                                    componentFlags: 0,
                                                    componentFlagsMask: 0)
        guard let component = AudioComponentFindNext(nil, &description) else {
            throw AudioBridgeError(status: -1, operation: "查找 HAL 音频组件")
        }
        var unit: AudioUnit?
        var status = AudioComponentInstanceNew(component, &unit)
        guard status == noErr, let unit else { throw AudioBridgeError(status: status, operation: "创建 HAL 音频组件") }

        var enable: UInt32 = 1
        var disable: UInt32 = 0
        if input {
            status = AudioUnitSetProperty(unit, kAudioOutputUnitProperty_EnableIO, kAudioUnitScope_Input, 1, &enable, UInt32(MemoryLayout<UInt32>.size))
            status = status == noErr ? AudioUnitSetProperty(unit, kAudioOutputUnitProperty_EnableIO, kAudioUnitScope_Output, 0, &disable, UInt32(MemoryLayout<UInt32>.size)) : status
        } else {
            status = AudioUnitSetProperty(unit, kAudioOutputUnitProperty_EnableIO, kAudioUnitScope_Input, 1, &disable, UInt32(MemoryLayout<UInt32>.size))
            status = status == noErr ? AudioUnitSetProperty(unit, kAudioOutputUnitProperty_EnableIO, kAudioUnitScope_Output, 0, &enable, UInt32(MemoryLayout<UInt32>.size)) : status
        }
        guard status == noErr else {
            AudioComponentInstanceDispose(unit)
            throw AudioBridgeError(status: status, operation: "启用 HAL 音频方向")
        }

        var currentDevice = device
        status = AudioUnitSetProperty(unit, kAudioOutputUnitProperty_CurrentDevice, kAudioUnitScope_Global, 0, &currentDevice, UInt32(MemoryLayout<AudioDeviceID>.size))
        guard status == noErr else {
            AudioComponentInstanceDispose(unit)
            throw AudioBridgeError(status: status, operation: "选择音频设备")
        }

        var format = AudioStreamBasicDescription(mSampleRate: rate,
                                                  mFormatID: kAudioFormatLinearPCM,
                                                  mFormatFlags: kAudioFormatFlagsNativeFloatPacked,
                                                  mBytesPerPacket: 4,
                                                  mFramesPerPacket: 1,
                                                  mBytesPerFrame: 4,
                                                  mChannelsPerFrame: 1,
                                                  mBitsPerChannel: 32,
                                                  mReserved: 0)
        let scope: AudioUnitScope = input ? kAudioUnitScope_Output : kAudioUnitScope_Input
        let element: AudioUnitElement = input ? 1 : 0
        status = AudioUnitSetProperty(unit, kAudioUnitProperty_StreamFormat, scope, element, &format, UInt32(MemoryLayout<AudioStreamBasicDescription>.size))
        guard status == noErr else {
            AudioComponentInstanceDispose(unit)
            throw AudioBridgeError(status: status, operation: "设置音频格式")
        }
        return unit
    }

    private func findDevice(names: [String], input: Bool) -> AudioDeviceID? {
        allDevices().first { device in
            let name = deviceName(device)
            guard names.contains(where: { name.localizedCaseInsensitiveContains($0) }) else { return false }
            return channelCount(device, input: input) > 0
        }
    }

    private func defaultDevice(input: Bool) -> AudioDeviceID? {
        var address = AudioObjectPropertyAddress(mSelector: input ? kAudioHardwarePropertyDefaultInputDevice : kAudioHardwarePropertyDefaultOutputDevice,
                                                  mScope: kAudioObjectPropertyScopeGlobal,
                                                  mElement: kAudioObjectPropertyElementMain)
        var device = AudioDeviceID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &device) == noErr,
              device != kAudioObjectUnknown else { return nil }
        return device
    }

    private func allDevices() -> [AudioDeviceID] {
        var address = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDevices,
                                                  mScope: kAudioObjectPropertyScopeGlobal,
                                                  mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size) == noErr else { return [] }
        var devices = [AudioDeviceID](repeating: 0, count: Int(size) / MemoryLayout<AudioDeviceID>.size)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &devices) == noErr else { return [] }
        return devices
    }

    private func deviceName(_ device: AudioDeviceID) -> String {
        var address = AudioObjectPropertyAddress(mSelector: kAudioObjectPropertyName,
                                                  mScope: kAudioObjectPropertyScopeGlobal,
                                                  mElement: kAudioObjectPropertyElementMain)
        var name: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        guard AudioObjectGetPropertyData(device, &address, 0, nil, &size, &name) == noErr,
              let name else { return "" }
        return name.takeUnretainedValue() as String
    }

    private func nominalRate(_ device: AudioDeviceID) -> Double {
        var address = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyNominalSampleRate,
                                                  mScope: kAudioObjectPropertyScopeGlobal,
                                                  mElement: kAudioObjectPropertyElementMain)
        var rate = 48_000.0
        var size = UInt32(MemoryLayout<Double>.size)
        _ = AudioObjectGetPropertyData(device, &address, 0, nil, &size, &rate)
        return rate > 1_000 ? rate : 48_000
    }

    private func channelCount(_ device: AudioDeviceID, input: Bool) -> Int {
        var address = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyStreamConfiguration,
                                                  mScope: input ? kAudioDevicePropertyScopeInput : kAudioDevicePropertyScopeOutput,
                                                  mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(device, &address, 0, nil, &size) == noErr else { return 0 }
        let buffer = UnsafeMutablePointer<AudioBufferList>.allocate(capacity: Int(size))
        defer { buffer.deallocate() }
        guard AudioObjectGetPropertyData(device, &address, 0, nil, &size, buffer) == noErr else { return 0 }
        let buffers = UnsafeMutableAudioBufferListPointer(buffer)
        return buffers.reduce(0) { $0 + Int($1.mNumberChannels) }
    }

    private static let moduleInputCallback: AURenderCallback = { refCon, flags, timeStamp, bus, frames, data in
        return Unmanaged<VoiceAudioBridge>.fromOpaque(refCon).takeUnretainedValue().captureModule(flags, timeStamp, bus, frames)
    }

    private static let hostInputCallback: AURenderCallback = { refCon, flags, timeStamp, bus, frames, data in
        return Unmanaged<VoiceAudioBridge>.fromOpaque(refCon).takeUnretainedValue().captureHost(flags, timeStamp, bus, frames)
    }

    private static let moduleOutputCallback: AURenderCallback = { refCon, flags, timeStamp, bus, frames, data in
        guard let data else { return -1 }
        return Unmanaged<VoiceAudioBridge>.fromOpaque(refCon).takeUnretainedValue().renderModule(data, frames)
    }

    private static let hostOutputCallback: AURenderCallback = { refCon, flags, timeStamp, bus, frames, data in
        guard let data else { return -1 }
        return Unmanaged<VoiceAudioBridge>.fromOpaque(refCon).takeUnretainedValue().renderHost(data, frames)
    }

    private func captureModule(_ flags: UnsafeMutablePointer<AudioUnitRenderActionFlags>?, _ timeStamp: UnsafePointer<AudioTimeStamp>?, _ bus: UInt32, _ frames: UInt32) -> OSStatus {
        renderInput(unit: moduleInputUnit, flags: flags, timeStamp: timeStamp, bus: bus, frames: frames) { buffer in
            moduleToHost.append(buffer, count: Int(frames))
        }
    }

    private func captureHost(_ flags: UnsafeMutablePointer<AudioUnitRenderActionFlags>?, _ timeStamp: UnsafePointer<AudioTimeStamp>?, _ bus: UInt32, _ frames: UInt32) -> OSStatus {
        renderInput(unit: hostInputUnit, flags: flags, timeStamp: timeStamp, bus: bus, frames: frames) { buffer in
            hostToModule.append(buffer, count: Int(frames))
        }
    }

    private func renderInput(unit: AudioUnit?, flags: UnsafeMutablePointer<AudioUnitRenderActionFlags>?, timeStamp: UnsafePointer<AudioTimeStamp>?, bus: UInt32, frames: UInt32, consume: (UnsafePointer<Float>) -> Void) -> OSStatus {
        guard let unit, let timeStamp else { return -1 }
        let count = Int(frames)
        let raw = UnsafeMutablePointer<Float>.allocate(capacity: count)
        defer { raw.deallocate() }
        let buffer = AudioBuffer(mNumberChannels: 1, mDataByteSize: frames * 4, mData: raw)
        var list = AudioBufferList(mNumberBuffers: 1, mBuffers: buffer)
        let status = AudioUnitRender(unit, flags, timeStamp, bus, frames, &list)
        if status == noErr { consume(UnsafePointer(raw)) }
        return status
    }

    private func renderModule(_ data: UnsafeMutablePointer<AudioBufferList>, _ frames: UInt32) -> OSStatus {
        guard data.pointee.mNumberBuffers > 0, let target = data.pointee.mBuffers.mData?.assumingMemoryBound(to: Float.self) else { return noErr }
        hostToModule.readResampled(into: target, count: Int(frames), sourceRate: hostInputRate, destinationRate: moduleOutputRate)
        data.pointee.mBuffers.mDataByteSize = frames * 4
        return noErr
    }

    private func renderHost(_ data: UnsafeMutablePointer<AudioBufferList>, _ frames: UInt32) -> OSStatus {
        guard data.pointee.mNumberBuffers > 0, let target = data.pointee.mBuffers.mData?.assumingMemoryBound(to: Float.self) else { return noErr }
        moduleToHost.readResampled(into: target, count: Int(frames), sourceRate: moduleInputRate, destinationRate: hostOutputRate)
        data.pointee.mBuffers.mDataByteSize = frames * 4
        return noErr
    }

    deinit { stop() }
}
