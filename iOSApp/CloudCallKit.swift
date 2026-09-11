import AVFoundation
import CallKit
import Foundation
import PushKit

struct CloudCallSession: Codable {
    let id: String
    let status: String
    let mediaURL: String?
}

final class CloudCallClient {
    private let session: URLSession

    init() {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 8
        configuration.timeoutIntervalForResource = 12
        session = URLSession(configuration: configuration)
    }

    func startCall(baseURL: String, token: String, deviceID: String, number: String) async throws -> CloudCallSession {
        var request = try makeRequest(baseURL: baseURL, token: token, deviceID: deviceID, suffix: "/calls", method: "POST")
        request.httpBody = try JSONEncoder().encode(["number": number])
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let (data, response) = try await session.data(for: request)
        try validate(response)
        return try JSONDecoder().decode(CloudCallSession.self, from: data)
    }

    func endCall(baseURL: String, token: String, deviceID: String, callID: String) async throws {
        let request = try makeRequest(baseURL: baseURL, token: token, deviceID: deviceID, suffix: "/calls/\(callID)", method: "DELETE")
        let (_, response) = try await session.data(for: request)
        try validate(response)
    }

    func fetchCall(baseURL: String, token: String, deviceID: String, callID: String) async throws -> CloudCallSession {
        let request = try makeRequest(baseURL: baseURL, token: token, deviceID: deviceID, suffix: "/calls/\(callID)", method: "GET")
        let (data, response) = try await session.data(for: request)
        try validate(response)
        return try JSONDecoder().decode(CloudCallSession.self, from: data)
    }

    func updateCall(baseURL: String, token: String, deviceID: String, callID: String, status: String, mediaURL: String? = nil) async throws {
        var request = try makeRequest(baseURL: baseURL, token: token, deviceID: deviceID, suffix: "/calls/\(callID)/events", method: "POST")
        var payload = ["status": status]
        if let mediaURL { payload["mediaURL"] = mediaURL }
        request.httpBody = try JSONEncoder().encode(payload)
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let (_, response) = try await session.data(for: request)
        try validate(response)
    }

    private func makeRequest(baseURL: String, token: String, deviceID: String, suffix: String, method: String) throws -> URLRequest {
        guard let base = URL(string: baseURL.trimmingCharacters(in: .whitespacesAndNewlines).trimmingCharacters(in: CharacterSet(charactersIn: "/"))),
              let encodedDeviceID = deviceID.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed),
              var components = URLComponents(url: base, resolvingAgainstBaseURL: false) else {
            throw CloudCallError.invalidConfiguration
        }
        let basePath = components.path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        components.path = "/\(basePath.isEmpty ? "" : "\(basePath)/")api/v1/devices/\(encodedDeviceID)\(suffix)"
        guard let url = components.url else { throw CloudCallError.invalidConfiguration }
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        return request
    }

    private func validate(_ response: URLResponse) throws {
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw CloudCallError.serverRejected((response as? HTTPURLResponse)?.statusCode ?? 0)
        }
    }
}

enum CloudCallError: LocalizedError {
    case invalidConfiguration
    case serverRejected(Int)

    var errorDescription: String? {
        switch self {
        case .invalidConfiguration:
            return "请先填写云服务器地址、设备 ID 和访问令牌"
        case .serverRejected(let statusCode):
            return "云端拨号被拒绝（HTTP \(statusCode)）"
        }
    }
}

final class CloudCallKitManager: NSObject, ObservableObject, CXProviderDelegate, PKPushRegistryDelegate {
    static let shared = CloudCallKitManager()

    @Published private(set) var status = "未配置"
    var onStateChange: ((String) -> Void)?

    private let provider: CXProvider
    private let controller = CXCallController()
    private let pushRegistry: PKPushRegistry
    private let client = CloudCallClient()
    private var configs: [UUID: CallConfig] = [:]
    private var serverCallIDs: [UUID: String] = [:]
    private var pollTasks: [UUID: Task<Void, Never>] = [:]
    private var defaultConfig: CallConfig?
    private var currentCall: UUID?
    private var localNumbers: [UUID: String] = [:]
    private var localStart: ((String) async throws -> Void)?
    private var localAnswer: (() async throws -> Void)?
    private var localEnd: (() async throws -> Void)?
    private var currentCallConnected = false
    private var currentCallIsIncoming = false

    private override init() {
        let configuration = CXProviderConfiguration()
        configuration.supportedHandleTypes = [.phoneNumber]
        configuration.maximumCallsPerCallGroup = 1
        configuration.maximumCallGroups = 1
        configuration.includesCallsInRecents = true
        provider = CXProvider(configuration: configuration)
        pushRegistry = PKPushRegistry(queue: nil)
        super.init()
        provider.setDelegate(self, queue: nil)
        pushRegistry.delegate = self
        pushRegistry.desiredPushTypes = [.voIP]
    }

    func configure(baseURL: String, token: String, deviceID: String) {
        defaultConfig = CallConfig(baseURL: baseURL, token: token, deviceID: deviceID, number: "")
    }

    func configureLocal(
        start: @escaping (String) async throws -> Void,
        answer: @escaping () async throws -> Void,
        end: @escaping () async throws -> Void
    ) {
        localStart = start
        localAnswer = answer
        localEnd = end
    }

    func startOutgoing(number: String, baseURL: String, token: String, deviceID: String) {
        let uuid = UUID()
        configs[uuid] = CallConfig(baseURL: baseURL, token: token, deviceID: deviceID, number: number)
        requestOutgoing(number: number, uuid: uuid)
    }

    func startOutgoing(number: String) {
        let uuid = UUID()
        localNumbers[uuid] = number
        requestOutgoing(number: number, uuid: uuid)
    }

    private func requestOutgoing(number: String, uuid: UUID) {
        currentCall = uuid
        currentCallConnected = false
        currentCallIsIncoming = false
        setStatus("请求系统电话界面")
        let action = CXStartCallAction(call: uuid, handle: CXHandle(type: .phoneNumber, value: number))
        controller.request(CXTransaction(action: action)) { [weak self] error in
            if let error {
                self?.setStatus("CallKit 请求失败：\(error.localizedDescription)")
            }
        }
    }

    func reportIncoming(number: String, uuid: UUID = UUID(), serverCallID: String? = nil) {
        currentCall = uuid
        currentCallConnected = false
        currentCallIsIncoming = true
        if let config = defaultConfig { configs[uuid] = CallConfig(baseURL: config.baseURL, token: config.token, deviceID: config.deviceID, number: number) }
        if let serverCallID { serverCallIDs[uuid] = serverCallID }
        let update = CXCallUpdate()
        update.remoteHandle = CXHandle(type: .phoneNumber, value: number)
        update.hasVideo = false
        provider.reportNewIncomingCall(with: uuid, update: update) { [weak self] error in
            if let error {
                self?.setStatus("来电上报失败：\(error.localizedDescription)")
            } else {
                self?.setStatus("云端来电")
            }
        }
    }

    func endCurrentCall() {
        guard let uuid = currentCall else { return }
        controller.request(CXTransaction(action: CXEndCallAction(call: uuid))) { [weak self] error in
            if let error {
                self?.setStatus("挂断失败：\(error.localizedDescription)")
            }
        }
    }

    func answerCurrentCall() {
        guard let uuid = currentCall else {
            setStatus("当前没有云端来电")
            return
        }
        controller.request(CXTransaction(action: CXAnswerCallAction(call: uuid))) { [weak self] error in
            if let error {
                self?.setStatus("接听失败：\(error.localizedDescription)")
            }
        }
    }

    func providerDidReset(_ provider: CXProvider) {
        pollTasks.values.forEach { $0.cancel() }
        pollTasks.removeAll()
        configs.removeAll()
        serverCallIDs.removeAll()
        localNumbers.removeAll()
        currentCall = nil
        currentCallConnected = false
        currentCallIsIncoming = false
        setStatus("空闲")
    }

    func reportConnected() {
        guard let uuid = currentCall else { return }
        guard !currentCallConnected else { return }
        currentCallConnected = true
        if !currentCallIsIncoming {
            provider.reportOutgoingCall(with: uuid, connectedAt: Date())
        }
        setStatus("通话中")
    }

    func reportEnded(reason: CXCallEndedReason = .remoteEnded) {
        guard let uuid = currentCall else { return }
        provider.reportCall(with: uuid, endedAt: Date(), reason: reason)
        currentCall = nil
        currentCallConnected = false
        currentCallIsIncoming = false
        localNumbers[uuid] = nil
        setStatus("空闲")
    }

    func provider(_ provider: CXProvider, perform action: CXStartCallAction) {
        if let config = configs[action.callUUID] {
            setStatus("连接云端电话")
            Task {
                do {
                    let call = try await client.startCall(baseURL: config.baseURL, token: config.token, deviceID: config.deviceID, number: config.number)
                    serverCallIDs[action.callUUID] = call.id
                    action.fulfill()
                    provider.reportOutgoingCall(with: action.callUUID, startedConnectingAt: Date())
                    setStatus(call.status == "pending_backend" ? "云端等待语音后端" : "呼叫中")
                    startPolling(uuid: action.callUUID, config: config, callID: call.id)
                } catch {
                    action.fail()
                    setStatus("云端拨号失败：\(error.localizedDescription)")
                }
            }
            return
        }

        guard let number = localNumbers[action.callUUID], let localStart else {
            action.fail()
            setStatus("没有找到本地模块通话配置")
            return
        }

        setStatus("连接 DJI 模块")
        Task {
            do {
                try await localStart(number)
                action.fulfill()
                provider.reportOutgoingCall(with: action.callUUID, startedConnectingAt: Date())
                configureAudioSession()
                setStatus("模块呼叫中")
            } catch {
                action.fail()
                setStatus("模块拨号失败：\(error.localizedDescription)")
            }
        }
    }

    func provider(_ provider: CXProvider, perform action: CXAnswerCallAction) {
        if let config = configs[action.callUUID], let callID = serverCallIDs[action.callUUID] {
            Task { try? await client.updateCall(baseURL: config.baseURL, token: config.token, deviceID: config.deviceID, callID: callID, status: "ringing") }
            configureAudioSession()
            action.fulfill()
            setStatus("接听中；等待云端语音")
            return
        }

        if let localAnswer {
            Task {
                do {
                    try await localAnswer()
                    configureAudioSession()
                    action.fulfill()
                    setStatus("模块接听中")
                } catch {
                    action.fail()
                    setStatus("模块接听失败：\(error.localizedDescription)")
                }
            }
            return
        }

        action.fail()
        setStatus("没有找到接听配置")
    }

    func provider(_ provider: CXProvider, perform action: CXEndCallAction) {
        if configs[action.callUUID] == nil, let localEnd {
            Task {
                try? await localEnd()
                localNumbers[action.callUUID] = nil
                currentCall = nil
                currentCallConnected = false
                currentCallIsIncoming = false
                try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
                action.fulfill()
                setStatus("空闲")
            }
            return
        }

        let config = configs[action.callUUID]
        let serverCallID = serverCallIDs[action.callUUID]
        pollTasks[action.callUUID]?.cancel()
        pollTasks[action.callUUID] = nil
        if let config, let serverCallID {
            Task { try? await client.endCall(baseURL: config.baseURL, token: config.token, deviceID: config.deviceID, callID: serverCallID) }
        }
        configs[action.callUUID] = nil
        serverCallIDs[action.callUUID] = nil
        currentCall = nil
        currentCallConnected = false
        currentCallIsIncoming = false
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        action.fulfill()
        setStatus("空闲")
    }

    private func startPolling(uuid: UUID, config: CallConfig, callID: String) {
        pollTasks[uuid]?.cancel()
        pollTasks[uuid] = Task { [weak self] in
            guard let self else { return }
            for _ in 0..<30 where !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 2_000_000_000)
                guard !Task.isCancelled else { return }
                do {
                    let call = try await self.client.fetchCall(baseURL: config.baseURL, token: config.token, deviceID: config.deviceID, callID: callID)
                    if call.status == "connected" {
                        self.provider.reportOutgoingCall(with: uuid, connectedAt: Date())
                        self.setStatus("云端已连接；等待媒体适配器")
                        return
                    }
                    if call.status == "ended" || call.status == "failed" {
                        self.provider.reportCall(with: uuid, endedAt: Date(), reason: call.status == "failed" ? .failed : .remoteEnded)
                        self.setStatus(call.status == "failed" ? "云端呼叫失败" : "对方已挂断")
                        return
                    }
                } catch {
                    self.setStatus("查询云端通话状态失败")
                    return
                }
            }
            if !Task.isCancelled {
                self.provider.reportCall(with: uuid, endedAt: Date(), reason: .failed)
                self.setStatus("云端语音后端未在 60 秒内就绪")
            }
        }
    }

    func provider(_ provider: CXProvider, didActivate audioSession: AVAudioSession) {
        configureAudioSession()
    }

    func provider(_ provider: CXProvider, didDeactivate audioSession: AVAudioSession) {
        try? audioSession.setActive(false, options: .notifyOthersOnDeactivation)
    }

    func pushRegistry(_ registry: PKPushRegistry, didUpdate pushCredentials: PKPushCredentials, for type: PKPushType) {
        // The token must be uploaded to the cloud account before incoming calls can wake the app.
        setStatus("已取得 VoIP 推送令牌，请上传到云端")
    }

    func pushRegistry(_ registry: PKPushRegistry, didReceiveIncomingPushWith payload: PKPushPayload, for type: PKPushType, completion: @escaping () -> Void) {
        let values = payload.dictionaryPayload
        let number = values["number"] as? String ?? "云端电话"
        let uuid = UUID(uuidString: values["uuid"] as? String ?? "") ?? UUID()
        reportIncoming(number: number, uuid: uuid, serverCallID: values["callID"] as? String)
        completion()
    }

    private func configureAudioSession() {
        let audio = AVAudioSession.sharedInstance()
        try? audio.setCategory(.playAndRecord, mode: .voiceChat, options: [.allowBluetoothHFP, .allowBluetoothA2DP])
        try? audio.setActive(true)
    }

    private func setStatus(_ value: String) {
        DispatchQueue.main.async {
            self.status = value
            self.onStateChange?(value)
        }
    }

    private struct CallConfig {
        let baseURL: String
        let token: String
        let deviceID: String
        let number: String
    }
}
