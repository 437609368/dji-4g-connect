import Foundation
import Network
import SwiftUI
import AVFoundation

@main
struct DJI4GConnectIOSApp: App {
    @StateObject private var model = NetworkModel()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(model)
        }
    }
}

@MainActor
final class NetworkModel: ObservableObject {
    @Published private(set) var status = "检测中"
    @Published private(set) var interfaceName = "—"
    @Published private(set) var isConnected = false
    @Published private(set) var isOnline = false
    @Published private(set) var operatorName = "未读取"
    @Published private(set) var signalText = "未读取"
    @Published private(set) var modemModel = "未读取"
    @Published private(set) var lastChecked: Date?
    @Published private(set) var bridgeStatus = "未检测"
    @Published private(set) var bridgeDetail = ""
    @Published private(set) var callState = "空闲"
    @Published var phoneNumber = ""
    @Published var cloudBaseURL = UserDefaults.standard.string(forKey: "cloudBaseURL") ?? ""
    @Published var cloudToken = UserDefaults.standard.string(forKey: "cloudToken") ?? ""
    @Published var cloudDeviceID = UserDefaults.standard.string(forKey: "cloudDeviceID") ?? "iphone"
    @Published private(set) var smsMessages: [CloudSMSMessage] = []
    @Published private(set) var smsStatus = "未配置云端"
    @Published var smsRecipient = ""
    @Published var smsBody = ""

    private let monitor = NWPathMonitor()
    private let queue = DispatchQueue(label: "local.dji.4g-connect.network")
    private let bridge = ModemBridgeClient()
    private let cloudSMS = CloudSMSClient()
    private let cloudCallKit = CloudCallKitManager.shared
    private var callPollingTask: Task<Void, Never>?
    private var pathIsSatisfied = false
    private var internetCheckSucceeded = false
    private var localCallWasActive = false
    private var lastIncomingNumber: String?

    init() {
        monitor.pathUpdateHandler = { [weak self] path in
            Task { @MainActor in
                self?.update(path)
            }
        }
        monitor.start(queue: queue)
        cloudCallKit.onStateChange = { [weak self] state in
            Task { @MainActor in self?.callState = state }
        }
        cloudCallKit.configureLocal(
            start: { [weak self] number in
                guard let self else { throw NSError(domain: "DJI4GConnect", code: 1, userInfo: [NSLocalizedDescriptionKey: "模块控制对象已释放"]) }
                _ = try await self.sendLocalAT("ATD\(number);")
            },
            answer: { [weak self] in
                guard let self else { throw NSError(domain: "DJI4GConnect", code: 1, userInfo: [NSLocalizedDescriptionKey: "模块控制对象已释放"]) }
                _ = try await self.sendLocalAT("ATA")
            },
            end: { [weak self] in
                guard let self else { throw NSError(domain: "DJI4GConnect", code: 1, userInfo: [NSLocalizedDescriptionKey: "模块控制对象已释放"]) }
                _ = try? await self.sendLocalAT("AT+CHUP")
            }
        )
        if cloudConfigured {
            cloudCallKit.configure(baseURL: cloudBaseURL, token: cloudToken, deviceID: cloudDeviceID)
        }
    }

    deinit {
        monitor.cancel()
        callPollingTask?.cancel()
    }

    func checkInternet() {
        status = "检测中"
        internetCheckSucceeded = false
        Task {
            do {
                var request = URLRequest(url: URL(string: "https://captive.apple.com/hotspot-detect.html")!)
                request.timeoutInterval = 8
                let (_, response) = try await URLSession.shared.data(for: request)
                guard let http = response as? HTTPURLResponse, (200..<400).contains(http.statusCode) else {
                    throw URLError(.badServerResponse)
                }
                internetCheckSucceeded = true
                isConnected = true
                if interfaceName == "—" { interfaceName = "USB 以太网" }
                isOnline = true
                status = "可以上网"
            } catch {
                isConnected = pathIsSatisfied
                isOnline = false
                status = "网络不可用"
            }
            lastChecked = Date()
        }
    }

    func saveCloudSettings() {
        UserDefaults.standard.set(cloudBaseURL.trimmingCharacters(in: .whitespacesAndNewlines), forKey: "cloudBaseURL")
        UserDefaults.standard.set(cloudToken, forKey: "cloudToken")
        UserDefaults.standard.set(cloudDeviceID, forKey: "cloudDeviceID")
        cloudCallKit.configure(baseURL: cloudBaseURL, token: cloudToken, deviceID: cloudDeviceID)
        smsStatus = "云端配置已保存"
    }

    func syncSMS() {
        guard cloudConfigured else {
            smsStatus = "请先填写云服务器配置"
            return
        }
        smsStatus = "同步中…"
        Task {
            do {
                let messages = try await cloudSMS.fetchMessages(baseURL: cloudBaseURL, token: cloudToken, deviceID: cloudDeviceID)
                await MainActor.run {
                    self.smsMessages = messages
                    self.smsStatus = "已同步 \(messages.count) 条短信"
                }
            } catch {
                await MainActor.run { self.smsStatus = error.localizedDescription }
            }
        }
    }

    func queueSMS() {
        let recipient = smsRecipient.trimmingCharacters(in: .whitespacesAndNewlines)
        let body = smsBody.trimmingCharacters(in: .whitespacesAndNewlines)
        guard cloudConfigured, !recipient.isEmpty, !body.isEmpty else {
            smsStatus = "请填写云端配置、收件号码和短信内容"
            return
        }
        smsStatus = "发送命令排队中…"
        Task {
            do {
                let commandID = try await cloudSMS.enqueueSMS(baseURL: cloudBaseURL, token: cloudToken, deviceID: cloudDeviceID, to: recipient, body: body)
                await MainActor.run { self.smsStatus = "已排队，命令 ID：\(commandID.prefix(8))" }
            } catch {
                await MainActor.run { self.smsStatus = error.localizedDescription }
            }
        }
    }

    private var cloudConfigured: Bool {
        !cloudBaseURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty &&
        !cloudToken.isEmpty && !cloudDeviceID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    func discoverModuleControl() {
        bridgeStatus = "检测中"
        bridgeDetail = "正在通过 USB 以太网寻找模块 AT 控制通道"
        Task {
            do {
                let endpoint = try await bridge.discover()
                let identity = try? await bridge.sendAT("ATI")
                let cops = try? await bridge.sendAT("AT+COPS?")
                let csq = try? await bridge.sendAT("AT+CSQ")
                await MainActor.run {
                    self.bridgeStatus = "已发现"
                    self.bridgeDetail = endpoint.description
                    self.modemModel = Self.modemModel(from: identity)
                    self.operatorName = Self.operatorName(from: cops)
                    self.signalText = Self.signalText(from: csq)
                }
                await self.pollCallState()
            } catch {
                await MainActor.run {
                    self.bridgeStatus = "未发现"
                    self.bridgeDetail = "模块当前只提供上网接口，未发现 AT 桥接服务：\(error.localizedDescription)"
                    self.modemModel = "等待 AT 通道"
                    self.operatorName = "等待 AT 通道"
                    self.signalText = "等待 AT 通道"
                }
            }
        }
    }

    func dial() {
        let number = phoneNumber.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !number.isEmpty else {
            callState = "请输入号码"
            return
        }
        if cloudConfigured {
            cloudCallKit.startOutgoing(number: number, baseURL: cloudBaseURL, token: cloudToken, deviceID: cloudDeviceID)
            return
        }
        localCallWasActive = true
        cloudCallKit.startOutgoing(number: number)
        callState = "请求系统电话界面"
        Task { await self.pollCallState() }
    }

    func answer() {
        if cloudConfigured {
            cloudCallKit.answerCurrentCall()
            return
        }
        cloudCallKit.answerCurrentCall()
        callState = "请求系统接听界面"
    }

    func hangup() {
        if cloudConfigured {
            cloudCallKit.endCurrentCall()
            return
        }
        cloudCallKit.endCurrentCall()
        callState = "正在挂断"
    }

    private func pollCallState() async {
        callPollingTask?.cancel()
        callPollingTask = Task { [weak self] in
            guard let self else { return }
            while !Task.isCancelled {
                do {
                    let response = try await self.bridge.sendAT("AT+CLCC")
                    await MainActor.run {
                        guard let entry = Self.clccEntry(from: response) else {
                            if self.localCallWasActive {
                                self.cloudCallKit.reportEnded()
                                self.localCallWasActive = false
                                self.lastIncomingNumber = nil
                                self.callState = "空闲"
                            }
                            return
                        }

                        self.localCallWasActive = true
                        if entry.direction == 1 && (entry.status == 4 || entry.status == 5) {
                            let number = entry.number.isEmpty ? "未知号码" : entry.number
                            self.callState = "来电：\(number)"
                            if self.lastIncomingNumber != number {
                                self.lastIncomingNumber = number
                                self.cloudCallKit.reportIncoming(number: number)
                            }
                        } else if entry.status == 0 {
                            self.callState = "通话中"
                            self.cloudCallKit.reportConnected()
                        } else {
                            self.callState = "呼叫中"
                        }
                    }
                } catch { }
                try? await Task.sleep(nanoseconds: 2_000_000_000)
            }
        }
    }

    private func sendLocalAT(_ command: String) async throws -> String {
        do { return try await bridge.sendAT(command) }
        catch {
            _ = try await bridge.discover()
            return try await bridge.sendAT(command)
        }
    }

    private static func clccEntry(from response: String) -> (direction: Int, status: Int, number: String)? {
        guard let line = response
            .split(whereSeparator: \.isNewline)
            .first(where: { $0.trimmingCharacters(in: .whitespaces).hasPrefix("+CLCC:") }) else { return nil }
        let fields = line
            .replacingOccurrences(of: "+CLCC:", with: "")
            .split(separator: ",", omittingEmptySubsequences: false)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines).trimmingCharacters(in: CharacterSet(charactersIn: "\"")) }
        guard fields.count >= 3, let direction = Int(fields[0]), let status = Int(fields[2]) else { return nil }
        return (direction, status, fields.count > 5 ? fields[5] : "")
    }

    private func activateCallAudio() {
        let audio = AVAudioSession.sharedInstance()
        do {
            try audio.setCategory(.playAndRecord, mode: .voiceChat, options: [.allowBluetoothHFP, .allowBluetoothA2DP])
            if let usb = audio.availableInputs?.first(where: { $0.portType == .usbAudio }) {
                try audio.setPreferredInput(usb)
            }
            try audio.setActive(true)
        } catch {
            bridgeDetail = "通话控制已发送，但 USB 音频路由失败：\(error.localizedDescription)"
        }
    }

    private func update(_ path: NWPath) {
        pathIsSatisfied = path.status == .satisfied
        isConnected = pathIsSatisfied || internetCheckSucceeded
        interfaceName = Self.interfaceName(for: path)
        if !isConnected {
            status = "未连接"
            isOnline = false
        }
    }

    private static func modemModel(from response: String?) -> String {
        guard let response else { return "未读取" }
        let lines = usefulLines(response)
        return lines.first(where: { $0.localizedCaseInsensitiveContains("qdc507") || $0.localizedCaseInsensitiveContains("ec25") || $0.localizedCaseInsensitiveContains("model") }) ?? lines.first ?? "未读取"
    }

    private static func operatorName(from response: String?) -> String {
        guard let response else { return "未读取" }
        if let quoted = response.split(separator: "\"").dropFirst().first, !quoted.isEmpty {
            return String(quoted)
        }
        return usefulLines(response).first ?? "未读取"
    }

    private static func signalText(from response: String?) -> String {
        guard let response else { return "未读取" }
        guard let line = usefulLines(response).first,
              let value = line.split(whereSeparator: { !$0.isNumber }).first,
              !value.isEmpty else { return "未读取" }
        return "\(value)/31"
    }

    private static func usefulLines(_ response: String) -> [String] {
        response
            .split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty && $0 != "OK" && $0 != "ERROR" && !$0.hasPrefix("AT") }
    }

    private static func interfaceName(for path: NWPath) -> String {
        if path.usesInterfaceType(.wiredEthernet) { return "USB 以太网" }
        if path.usesInterfaceType(.wifi) { return "Wi‑Fi" }
        if path.usesInterfaceType(.cellular) { return "蜂窝网络" }
        if path.usesInterfaceType(.loopback) { return "本机回环" }
        return "其他网络"
    }
}

struct ContentView: View {
    @EnvironmentObject private var model: NetworkModel

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    statusCard
                    Button {
                        model.checkInternet()
                    } label: {
                        Label("测试互联网", systemImage: "network")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)

                    VStack(alignment: .leading, spacing: 12) {
                        Label("当前连接", systemImage: "cable.connector")
                            .font(.headline)
                        infoRow("接口", model.interfaceName)
                        infoRow("状态", model.isConnected ? "系统已连接" : "未连接")
                        infoRow("互联网", model.isOnline ? "可访问" : "尚未测试")
                        infoRow("型号", model.modemModel)
                        infoRow("运营商", model.operatorName)
                        infoRow("信号强度", model.signalText)
                    }
                    .padding()
                    .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 16))

                    VStack(alignment: .leading, spacing: 12) {
                        Label("网络开关", systemImage: "power")
                            .font(.headline)
                        HStack {
                            Text("USB 以太网")
                            Spacer()
                            Text("由 iPadOS 管理")
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                        }
                        Text("普通 App 不能直接启停系统 Ethernet。请在“设置 → 以太网 → Baiwangd”中操作。")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                    .padding()
                    .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 16))

                    callCard
                    smsCard

                    Text("IG830 已由 iPadOS 识别为 USB 以太网。运营商和信号强度需要 IG830 提供 AT 或局域网管理协议，目前系统网络接口不包含这些信息。")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
                .padding()
            }
            .navigationTitle("DJI 4G Connect")
            .task {
                model.checkInternet()
                model.discoverModuleControl()
            }
        }
    }

    private var callCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label("电话", systemImage: "phone")
                .font(.headline)
            HStack {
                TextField("电话号码", text: $model.phoneNumber)
                    .textFieldStyle(.roundedBorder)
                    .keyboardType(.phonePad)
                Button("拨号") { model.dial() }
                    .buttonStyle(.borderedProminent)
            }
            HStack {
                Button("接听") { model.answer() }
                    .buttonStyle(.bordered)
                Button("挂断") { model.hangup() }
                    .buttonStyle(.bordered)
                Spacer()
                Text(model.callState)
                    .font(.subheadline.weight(.medium))
            }
            Divider()
            infoRow("AT通道", model.bridgeStatus)
            if !model.bridgeDetail.isEmpty {
                Text(model.bridgeDetail)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            Text("Mac Catalyst 版本会先弹出系统 CallKit 通话界面。填写云端配置时走云端电话；未填写时直接通过 AT 桥接控制模块。两种模式都需要真实的语音媒体通道，CallKit 本身不会生成通话声音。")
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
        .padding()
        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 16))
    }

    private var smsCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label("云端短信", systemImage: "message")
                .font(.headline)
            TextField("云服务器地址，例如 https://example.com", text: $model.cloudBaseURL)
                .textFieldStyle(.roundedBorder)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
            TextField("设备 ID", text: $model.cloudDeviceID)
                .textFieldStyle(.roundedBorder)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
            SecureField("访问令牌", text: $model.cloudToken)
                .textFieldStyle(.roundedBorder)
            HStack {
                Button("保存配置") { model.saveCloudSettings() }
                Button("同步短信") { model.syncSMS() }
            }
            Divider()
            ForEach(model.smsMessages) { message in
                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        Text(message.direction == "incoming" ? "收到" : "发送")
                            .font(.caption.weight(.semibold))
                        Text(message.number).font(.subheadline)
                        Spacer()
                        Text(message.date).font(.caption).foregroundStyle(.secondary)
                    }
                    Text(message.body)
                        .font(.body)
                }
                Divider()
            }
            TextField("收件号码", text: $model.smsRecipient)
                .textFieldStyle(.roundedBorder)
                .keyboardType(.phonePad)
            TextField("短信内容", text: $model.smsBody, axis: .vertical)
                .textFieldStyle(.roundedBorder)
                .lineLimit(2...5)
            Button("排队发送短信") { model.queueSMS() }
                .buttonStyle(.borderedProminent)
            Text(model.smsStatus)
                .font(.footnote)
                .foregroundStyle(.secondary)
            Text("当前版本只完成云端保存和命令排队；iPhone 端 AT/USB 权限接通后，才会真正写入 QDC507。")
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
        .padding()
        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 16))
    }

    private var statusCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            Image(systemName: model.isOnline ? "checkmark.circle.fill" : "antenna.radiowaves.left.and.right")
                .font(.system(size: 42))
                .foregroundStyle(model.isOnline ? .green : .accentColor)
            Text(model.status)
                .font(.title2.weight(.semibold))
            Text(model.interfaceName)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(22)
        .background(
            (model.isOnline ? Color.green : Color.accentColor).opacity(0.12),
            in: RoundedRectangle(cornerRadius: 20)
        )
    }

    private func infoRow(_ label: String, _ value: String) -> some View {
        HStack {
            Text(label).foregroundStyle(.secondary)
            Spacer()
            Text(value).fontWeight(.medium)
        }
    }
}

private struct ModemBridgeEndpoint: CustomStringConvertible {
    enum Transport { case http, tcp }

    let ip: String
    let port: Int
    let transport: Transport

    var description: String {
        switch transport {
        case .http: return "HTTP AT 桥接 \(ip):\(port)"
        case .tcp: return "TCP AT 通道 \(ip):\(port)"
        }
    }
}

private final class ModemBridgeClient {
    private let gatewayIPs = ["192.168.225.1", "192.168.42.129", "192.168.43.1"]
    private let httpPorts = [80, 8080, 7575]
    private let tcpPorts = [7575, 23, 5555, 8080]
    private let session: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 3
        configuration.timeoutIntervalForResource = 5
        return URLSession(configuration: configuration)
    }()
    private var endpoint: ModemBridgeEndpoint?

    func discover() async throws -> ModemBridgeEndpoint {
        for ip in gatewayIPs {
            for port in httpPorts where await probeHTTP(ip: ip, port: port) {
                let found = ModemBridgeEndpoint(ip: ip, port: port, transport: .http)
                endpoint = found
                return found
            }
        }
        for ip in gatewayIPs {
            for port in tcpPorts where await probeTCP(ip: ip, port: port) {
                let found = ModemBridgeEndpoint(ip: ip, port: port, transport: .tcp)
                endpoint = found
                return found
            }
        }
        throw BridgeError.notFound
    }

    func sendAT(_ command: String) async throws -> String {
        guard let endpoint else { throw BridgeError.notFound }
        switch endpoint.transport {
        case .http:
            return try await sendHTTP(endpoint: endpoint, command: command)
        case .tcp:
            return try await sendTCP(endpoint: endpoint, command: command)
        }
    }

    private func probeHTTP(ip: String, port: Int) async -> Bool {
        guard let url = URL(string: "http://\(ip):\(port)/api/status") else { return false }
        do {
            let (_, response) = try await session.data(from: url)
            return (response as? HTTPURLResponse)?.statusCode == 200
        } catch { return false }
    }

    private func sendHTTP(endpoint: ModemBridgeEndpoint, command: String) async throws -> String {
        guard let url = URL(string: "http://\(endpoint.ip):\(endpoint.port)/api/at") else {
            throw BridgeError.invalidURL
        }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = 8
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: [
            "command": command,
            "timeoutMs": 5000
        ])
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            throw BridgeError.invalidResponse
        }
        if let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            if let ok = object["Ok"] as? Bool, ok {
                return object["Data"] as? String ?? ""
            }
            if let error = object["Error"] as? String, !error.isEmpty {
                throw BridgeError.server(error)
            }
        }
        return String(data: data, encoding: .utf8) ?? ""
    }

    private func probeTCP(ip: String, port: Int) async -> Bool {
        await withCheckedContinuation { continuation in
            let connection = NWConnection(host: NWEndpoint.Host(ip), port: NWEndpoint.Port(rawValue: UInt16(port))!, using: .tcp)
            let once = Once()
            connection.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    if once.claim() { continuation.resume(returning: true) }
                    connection.cancel()
                case .failed, .cancelled:
                    if once.claim() { continuation.resume(returning: false) }
                default: break
                }
            }
            connection.start(queue: .global(qos: .utility))
            DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 1.5) {
                if once.claim() { connection.cancel(); continuation.resume(returning: false) }
            }
        }
    }

    private func sendTCP(endpoint: ModemBridgeEndpoint, command: String) async throws -> String {
        try await withCheckedThrowingContinuation { continuation in
            let connection = NWConnection(host: NWEndpoint.Host(endpoint.ip), port: NWEndpoint.Port(rawValue: UInt16(endpoint.port))!, using: .tcp)
            var buffer = Data()
            let once = Once()
            func finish(_ result: Result<String, Error>) {
                guard once.claim() else { return }
                connection.cancel()
                continuation.resume(with: result)
            }
            func receive() {
                connection.receive(minimumIncompleteLength: 1, maximumLength: 8192) { data, _, isComplete, error in
                    if let data { buffer.append(data) }
                    let text = String(data: buffer, encoding: .utf8) ?? ""
                    if text.contains("\nOK") || text.hasSuffix("OK") || text.contains("ERROR") {
                        finish(.success(text))
                    } else if let error {
                        finish(.failure(error))
                    } else if isComplete {
                        finish(.success(text))
                    } else {
                        receive()
                    }
                }
            }
            connection.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    connection.send(content: Data((command + "\r").utf8), completion: .contentProcessed { error in
                        if let error { finish(.failure(error)) } else { receive() }
                    })
                case .failed(let error): finish(.failure(error))
                case .cancelled: finish(.failure(BridgeError.connectionClosed))
                default: break
                }
            }
            connection.start(queue: .global(qos: .utility))
            DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 8) {
                finish(.failure(BridgeError.timeout))
            }
        }
    }

    private final class Once: @unchecked Sendable {
        private let lock = NSLock()
        private var completed = false

        func claim() -> Bool {
            lock.lock()
            defer { lock.unlock() }
            guard !completed else { return false }
            completed = true
            return true
        }
    }

    private enum BridgeError: LocalizedError {
        case notFound, invalidURL, invalidResponse, connectionClosed, timeout, server(String)

        var errorDescription: String? {
            switch self {
            case .notFound: return "未发现 AT 桥接服务"
            case .invalidURL: return "模块地址无效"
            case .invalidResponse: return "模块响应无效"
            case .connectionClosed: return "TCP 通道已关闭"
            case .timeout: return "AT 命令超时"
            case .server(let message): return message
            }
        }
    }
}
