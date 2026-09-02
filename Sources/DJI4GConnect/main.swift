import AppKit
import Combine
import Darwin
import Foundation
import LibUSBBridge
import SwiftUI

// MARK: - Hardware

enum ModemError: LocalizedError {
    case invalidAPN
    case noSerialPort
    case openFailed(String)
    case commandFailed(String)

    var errorDescription: String? {
        switch self {
        case .invalidAPN: return "APN 只能包含字母、数字、点、短横线和下划线。"
        case .noSerialPort: return "没有找到可用的 AT 通道。请确认模块已连接，并使用支持数据传输的 USB 线。"
        case .openFailed(let message): return "无法打开模块串口：\(message)"
        case .commandFailed(let message): return "模块没有接受指令：\(message)"
        }
    }
}

protocol ATChannel: AnyObject {
    func send(_ command: String, timeout: TimeInterval) throws -> String
    func sendSMS(to recipient: String, body: String) throws -> String
    func close()
}

final class SerialPort: ATChannel {
    let path: String
    private var fileDescriptor: Int32 = -1

    init(path: String) { self.path = path }

    func open() throws {
        fileDescriptor = Darwin.open(path, O_RDWR | O_NOCTTY | O_NONBLOCK)
        guard fileDescriptor >= 0 else {
            throw ModemError.openFailed(String(cString: strerror(errno)))
        }

        var options = termios()
        guard tcgetattr(fileDescriptor, &options) == 0 else { throw POSIXError(.init(rawValue: errno)!) }
        cfmakeraw(&options)
        cfsetspeed(&options, speed_t(B115200))
        options.c_cflag |= tcflag_t(CLOCAL | CREAD)
        guard tcsetattr(fileDescriptor, TCSANOW, &options) == 0 else {
            throw POSIXError(.init(rawValue: errno)!)
        }
    }

    func close() {
        guard fileDescriptor >= 0 else { return }
        Darwin.close(fileDescriptor)
        fileDescriptor = -1
    }

    @discardableResult
    func send(_ command: String, timeout: TimeInterval = 1.2) throws -> String {
        guard fileDescriptor >= 0 else { throw ModemError.openFailed("串口未打开") }
        try write(Array((command + "\r").utf8))
        return try readResponse(timeout: timeout)
    }

    func sendSMS(to recipient: String, body: String) throws -> String {
        _ = try send("AT+CMGF=1")
        _ = try send("AT+CSCS=\"UCS2\"")
        let encodedRecipient = Self.ucs2Hex(recipient)
        let encodedBody = Self.ucs2Hex(body)
        try write(Array(("AT+CMGS=\"\(encodedRecipient)\"\r").utf8))
        let prompt = try readResponse(timeout: 2, stopAtPrompt: true)
        guard prompt.contains(">") else { throw ModemError.commandFailed(prompt.isEmpty ? "未收到短信输入提示" : prompt) }
        try write(Array(encodedBody.utf8) + [26])
        return try readResponse(timeout: 8)
    }

    private static func ucs2Hex(_ value: String) -> String {
        value.utf16.map { String(format: "%04X", $0) }.joined()
    }

    private func write(_ bytes: [UInt8]) throws {
        let written = bytes.withUnsafeBytes { buffer in
            Darwin.write(fileDescriptor, buffer.baseAddress, buffer.count)
        }
        guard written == bytes.count else { throw POSIXError(.init(rawValue: errno)!) }
    }

    private func readResponse(timeout: TimeInterval, stopAtPrompt: Bool = false) throws -> String {
        var response = Data()
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            var descriptor = pollfd(fd: fileDescriptor, events: Int16(POLLIN), revents: 0)
            let ready = poll(&descriptor, 1, 120)
            if ready <= 0 { continue }

            var bytes = [UInt8](repeating: 0, count: 1024)
            let count = Darwin.read(fileDescriptor, &bytes, bytes.count)
            if count > 0 {
                response.append(contentsOf: bytes.prefix(count))
                if stopAtPrompt && response.contains(62) { break }
                if response.contains(where: { $0 == 10 }) &&
                    (response.range(of: Data("OK".utf8)) != nil || response.range(of: Data("ERROR".utf8)) != nil) {
                    break
                }
            }
        }
        return String(decoding: response, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    deinit { close() }
}

final class USBATPort: ATChannel {
    private let handle: OpaquePointer

    init() throws {
        guard let handle = dji_usb_at_create() else { throw ModemError.openFailed("无法分配 USB AT 通道") }
        var error = [CChar](repeating: 0, count: 256)
        let result = error.withUnsafeMutableBufferPointer {
            dji_usb_at_open(handle, $0.baseAddress, $0.count)
        }
        guard result == 0 else {
            let message = String(decoding: error.prefix(while: { $0 != 0 }).map { UInt8(bitPattern: $0) }, as: UTF8.self)
            dji_usb_at_destroy(handle)
            throw ModemError.openFailed(message.isEmpty ? "USB AT 接口不可用" : message)
        }
        self.handle = handle
    }

    func send(_ command: String, timeout: TimeInterval = 1.2) throws -> String {
        var response = [CChar](repeating: 0, count: 4096)
        let result = command.withCString { commandPointer in
            response.withUnsafeMutableBufferPointer {
                dji_usb_at_command(handle, commandPointer, $0.baseAddress, $0.count, UInt32(max(1, Int(timeout * 1000))))
            }
        }
        guard result == 0 else {
            let detail = String(cString: dji_usb_at_error(handle))
            throw ModemError.openFailed(detail)
        }
        return String(decoding: response.prefix(while: { $0 != 0 }).map { UInt8(bitPattern: $0) }, as: UTF8.self)
    }

    func sendSMS(to recipient: String, body: String) throws -> String {
        let recipientHex = Self.ucs2Hex(recipient)
        let bodyHex = Self.ucs2Hex(body)
        var response = [CChar](repeating: 0, count: 4096)
        let result = recipientHex.withCString { recipientPointer in
            bodyHex.withCString { bodyPointer in
                response.withUnsafeMutableBufferPointer {
                    dji_usb_at_send_sms(handle, recipientPointer, bodyPointer, $0.baseAddress, $0.count)
                }
            }
        }
        guard result == 0 else {
            let detail = String(cString: dji_usb_at_error(handle))
            throw ModemError.openFailed("USB AT 短信发送失败：\(detail)")
        }
        return String(decoding: response.prefix(while: { $0 != 0 }).map { UInt8(bitPattern: $0) }, as: UTF8.self)
    }

    func close() { dji_usb_at_close(handle) }

    deinit { dji_usb_at_destroy(handle) }

    private static func ucs2Hex(_ value: String) -> String {
        value.utf16.map { String(format: "%04X", $0) }.joined()
    }
}

enum PortScanner {
    static func allPorts() -> [String] {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: "/dev")) ?? []
        let prefixes = ["cu.usb", "cu.Baiwang", "cu.DJILTE", "cu.EG25", "cu.QDC", "cu.SLAB", "cu.wch", "tty.usb", "tty.Baiwang", "tty.DJILTE", "tty.EG25", "tty.QDC"]
        return names
            .filter { name in prefixes.contains(where: { name.hasPrefix($0) }) }
            .map { "/dev/\($0)" }
            .sorted()
    }
}

struct NetworkInterfaceInfo: Equatable {
    let device: String
    let label: String
    let address: String?
}

struct SMSMessage: Identifiable, Equatable {
    let id: Int
    let sender: String
    let date: String
    let body: String
}

enum CallOutcome: String, Codable {
    case dialing
    case connected
    case completed
    case failed
    case cancelled

    var title: String {
        switch self {
        case .dialing: return "呼叫中"
        case .connected: return "已接通"
        case .completed: return "已结束"
        case .failed: return "失败"
        case .cancelled: return "已取消"
        }
    }
}

struct CallRecord: Identifiable, Codable, Equatable {
    let id: UUID
    let number: String
    let startedAt: Date
    var endedAt: Date?
    var outcome: CallOutcome

    var duration: TimeInterval {
        max(0, (endedAt ?? Date()).timeIntervalSince(startedAt))
    }
}

enum SMSDirection: String, Codable {
    case incoming
    case outgoing

    var title: String {
        switch self {
        case .incoming: return "收到"
        case .outgoing: return "发送"
        }
    }
}

struct SMSHistoryRecord: Identifiable, Codable, Equatable {
    let id: String
    let direction: SMSDirection
    let number: String
    let body: String
    let date: Date
    let displayDate: String
}

enum CallState: Equatable {
    case idle
    case calling(String)
    case connected
    case failed(String)

    var title: String {
        switch self {
        case .idle: return "未通话"
        case .calling(let number): return "正在呼叫 \(number)"
        case .connected: return "通话中"
        case .failed(let reason): return "呼叫失败：\(reason)"
        }
    }
}

enum SystemNetwork {
    static func usbInterface() -> NetworkInterfaceInfo? {
        let output = run("/usr/sbin/networksetup", arguments: ["-listallhardwareports"])
        var label: String?
        var device: String?

        for line in output.split(separator: "\n", omittingEmptySubsequences: false) {
            let value = line.trimmingCharacters(in: .whitespaces)
            if value.hasPrefix("Hardware Port:") {
                label = value.replacingOccurrences(of: "Hardware Port:", with: "").trimmingCharacters(in: .whitespaces)
            } else if value.hasPrefix("Device:") {
                device = value.replacingOccurrences(of: "Device:", with: "").trimmingCharacters(in: .whitespaces)
                let searchable = (label ?? "").lowercased()
                if searchable.contains("usb") || searchable.contains("baiwang") || searchable.contains("dji") || searchable.contains("eg25") || searchable.contains("qdc") {
                    guard isNetworkServiceEnabled(label!) else { return nil }
                    return NetworkInterfaceInfo(device: device!, label: label!, address: address(for: device!))
                }
            }
        }
        return nil
    }

    static func address(for device: String) -> String? {
        let value = run("/usr/sbin/ipconfig", arguments: ["getifaddr", device]).trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty ? nil : value
    }

    @discardableResult
    static func renewDHCP(for device: String) -> Bool {
        let status = Process()
        status.executableURL = URL(fileURLWithPath: "/usr/sbin/ipconfig")
        status.arguments = ["set", device, "DHCP"]
        try? status.run()
        status.waitUntilExit()
        return status.terminationStatus == 0
    }

    @discardableResult
    static func renewDHCP(for device: String, service: String) -> Bool {
        let result = run("/usr/sbin/networksetup", arguments: ["-setdhcp", service])
        if !result.localizedCaseInsensitiveContains("error") {
            return true
        }
        return renewDHCP(for: device)
    }

    static func isNetworkServiceEnabled(_ service: String) -> Bool {
        let entries = run("/usr/sbin/networksetup", arguments: ["-listallnetworkservices"])
            .split(separator: "\n")
            .map { $0.trimmingCharacters(in: .whitespaces) }
        if let entry = entries.first(where: { $0 == service || $0 == "* \(service)" }) {
            return !entry.hasPrefix("* ")
        }
        return true
    }

    @discardableResult
    static func setUSBNetworkServicesEnabled(_ enabled: Bool) -> Bool {
        let services = networkServiceNames().filter { name in
            let searchable = name.lowercased()
            return searchable.contains("baiwang") || searchable.contains("dji") || searchable.contains("eg25") || searchable.contains("qdc")
        }
        guard !services.isEmpty else { return false }
        var success = true
        for service in services {
            let result = run("/usr/sbin/networksetup", arguments: ["-setnetworkserviceenabled", service, enabled ? "on" : "off"])
            if (!result.isEmpty && result.localizedCaseInsensitiveContains("error")) || isNetworkServiceEnabled(service) != enabled {
                success = false
            }
        }
        return success
    }

    private static func networkServiceNames() -> [String] {
        run("/usr/sbin/networksetup", arguments: ["-listallnetworkservices"])
            .split(separator: "\n")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty && !$0.hasPrefix("An asterisk") }
            .map { $0.hasPrefix("* ") ? String($0.dropFirst(2)) : $0 }
    }

    private static func run(_ executable: String, arguments: [String]) -> String {
        let process = Process()
        let pipe = Pipe()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.standardOutput = pipe
        process.standardError = Pipe()
        do {
            try process.run()
            process.waitUntilExit()
            return String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        } catch { return "" }
    }
}

// MARK: - State

enum ConnectionState: Equatable {
    case disconnected
    case connecting
    case connected
    case error

    var title: String {
        switch self {
        case .disconnected: return "未连接"
        case .connecting: return "正在连接"
        case .connected: return "已连接"
        case .error: return "需要处理"
        }
    }
}

@MainActor
final class ModemManager: ObservableObject {
    @Published var state: ConnectionState = .disconnected
    @Published var ports: [String] = []
    @Published var selectedPort = ""
    @Published var apn = UserDefaults.standard.string(forKey: "lastAPN") ?? ""
    @Published var enableECMSwitch = false
    @Published var operatorName = "等待模块"
    @Published var localNumber = "未读取"
    @Published var usbMode = "未读取"
    @Published var signalText = "—"
    @Published var network: NetworkInterfaceInfo?
    @Published var logs: [String] = []
    @Published var errorMessage = ""
    @Published var messages: [SMSMessage] = []
    @Published var smsHistory: [SMSHistoryRecord] = []
    @Published var callHistory: [CallRecord] = []
    @Published var callState: CallState = .idle
    @Published var voiceStatus = "未读取"
    @Published var isApplyingVoiceConfiguration = false

    private var channel: (any ATChannel)?
    private var refreshTimer: Timer?
    private var networkTimer: Timer?
    private var smsTimer: Timer?
    private var callTimer: Timer?
    private var manuallyDisconnected = false
    private var lastATAttempt: Date?
    private var callStartedAt: Date?
    private var activeCallRecordID: UUID?
    private var callEverConnected = false

    init() {
        loadHistory()
        if CommandLine.arguments.contains("--probe-at") { return }
        refreshDevices()
        refreshTimer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refreshDevices() }
        }
    }

    var isConnected: Bool { state == .connected }

    func refreshPorts() {
        refreshDevices()
    }

    private func refreshDevices() {
        ports = PortScanner.allPorts()
        if !ports.contains(selectedPort) { selectedPort = ports.first ?? "" }
        guard !manuallyDisconnected else {
            if SystemNetwork.usbInterface() == nil { manuallyDisconnected = false }
            return
        }

        if let found = SystemNetwork.usbInterface() {
            let changed = network != found
            network = found
            if channel == nil {
                operatorName = "需 AT 接口"
                usbMode = "ECM"
                if lastATAttempt == nil || Date().timeIntervalSince(lastATAttempt!) > 5 {
                    openATIfAvailable()
                }
            }
            if state == .disconnected || state == .error {
                state = .connected
                errorMessage = ""
                if changed { appendLog("发现已连接的 Baiwang USB 网卡：\(found.device)") }
                startNetworkPolling()
            }
        } else if state == .connected && channel == nil {
            state = .disconnected
            network = nil
            networkTimer?.invalidate()
            networkTimer = nil
            appendLog("Baiwang USB 网卡已移除")
        }
    }

    func connect() {
        manuallyDisconnected = false
        state = .connecting
        errorMessage = ""
        appendLog("开始连接模块")
        do {
            if SystemNetwork.setUSBNetworkServicesEnabled(true) {
                appendLog("已启用 Baiwang USB 网络服务")
            }
            if channel == nil {
                if !selectedPort.isEmpty {
                    let serial = SerialPort(path: selectedPort)
                    try serial.open()
                    channel = serial
                    appendLog("使用 AT 串口：\(selectedPort)")
                } else {
                    channel = try USBATPort()
                    appendLog("使用模块原生 USB AT 接口")
                }
            }
            guard channel != nil else { throw ModemError.noSerialPort }

            let identity = try command("ATI")
            appendLog(identity.isEmpty ? "模块已响应" : "模块：\(firstMeaningfulLine(identity))")
            let mode = try command("AT+QCFG=\"usbnet\"")
            usbMode = mode.contains(",1") ? "ECM" : firstMeaningfulLine(mode)
            let effectiveAPN = automaticAPN()
            if let effectiveAPN {
                _ = try command("AT+CGDCONT=1,\"IP\",\"\(effectiveAPN)\"")
                appendLog("已自动配置 APN：\(effectiveAPN)")
            } else {
                appendLog("未识别到默认 APN，保留模块现有配置")
            }
            _ = try command("AT+CGATT=1", timeout: 8)
            _ = try command("AT+CGACT=1,1", timeout: 15)
            if !mode.contains(",1") && enableECMSwitch {
                appendLog("正在切换 macOS 兼容模式 ECM；模块会重启一次")
                _ = try command("AT+QCFG=\"usbnet\",1")
                _ = try command("AT+CFUN=1,1", timeout: 2)
                channel?.close()
                channel = nil
                appendLog("模块正在重新枚举，请等待 USB 网卡出现")
            } else {
                _ = try command("AT+CFUN=1")
                readModuleStatus()
            }

            if let interfaceInfo = waitForNetworkInterface() {
                network = interfaceInfo
                _ = SystemNetwork.renewDHCP(for: interfaceInfo.device, service: interfaceInfo.label)
                var ready = waitForNetworkAddress(interfaceInfo)
                if ready == nil {
                    appendLog("DHCP 未获取地址，正在重启模块并重新枚举 USB 网卡")
                    ready = try? restartAndActivateData(apn: effectiveAPN)
                }
                if let ready {
                    network = ready
                    appendLog("USB 网卡 \(interfaceInfo.device) 已获取地址 \(ready.address ?? "")")
                } else {
                    appendLog("USB 网卡 \(interfaceInfo.device) 已发现，但 DHCP 尚未获取地址")
                }
            } else {
                appendLog("模块已配置，等待 macOS 创建 USB 网卡")
            }
            state = .connected
            startNetworkPolling()
            appendLog("连接成功，可以开始使用 4G 网络")
        } catch {
            channel?.close()
            channel = nil
            fail(error.localizedDescription)
        }
    }

    func disconnect() {
        manuallyDisconnected = true
        networkTimer?.invalidate()
        networkTimer = nil
        smsTimer?.invalidate()
        smsTimer = nil
        callTimer?.invalidate()
        callTimer = nil
        if let channel {
            _ = try? channel.send("AT+CGACT=0,1", timeout: 0.5)
            channel.close()
        }
        self.channel = nil
        network = nil
        state = .disconnected
        if activeCallRecordID != nil {
            finishActiveCall(outcome: .cancelled)
        }
        callState = .idle
        appendLog("已断开 Baiwang 4G 数据连接")
        appendLog("已保留 Baiwang 网络服务，方便下次直接重连；Wi-Fi 等其他网络不会受影响")
    }

    func clearLogs() { logs.removeAll() }

    func startSMSAutoRefresh() {
        smsTimer?.invalidate()
        smsTimer = nil
        loadMessages(silent: true)
        smsTimer = Timer.scheduledTimer(withTimeInterval: 12, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.loadMessages(silent: true) }
        }
    }

    func stopSMSAutoRefresh() {
        smsTimer?.invalidate()
        smsTimer = nil
    }

    private func openATIfAvailable() {
        lastATAttempt = Date()
        var serialError: String?
        do {
            if !selectedPort.isEmpty {
                let serial = SerialPort(path: selectedPort)
                try serial.open()
                let probe = try serial.send("AT")
                guard probe.uppercased().contains("OK") else {
                    throw ModemError.commandFailed("串口没有返回 OK")
                }
                channel = serial
                appendLog("已打开 AT 串口：\(selectedPort)")
            } else {
                channel = try USBATPort()
                appendLog("已通过 USB 直连打开 AT 接口")
            }
            readModuleStatus()
            return
        } catch {
            serialError = error.localizedDescription
            channel?.close()
            channel = nil
        }

        // ECM 模式通常不会创建 /dev/cu.*；即使系统没有串口，也尝试
        // 通过模块的 USB bulk AT 接口读取 COPS/CSQ、短信和电话状态。
        do {
            channel = try USBATPort()
            appendLog("已通过 USB 直连打开 AT 接口")
            readModuleStatus()
        } catch {
            operatorName = "需 AT 接口"
            let detail = serialError.map { "串口：\($0)；USB：\(error.localizedDescription)" } ?? error.localizedDescription
            appendLog("AT 接口暂不可用：\(detail)")
        }
    }

    func loadMessages(silent: Bool = false) {
        guard let channel else {
            if !silent { fail("读取短信需要 AT 接口；当前 USB AT 通道不可用。") }
            return
        }
        do {
            _ = try command("AT+CMGF=1")
            _ = try command("AT+CSCS=\"UCS2\"")
            let response = try channel.send("AT+CMGL=\"ALL\"", timeout: 4)
            messages = parseMessages(response)
            upsertIncomingMessages(messages)
            if !silent { appendLog("已读取 \(messages.count) 条短信") }
        } catch {
            if !silent { fail(error.localizedDescription) }
        }
    }

    func sendMessage(to recipient: String, body: String) {
        let number = recipient.trimmingCharacters(in: .whitespacesAndNewlines)
        guard number.range(of: "^[+0-9*#()-]+$", options: .regularExpression) != nil else { fail("请输入有效的手机号码"); return }
        guard !body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { fail("短信内容不能为空"); return }
        guard let channel else { fail("发送短信需要 AT 接口；当前 USB AT 通道不可用。"); return }
        do {
            appendLog("发送短信至 \(number)")
            let response = try channel.sendSMS(to: number, body: body)
            guard !response.uppercased().contains("ERROR") else { throw ModemError.commandFailed(response) }
            addOutgoingMessage(number: number, body: body)
            appendLog("短信发送成功")
        } catch { fail(error.localizedDescription) }
    }

    func dial(_ number: String) {
        let value = number.trimmingCharacters(in: .whitespacesAndNewlines)
        guard value.range(of: "^[+0-9*#()-]+$", options: .regularExpression) != nil else { fail("请输入有效的电话号码"); return }
        guard channel != nil else { fail("拨打电话需要 AT 接口；当前 USB AT 通道不可用。"); return }
        do {
            _ = try? command("AT+CLIP=1")
            _ = try? command("AT+COLP=1")
            _ = try? command("AT+QINDCFG=\"ccinfo\",1")
            _ = try? command("AT+QINDCFG=\"all\",1")
            _ = try command("ATD\(value);")
            callState = .calling(value)
            callEverConnected = false
            callStartedAt = Date()
            startCallRecord(number: value)
            appendLog("正在呼叫 \(value)")
            startCallPolling()
        } catch { fail(error.localizedDescription) }
    }

    func hangUp() {
        guard channel != nil else { callState = .idle; return }
        do {
            _ = try command("ATH")
            finishActiveCall(outcome: callEverConnected || callState == .connected ? .completed : .cancelled)
            callState = .idle
            callTimer?.invalidate()
            callTimer = nil
            callStartedAt = nil
            appendLog("通话已结束")
        } catch { fail(error.localizedDescription) }
    }

    func clearCallHistory() {
        callHistory.removeAll()
        saveHistory()
    }

    func clearSMSHistory() {
        smsHistory.removeAll()
        saveHistory()
    }

    private func loadHistory() {
        let decoder = JSONDecoder()
        if let data = UserDefaults.standard.data(forKey: "callHistory"),
           let records = try? decoder.decode([CallRecord].self, from: data) {
            callHistory = records.sorted { $0.startedAt > $1.startedAt }
        }
        if let data = UserDefaults.standard.data(forKey: "smsHistory"),
           let records = try? decoder.decode([SMSHistoryRecord].self, from: data) {
            smsHistory = records.sorted { $0.date > $1.date }
        }
    }

    private func saveHistory() {
        let encoder = JSONEncoder()
        if let data = try? encoder.encode(Array(callHistory.prefix(200))) {
            UserDefaults.standard.set(data, forKey: "callHistory")
        }
        if let data = try? encoder.encode(Array(smsHistory.prefix(500))) {
            UserDefaults.standard.set(data, forKey: "smsHistory")
        }
    }

    private func startCallRecord(number: String) {
        let record = CallRecord(id: UUID(), number: number, startedAt: Date(), endedAt: nil, outcome: .dialing)
        activeCallRecordID = record.id
        callHistory.insert(record, at: 0)
        saveHistory()
    }

    private func finishActiveCall(outcome: CallOutcome) {
        guard let id = activeCallRecordID, let index = callHistory.firstIndex(where: { $0.id == id }) else { return }
        callHistory[index].endedAt = Date()
        callHistory[index].outcome = outcome
        activeCallRecordID = nil
        saveHistory()
    }

    private func markCallConnected() {
        guard let id = activeCallRecordID, let index = callHistory.firstIndex(where: { $0.id == id }) else { return }
        callHistory[index].outcome = .connected
        saveHistory()
    }

    private func upsertIncomingMessages(_ incoming: [SMSMessage]) {
        for message in incoming {
            let id = "in-\(message.id)"
            let record = SMSHistoryRecord(id: id, direction: .incoming, number: message.sender, body: message.body, date: Date(), displayDate: message.date)
            if let index = smsHistory.firstIndex(where: { $0.id == id }) {
                smsHistory[index] = record
            } else {
                smsHistory.append(record)
            }
        }
        smsHistory.sort { $0.date > $1.date }
        saveHistory()
    }

    private func addOutgoingMessage(number: String, body: String) {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd HH:mm"
        let record = SMSHistoryRecord(id: "out-\(UUID().uuidString)", direction: .outgoing, number: number, body: body, date: Date(), displayDate: formatter.string(from: Date()))
        smsHistory.insert(record, at: 0)
        saveHistory()
    }

    private func command(_ text: String, timeout: TimeInterval = 1.2) throws -> String {
        appendLog("> \(text)")
        let result = try channel?.send(text, timeout: timeout) ?? ""
        if result.uppercased().contains("ERROR") { throw ModemError.commandFailed(result) }
        let visible = result.replacingOccurrences(of: "\r", with: "").replacingOccurrences(of: "\n", with: " ")
        if !visible.isEmpty { appendLog(visible) }
        return result
    }

    private func readModuleStatus() {
        if let signal = try? command("AT+CSQ"), let match = signal.range(of: #"\+CSQ:\s*(\d+)"#, options: .regularExpression) {
            let value = signal[match].split(separator: ":").last?.trimmingCharacters(in: .whitespaces).split(separator: ",").first ?? "—"
            signalText = value == "99" ? "未知" : "\(value) / 31"
        }
        if let cops = try? command("AT+COPS?") {
            let name = cops.split(separator: "\"").dropFirst().first.map(String.init)
            if let name, !name.isEmpty, !name.contains("?") {
                operatorName = operatorLabel(name)
            } else if cops.contains("+COPS: 0") {
                operatorName = "未注册"
            } else {
                operatorName = "读取中"
            }

            // Some QDC507 firmware returns the localized operator name as
            // question marks. Ask for MCC/MNC instead, then restore the
            // human-readable format for other modem clients.
            if name == nil || name?.contains("?") == true {
                _ = try? command("AT+COPS=3,2")
                if let numeric = try? command("AT+COPS?"),
                   let code = numeric.split(separator: "\"").dropFirst().first.map(String.init) {
                    operatorName = operatorLabel(code)
                }
                _ = try? command("AT+COPS=3,0")
            }
        }
        localNumber = readLocalNumber()
        readVoiceStatus()
    }

    private func readLocalNumber() -> String {
        guard let response = try? command("AT+CNUM") else { return "读取失败" }
        for line in response.replacingOccurrences(of: "\r", with: "").split(separator: "\n") {
            let candidates = line.split(separator: "\"", omittingEmptySubsequences: false).map(String.init)
            if let number = candidates.first(where: { $0.range(of: #"^\+?[0-9][0-9 -]{5,}$"#, options: .regularExpression) != nil }) {
                return number.replacingOccurrences(of: " ", with: "")
            }
        }
        return "运营商未提供"
    }

    private func operatorLabel(_ value: String) -> String {
        let labels = [
            "46000": "中国移动", "46001": "中国联通", "46003": "中国电信",
            "46004": "中国移动", "46005": "中国电信", "46006": "中国联通",
            "46007": "中国移动", "46008": "中国移动", "46009": "中国联通",
            "46011": "中国电信", "46015": "中国广电"
        ]
        if let label = labels[value] { return "\(label)（\(value)）" }
        if value.allSatisfy(\.isNumber) { return "运营商（\(value)）" }
        return value
    }

    private func readVoiceStatus() {
        let ims = (try? command("AT+QCFG=\"ims\"")) ?? ""
        let usb = (try? command("AT+QCFG=\"usbcfg\"")) ?? ""
        let pcm = channel.flatMap { try? $0.send("AT+QPCMV?", timeout: 0.8) } ?? ""
        let imsEnabled = ims.range(of: #"\+QCFG:\s*"ims",\s*1(?:\s|,|$)"#, options: .regularExpression) != nil
        let usbLine = usb.split(whereSeparator: \.isNewline).first(where: { $0.contains("+QCFG:") }).map(String.init) ?? ""
        let usbFields = usbLine.components(separatedBy: ",").map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
        let uacEnabled = usbFields.last == "1"
        let imsText = ims.isEmpty ? "IMS 未读取" : (imsEnabled ? "IMS 已开启" : "IMS 未开启")
        let uacText = usb.isEmpty ? "UAC 未读取" : (uacEnabled ? "USB 音频已启用" : "USB 音频未启用")
        let pcmText: String
        if pcm.isEmpty {
            pcmText = "媒体路由未读取"
        } else if pcm.uppercased().contains("ERROR") {
            pcmText = "媒体路由不支持"
        } else {
            pcmText = "媒体路由已提供"
        }
        voiceStatus = "\(imsText) · \(uacText) · \(pcmText)"
    }

    private func automaticAPN() -> String? {
        guard let code = numericOperatorCode() else {
            return apn.isEmpty ? nil : apn
        }
        switch code {
        case "46000", "46004", "46007", "46008":
            return "cmnet"
        case "46001", "46006", "46009":
            return "3gnet"
        case "46003", "46005", "46011":
            return "ctnet"
        case "46015":
            return "cbnet"
        default:
            return apn.isEmpty ? nil : apn
        }
    }

    private func numericOperatorCode() -> String? {
        _ = try? command("AT+COPS=3,2")
        defer { _ = try? command("AT+COPS=3,0") }
        guard let response = try? command("AT+COPS?") else { return nil }
        return response.split(separator: "\"").dropFirst().first.map(String.init)
    }

    func applyVoiceConfiguration() {
        guard !isApplyingVoiceConfiguration else { return }
        guard channel != nil else {
            fail("应用语音配置需要 AT 接口；请先连接 Baiwang 网卡。")
            return
        }
        isApplyingVoiceConfiguration = true
        defer { isApplyingVoiceConfiguration = false }
        do {
            let current = try command("AT+QCFG=\"usbcfg\"")
            let pattern = #"\+QCFG:\s*"usbcfg",\s*(0x[0-9A-Fa-f]+|\d+),\s*(0x[0-9A-Fa-f]+|\d+),\s*([01]),\s*([01]),\s*([01]),\s*([01]),\s*([01]),\s*([01]),\s*([01])"#
            guard let match = current.range(of: pattern, options: .regularExpression) else {
                throw ModemError.commandFailed("无法解析当前 USB 配置：\(current)")
            }
            let fields = current[match]
                .replacingOccurrences(of: #"\+QCFG:\s*"usbcfg",\s*"#, with: "", options: .regularExpression)
                .split(separator: ",")
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            guard fields.count == 9 else { throw ModemError.commandFailed("USB 配置字段数量异常") }
            let target = fields.dropLast(2) + ["1", "1"]
            let commandText = "AT+QCFG=\"usbcfg\",\(target.joined(separator: ","))"
            _ = try command(commandText)
            _ = try command("AT+QCFG=\"ims\",1")
            appendLog("已启用 IMS 和 USB 音频接口，模块将重启")
            _ = try? command("AT+CFUN=1,1", timeout: 2)
            channel?.close()
            channel = nil
            callState = .idle
            callStartedAt = nil
            voiceStatus = "已应用，等待模块重新枚举"
            appendLog("模块正在重启，请等待 Baiwang 网卡和 AT 接口重新出现")
        } catch {
            voiceStatus = "应用失败"
            fail(error.localizedDescription)
        }
    }

    private func startCallPolling() {
        callTimer?.invalidate()
        callTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.pollCallState() }
        }
    }

    private func pollCallState() {
        guard let channel else {
            // Some QDC507 firmware briefly drops the AT response channel when
            // the voice bearer is being established. Do not turn an already
            // connected call into a false failure in that window.
            if !callEverConnected {
                finishCallFailure("AT 通道已断开", queryCause: false)
            }
            return
        }
        let elapsed = callStartedAt.map { Date().timeIntervalSince($0) } ?? 0
        guard let response = try? channel.send("AT+CLCC", timeout: 0.8) else {
            if !callEverConnected, elapsed > 30 {
                finishCallFailure("呼叫超时，模块未返回通话状态", queryCause: true)
            }
            return
        }
        let upper = response.uppercased()
        if upper.contains("BUSY") && !callEverConnected {
            finishCallFailure("对方占线", queryCause: true)
        } else if upper.contains("NO ANSWER") && !callEverConnected {
            finishCallFailure("对方未接听", queryCause: true)
        } else if upper.contains("NO CARRIER") {
            if callEverConnected {
                finishActiveCall(outcome: .completed)
                callState = .idle
                callTimer?.invalidate()
                callTimer = nil
                callStartedAt = nil
                appendLog("通话已结束（模块返回 NO CARRIER）")
            } else {
                finishCallFailure("网络拒绝或未建立语音承载", queryCause: true)
            }
        } else if (upper.contains("+CME ERROR") || upper.contains("+CMS ERROR") || upper.trimmingCharacters(in: .whitespacesAndNewlines).hasSuffix("ERROR")) && !callEverConnected {
            finishCallFailure("网络拒绝或未建立语音承载", queryCause: true)
        } else if let status = callStatus(in: response) {
            switch status {
            case 0:
                if !callEverConnected { appendLog("对方已接听，通话已建立") }
                callEverConnected = true
                callState = .connected
                markCallConnected()
            case 2, 3:
                if case .calling = callState { return }
                callState = .calling("通话建立中")
            default:
                if elapsed > 30 { finishCallFailure("呼叫超时，未接通", queryCause: true) }
            }
        } else if elapsed > 30 {
            if !callEverConnected {
                finishCallFailure("呼叫超时，模块未建立语音承载", queryCause: true)
            }
        }
    }

    private func clccStatus(in response: String) -> Int? {
        let pattern = #"\+CLCC:\s*\d+\s*,\s*\d+\s*,\s*(\d+)"#
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(in: response, range: NSRange(response.startIndex..., in: response)),
              let range = Range(match.range(at: 1), in: response) else { return nil }
        return Int(response[range])
    }

    private func callStatus(in response: String) -> Int? {
        let upper = response.uppercased()
        if upper.contains("+COLP:") || upper.contains("CONNECT") { return 0 }
        if let status = clccStatus(in: response) { return status }
        let patterns = [
            #"\+QIND:\s*\"ccinfo\",\s*\d+\s*,\s*\d+\s*,\s*(-?\d+)"#,
            #"\^DSCI:\s*\d+\s*,\s*\d+\s*,\s*(-?\d+)"#
        ]
        for pattern in patterns {
            guard let regex = try? NSRegularExpression(pattern: pattern),
                  let match = regex.firstMatch(in: response, range: NSRange(response.startIndex..., in: response)),
                  let range = Range(match.range(at: 1), in: response),
                  let status = Int(response[range]) else { continue }
            return status
        }
        return nil
    }

    private func finishCallFailure(_ reason: String, queryCause: Bool) {
        if queryCause, let channel, let cause = try? channel.send("AT+CEER", timeout: 0.8) {
            let visible = cause.replacingOccurrences(of: "\r", with: "").replacingOccurrences(of: "\n", with: " ").trimmingCharacters(in: .whitespacesAndNewlines)
            if !visible.isEmpty { appendLog("通话原因：\(visible)") }
        }
        finishActiveCall(outcome: .failed)
        callState = .failed(reason)
        callTimer?.invalidate()
        callTimer = nil
        callStartedAt = nil
        appendLog("呼叫失败：\(reason)")
    }

    private func waitForNetworkInterface() -> NetworkInterfaceInfo? {
        for _ in 0..<4 {
            if let found = SystemNetwork.usbInterface() { return found }
            RunLoop.current.run(until: Date().addingTimeInterval(0.25))
        }
        return nil
    }

    private func waitForNetworkAddress(_ interfaceInfo: NetworkInterfaceInfo) -> NetworkInterfaceInfo? {
        for _ in 0..<20 {
            if let address = SystemNetwork.address(for: interfaceInfo.device) {
                return NetworkInterfaceInfo(device: interfaceInfo.device, label: interfaceInfo.label, address: address)
            }
            RunLoop.current.run(until: Date().addingTimeInterval(0.5))
        }
        return nil
    }

    private func restartAndActivateData(apn: String?) throws -> NetworkInterfaceInfo? {
        guard let channel else { return nil }
        _ = try? channel.send("AT+CFUN=1,1", timeout: 2)
        channel.close()
        self.channel = nil

        for _ in 0..<30 {
            RunLoop.current.run(until: Date().addingTimeInterval(0.5))
            if let usb = try? USBATPort() {
                self.channel = usb
                break
            }
        }
        guard self.channel != nil else { return nil }
        if let apn {
            _ = try command("AT+CGDCONT=1,\"IP\",\"\(apn)\"")
        }
        _ = try command("AT+CGATT=1", timeout: 8)
        _ = try command("AT+CGACT=1,1", timeout: 15)

        guard let interfaceInfo = waitForNetworkInterface() else { return nil }
        _ = SystemNetwork.renewDHCP(for: interfaceInfo.device, service: interfaceInfo.label)
        return waitForNetworkAddress(interfaceInfo)
    }

    private func startNetworkPolling() {
        networkTimer?.invalidate()
        networkTimer = Timer.scheduledTimer(withTimeInterval: 3, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                if let device = self.network?.device, let address = SystemNetwork.address(for: device) {
                    self.network = NetworkInterfaceInfo(device: device, label: self.network?.label ?? "USB 网络", address: address)
                } else if let found = SystemNetwork.usbInterface() {
                    self.network = found
                }
            }
        }
    }

    private func firstMeaningfulLine(_ value: String) -> String {
        value.split(separator: "\n").map(String.init).first(where: { !$0.contains("ATI") && !$0.isEmpty }) ?? value
    }

    private func parseMessages(_ response: String) -> [SMSMessage] {
        var result: [SMSMessage] = []
        var current: (id: Int, sender: String, date: String, body: String)?
        let lines = response.replacingOccurrences(of: "\r", with: "").split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        for line in lines {
            if line.hasPrefix("+CMGL:") {
                if let current { result.append(SMSMessage(id: current.id, sender: current.sender, date: current.date, body: current.body)) }
                let fields = line.replacingOccurrences(of: "+CMGL:", with: "").split(separator: ",", omittingEmptySubsequences: false).map { $0.trimmingCharacters(in: .whitespacesAndNewlines).trimmingCharacters(in: CharacterSet(charactersIn: "\"")) }
                let id = Int(fields.first ?? "0") ?? result.count
                let sender = fields.count > 2 ? decodeATText(fields[2]) : "未知号码"
                let date = fields.count > 4 ? fields[4] : ""
                current = (id, sender, date, "")
            } else if line != "OK", !line.isEmpty, var message = current {
                let decoded = decodeATText(line)
                message.body += message.body.isEmpty ? decoded : "\n\(decoded)"
                current = message
            }
        }
        if let current { result.append(SMSMessage(id: current.id, sender: current.sender, date: current.date, body: current.body)) }
        return result
    }

    private func decodeATText(_ value: String) -> String {
        let text = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard text.count.isMultiple(of: 4), text.allSatisfy({ $0.isHexDigit }) else { return text }
        var units: [UInt16] = []
        var index = text.startIndex
        while index < text.endIndex {
            let end = text.index(index, offsetBy: 4)
            guard let unit = UInt16(text[index..<end], radix: 16) else { return text }
            units.append(unit)
            index = end
        }
        return String(decoding: units, as: UTF16.self)
    }

    private func appendLog(_ text: String) {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss"
        logs.append("\(formatter.string(from: Date()))  \(text)")
        if logs.count > 120 { logs.removeFirst(logs.count - 120) }
    }

    private func fail(_ message: String) {
        state = .error
        errorMessage = message
        appendLog("错误：\(message)")
    }
}

// MARK: - UI

@main
struct DJI4GConnectApp: App {
    @StateObject private var modem = ModemManager()

    init() {
        if CommandLine.arguments.contains("--probe-at") {
            do {
                let usb = try USBATPort()
                print(try usb.send("ATI"))
                print(try usb.send("AT+COPS?"))
                print(try usb.send("AT+COPS=3,2"))
                print(try usb.send("AT+COPS?"))
                print(try usb.send("AT+CNUM"))
                _ = try? usb.send("AT+COPS=3,0")
                print(try usb.send("AT+QCFG=\"ims\""))
                print(try usb.send("AT+QCFG=\"usbcfg\""))
                print(try usb.send("AT+QPCMV?"))
                print(try usb.send("AT+CSQ"))
                print(try usb.send("AT+CGDCONT?"))
                print(try usb.send("AT+CGATT?"))
                print(try usb.send("AT+CGACT?"))
                usb.close()
                Darwin.exit(0)
            } catch {
                fputs("AT probe failed: \(error.localizedDescription)\n", stderr)
                Darwin.exit(1)
            }
        }
        NSApplication.shared.setActivationPolicy(.regular)
        NSApplication.shared.activate(ignoringOtherApps: true)
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(modem)
                .frame(minWidth: 900, minHeight: 620)
        }
        .windowResizability(.contentSize)
        .commands {
            CommandGroup(after: .windowArrangement) {
                Button("重新扫描设备") { modem.refreshPorts() }
                    .keyboardShortcut("r", modifiers: [.command, .shift])
            }
        }
    }
}

enum AppSection: Hashable {
    case overview
    case messages
    case phone
}

struct ContentView: View {
    @EnvironmentObject private var modem: ModemManager
    @State private var selectedSection: AppSection = .overview
    @State private var recipient = ""
    @State private var messageBody = ""
    @State private var phoneNumber = ""

    var body: some View {
        HStack(spacing: 0) {
            Sidebar(selectedSection: $selectedSection)
            Divider()
            switch selectedSection {
            case .overview: mainContent
            case .messages: messagesContent
            case .phone: phoneContent
            }
        }
        .background(Color(nsColor: .windowBackgroundColor))
    }

    private var mainContent: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 7) {
                    Text("连接你的 4G 模块")
                        .font(.system(size: 28, weight: .semibold, design: .rounded))
                    Text("插入自己的 SIM 卡，让 MacBook 直接使用移动网络。")
                        .foregroundStyle(.secondary)
                }
                Spacer()
                StatusPill(state: modem.state)
            }
            .padding(.bottom, 28)

            HStack(alignment: .top, spacing: 18) {
                setupPanel
                statusPanel
            }

            logPanel
        }
        .padding(32)
    }

    private var setupPanel: some View {
        VStack(alignment: .leading, spacing: 20) {
            SectionTitle(icon: "cable.connector", title: "设备与网络")

            VStack(alignment: .leading, spacing: 8) {
                FieldLabel("模块串口")
                HStack(spacing: 8) {
                    Image(systemName: "externaldrive.connected.to.line.below")
                        .foregroundStyle(Color.accentColor)
                    Picker("串口", selection: $modem.selectedPort) {
                        if modem.ports.isEmpty {
                            Text(modem.network == nil ? "未发现串口" : "网卡已连接，无需串口").tag("")
                        }
                        ForEach(modem.ports, id: \.self) { port in Text(port.replacingOccurrences(of: "/dev/", with: "")).tag(port) }
                    }
                    .labelsHidden()
                    Button { modem.refreshPorts() } label: { Image(systemName: "arrow.clockwise") }
                        .buttonStyle(.borderless)
                        .help("重新扫描")
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 10)
                .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 10))
            }

            if !modem.errorMessage.isEmpty {
                Label(modem.errorMessage, systemImage: "exclamationmark.triangle.fill")
                    .font(.callout)
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Button {
                modem.isConnected ? modem.disconnect() : modem.connect()
            } label: {
                HStack {
                    Image(systemName: modem.isConnected ? "stop.fill" : "bolt.fill")
                    Text(modem.isConnected ? "断开 4G" : "开始连接")
                }
                .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .disabled(modem.state == .connecting)

            Text("连接过程只修改本次会话的网络设置，不会刷写或永久修改模块。")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(22)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 16))
    }

    private var statusPanel: some View {
        VStack(alignment: .leading, spacing: 20) {
            SectionTitle(icon: "antenna.radiowaves.left.and.right", title: "连接状态")

            VStack(alignment: .leading, spacing: 16) {
                InfoRow(label: "运营商", value: modem.operatorName, icon: "building.2")
                InfoRow(label: "本机号码", value: modem.localNumber, icon: "phone")
                InfoRow(label: "USB 模式", value: modem.usbMode, icon: "arrow.triangle.branch")
                InfoRow(label: "信号", value: modem.signalText, icon: "cellularbars")
                InfoRow(label: "USB 网卡", value: modem.network?.device ?? "等待出现", icon: "network")
                InfoRow(label: "IP 地址", value: modem.network?.address ?? "尚未获取", icon: "number")
            }

            Spacer(minLength: 0)

            if modem.isConnected {
                Label(modem.network?.address == nil ? "正在等待 DHCP 地址" : "MacBook 正在使用 USB 4G 网络", systemImage: modem.network?.address == nil ? "hourglass" : "checkmark.circle.fill")
                    .font(.callout.weight(.medium))
                    .foregroundStyle(modem.network?.address == nil ? .orange : .green)
            } else {
                Text("连接后，这里会显示运营商、信号和 IP 地址。")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(22)
        .frame(maxWidth: .infinity, minHeight: 306, alignment: .leading)
        .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 16))
    }

    private var logPanel: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                SectionTitle(icon: "terminal", title: "连接日志")
                Spacer()
                Button("清空") { modem.clearLogs() }
                    .buttonStyle(.borderless)
                    .foregroundStyle(.secondary)
            }
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 5) {
                        if modem.logs.isEmpty {
                            Text("等待操作…")
                                .foregroundStyle(.tertiary)
                        } else {
                            ForEach(Array(modem.logs.enumerated()), id: \.offset) { index, line in
                                Text(line)
                                    .font(.system(size: 11, design: .monospaced))
                                    .foregroundStyle(line.contains("错误") ? .red : .secondary)
                                    .textSelection(.enabled)
                                    .id(index)
                            }
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(14)
                }
                .onChange(of: modem.logs.count, perform: { _ in
                    if let last = modem.logs.indices.last { proxy.scrollTo(last, anchor: .bottom) }
                })
            }
            .frame(height: 148)
            .background(Color.black.opacity(0.04), in: RoundedRectangle(cornerRadius: 10))
        }
        .padding(.top, 24)
    }

    private var messagesContent: some View {
        VStack(alignment: .leading, spacing: 0) {
            pageHeader(title: "短信", subtitle: "读取 SIM 卡短信，或使用模块发送新消息。") {
                HStack(spacing: 10) {
                    Button { modem.loadMessages() } label: {
                        Label("刷新短信", systemImage: "arrow.clockwise")
                    }
                    .buttonStyle(.bordered)
                    Button { modem.clearSMSHistory() } label: {
                        Label("清空记录", systemImage: "trash")
                    }
                    .buttonStyle(.borderless)
                    .foregroundStyle(.secondary)
                }
            }

            HStack(alignment: .top, spacing: 18) {
                VStack(alignment: .leading, spacing: 14) {
                    SectionTitle(icon: "clock.arrow.circlepath", title: "短信记录")
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 12) {
                            if modem.smsHistory.isEmpty {
                                VStack(alignment: .leading, spacing: 8) {
                                    Image(systemName: "message.badge.waveform")
                                        .font(.system(size: 28))
                                        .foregroundStyle(.secondary)
                                    Text("还没有短信记录")
                                        .font(.headline)
                                    Text("点击右上角“刷新短信”。如果当前只有 USB 网卡，没有 AT 串口，短信功能需要先切换模块模式。")
                                        .font(.callout)
                                        .foregroundStyle(.secondary)
                                        .fixedSize(horizontal: false, vertical: true)
                                }
                                .padding(.vertical, 22)
                            } else {
                                ForEach(modem.smsHistory) { record in
                                    SMSHistoryRow(record: record)
                                }
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
                .padding(22)
                .frame(maxWidth: .infinity, minHeight: 300, alignment: .leading)
                .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 16))

                VStack(alignment: .leading, spacing: 14) {
                    SectionTitle(icon: "square.and.pencil", title: "发送短信")
                    FieldLabel("收件人")
                    TextField("+86 138…", text: $recipient)
                        .textFieldStyle(.roundedBorder)
                    FieldLabel("内容")
                    TextEditor(text: $messageBody)
                        .font(.callout)
                        .padding(6)
                        .frame(minHeight: 112)
                        .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 8))
                    Button { modem.sendMessage(to: recipient, body: messageBody) } label: {
                        Label("发送", systemImage: "paperplane.fill")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                }
                .padding(22)
                .frame(width: 280, alignment: .leading)
                .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 16))
            }
            .padding(.top, 24)

            featureNotice
        }
        .padding(32)
        .onAppear { modem.startSMSAutoRefresh() }
        .onDisappear { modem.stopSMSAutoRefresh() }
    }

    private var phoneContent: some View {
        VStack(alignment: .leading, spacing: 0) {
            pageHeader(title: "电话", subtitle: "通过模块的语音通道拨号或挂断。") { EmptyView() }

            HStack(alignment: .top, spacing: 18) {
                VStack(alignment: .leading, spacing: 20) {
                    SectionTitle(icon: "phone", title: "拨号")
                    TextField("输入电话号码", text: $phoneNumber)
                        .textFieldStyle(.roundedBorder)
                        .font(.title3.monospacedDigit())
                    HStack(spacing: 10) {
                        Button { modem.dial(phoneNumber) } label: {
                            Label("拨打", systemImage: "phone.fill")
                                .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.large)
                        Button { modem.hangUp() } label: {
                            Label("挂断", systemImage: "phone.down.fill")
                                .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.large)
                    }
                }
                .padding(22)
                .frame(maxWidth: .infinity, minHeight: 210, alignment: .leading)
                .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 16))

                VStack(alignment: .leading, spacing: 16) {
                    SectionTitle(icon: "phone.connection", title: "通话状态")
                    Image(systemName: modem.callState == .idle || isFailedCall ? "phone" : "phone.fill")
                        .font(.system(size: 34))
                        .foregroundStyle(isFailedCall ? Color.red : modem.callState == .idle ? Color.secondary : Color.green)
                    Text(modem.callState.title)
                        .font(.title3.weight(.medium))
                    Text(modem.voiceStatus)
                        .font(.callout.weight(.medium))
                        .foregroundStyle(modem.voiceStatus.contains("未") || modem.voiceStatus.contains("不支持") ? .orange : .secondary)
                    if modem.voiceStatus.contains("IMS 未开启") || modem.voiceStatus.contains("USB 音频未启用") {
                        Button {
                            modem.applyVoiceConfiguration()
                        } label: {
                            Label(modem.isApplyingVoiceConfiguration ? "正在应用…" : "启用语音并重启模块", systemImage: "waveform")
                        }
                        .buttonStyle(.bordered)
                        .disabled(modem.isApplyingVoiceConfiguration)
                    }
                    if modem.voiceStatus.contains("媒体路由不支持") {
                        Text("模块已被 Mac 识别为 USB 音频设备，但当前固件没有提供通话媒体路由，所以只能建立通话信令，声音不会进入 Mac 的扬声器或麦克风。")
                            .font(.caption)
                            .foregroundStyle(.orange)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Text("拨号命令被接受不等于对方已响铃；只有模块返回真实 CLCC 接通状态才显示“通话中”。")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(22)
                .frame(width: 280, height: 210, alignment: .leading)
                .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 16))
            }

            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    SectionTitle(icon: "clock.arrow.circlepath", title: "通话记录")
                    Spacer()
                    Button("清空") { modem.clearCallHistory() }
                        .buttonStyle(.borderless)
                        .foregroundStyle(.secondary)
                }
                if modem.callHistory.isEmpty {
                    Text("还没有通话记录")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .padding(.vertical, 10)
                } else {
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 10) {
                            ForEach(modem.callHistory) { record in
                                CallHistoryRow(record: record)
                            }
                        }
                    }
                    .frame(height: 150)
                }
            }
            .padding(22)
            .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 16))
            .padding(.top, 24)

            featureNotice
        }
        .padding(32)
    }

    private var isFailedCall: Bool {
        if case .failed = modem.callState { return true }
        return false
    }

    private var featureNotice: some View {
        Group {
            if !modem.errorMessage.isEmpty {
                Label(modem.errorMessage, systemImage: "exclamationmark.triangle.fill")
                    .font(.callout)
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.top, 18)
            } else {
                Label("电话和短信需要模块 AT 接口；当前仅有 Baiwang 网卡时，网络仍可正常使用。", systemImage: "info.circle")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .padding(.top, 18)
            }
        }
    }

    private func pageHeader<Actions: View>(title: String, subtitle: String, @ViewBuilder actions: () -> Actions) -> some View {
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 7) {
                Text(title)
                    .font(.system(size: 28, weight: .semibold, design: .rounded))
                Text(subtitle)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            actions()
        }
        .padding(.bottom, 28)
    }
}

struct Sidebar: View {
    @EnvironmentObject private var modem: ModemManager
    @Binding var selectedSection: AppSection

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 11) {
                ZStack {
                    RoundedRectangle(cornerRadius: 10)
                        .fill(Color.accentColor)
                    Image(systemName: "antenna.radiowaves.left.and.right")
                        .foregroundStyle(.white)
                        .font(.system(size: 16, weight: .semibold))
                }
                .frame(width: 34, height: 34)
                Text("DJI 4G Connect")
                    .font(.headline)
            }
            .padding(.bottom, 42)

            Text("使用流程")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
                .padding(.bottom, 14)

            StepRow(number: "1", title: "连接模块", detail: modem.network != nil ? "Baiwang 网卡已连接" : modem.ports.isEmpty ? "等待 USB 设备" : "已发现串口", active: modem.state == .disconnected || modem.state == .error)
            StepRow(number: "2", title: "自动配置网络", detail: "根据运营商自动选择接入点", active: !modem.isConnected)
            StepRow(number: "3", title: "开始上网", detail: modem.isConnected ? "网络已就绪" : "等待连接", active: modem.isConnected)

            VStack(alignment: .leading, spacing: 6) {
                NavRow(title: "总览", icon: "rectangle.3.group", selected: selectedSection == .overview) { selectedSection = .overview }
                NavRow(title: "短信", icon: "message", selected: selectedSection == .messages) { selectedSection = .messages }
                NavRow(title: "电话", icon: "phone", selected: selectedSection == .phone) { selectedSection = .phone }
            }

            Spacer()

            VStack(alignment: .leading, spacing: 8) {
                Label("支持大疆一代 4G 模块", systemImage: "checkmark.seal")
                Text("macOS 13 · Apple Silicon\nUSB-C 数据线连接")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.top, 16)
        }
        .padding(24)
        .frame(width: 228, alignment: .leading)
        .background(Color(nsColor: .underPageBackgroundColor))
    }
}

struct NavRow: View {
    let title: String
    let icon: String
    let selected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Label(title, systemImage: icon)
                Spacer(minLength: 0)
            }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 10)
                .padding(.vertical, 8)
                .foregroundStyle(selected ? .primary : .secondary)
                .background(selected ? Color.accentColor.opacity(0.12) : .clear, in: RoundedRectangle(cornerRadius: 8))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .frame(maxWidth: .infinity)
    }
}

struct SMSRow: View {
    let message: SMSMessage

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Label(message.sender, systemImage: "person.crop.circle")
                    .font(.callout.weight(.medium))
                Spacer()
                Text(message.date)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Text(message.body.isEmpty ? "（空短信）" : message.body)
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.bottom, 10)
        .overlay(alignment: .bottom) { Divider() }
    }
}

struct SMSHistoryRow: View {
    let record: SMSHistoryRecord

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 8) {
                Label(record.direction.title, systemImage: record.direction == .incoming ? "arrow.down.left" : "arrow.up.right")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(record.direction == .incoming ? .blue : .green)
                Text(record.number)
                    .font(.callout.weight(.medium))
                Spacer()
                Text(record.displayDate)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Text(record.body.isEmpty ? "（空短信）" : record.body)
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.bottom, 9)
        .overlay(alignment: .bottom) { Divider() }
    }
}

struct CallHistoryRow: View {
    let record: CallRecord

    private static let formatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "MM-dd HH:mm"
        return formatter
    }()

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: record.outcome == .failed ? "phone.down.fill" : "phone.fill")
                .foregroundStyle(record.outcome == .failed ? .red : record.outcome == .connected ? .green : .secondary)
            VStack(alignment: .leading, spacing: 3) {
                Text(record.number)
                    .font(.callout.weight(.medium))
                Text("\(Self.formatter.string(from: record.startedAt)) · \(record.outcome.title)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            if record.duration > 0 {
                Text(durationText(record.duration))
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 2)
    }

    private func durationText(_ duration: TimeInterval) -> String {
        let seconds = Int(duration.rounded())
        return seconds >= 60 ? "\(seconds / 60)m \(seconds % 60)s" : "\(seconds)s"
    }
}

struct StepRow: View {
    let number: String
    let title: String
    let detail: String
    let active: Bool

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Text(number)
                .font(.system(size: 12, weight: .semibold, design: .rounded))
                .foregroundStyle(active ? .white : .secondary)
                .frame(width: 24, height: 24)
                .background(active ? Color.accentColor : Color.secondary.opacity(0.15), in: Circle())
            VStack(alignment: .leading, spacing: 3) {
                Text(title).font(.callout.weight(.medium))
                Text(detail).font(.caption).foregroundStyle(.secondary)
            }
        }
        .padding(.bottom, 23)
    }
}

struct SectionTitle: View {
    let icon: String
    let title: String

    var body: some View {
        Label(title, systemImage: icon)
            .font(.headline)
    }
}

struct FieldLabel: View {
    let title: String
    init(_ title: String) { self.title = title }

    var body: some View {
        Text(title.uppercased())
            .font(.caption.weight(.semibold))
            .foregroundStyle(.secondary)
    }
}

struct StatusPill: View {
    let state: ConnectionState

    var body: some View {
        Label(state.title, systemImage: state == .connected ? "checkmark.circle.fill" : state == .connecting ? "arrow.triangle.2.circlepath" : state == .error ? "exclamationmark.circle.fill" : "circle")
            .font(.callout.weight(.medium))
            .foregroundStyle(state == .connected ? .green : state == .error ? .red : .secondary)
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(Color(nsColor: .controlBackgroundColor), in: Capsule())
    }
}

struct InfoRow: View {
    let label: String
    let value: String
    let icon: String

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: icon)
                .foregroundStyle(.secondary)
                .frame(width: 18)
            Text(label)
                .foregroundStyle(.secondary)
            Spacer()
            Text(value)
                .fontWeight(.medium)
                .lineLimit(1)
        }
        .font(.callout)
    }
}
