import Foundation

struct CloudSMSMessage: Codable, Identifiable, Equatable {
    let id: String
    let direction: String
    let number: String
    let body: String
    let date: String
}

struct CloudSMSCommand: Codable, Identifiable, Equatable {
    let id: String
    let type: String
    let to: String
    let body: String
}

final class CloudSMSClient {
    private let session: URLSession

    init() {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 8
        configuration.timeoutIntervalForResource = 12
        session = URLSession(configuration: configuration)
    }

    func fetchMessages(baseURL: String, token: String, deviceID: String) async throws -> [CloudSMSMessage] {
        let request = try makeRequest(baseURL: baseURL, token: token, deviceID: deviceID, suffix: "/messages", method: "GET")
        let (data, response) = try await session.data(for: request)
        try validate(response)
        return try JSONDecoder().decode(MessageEnvelope.self, from: data).messages
    }

    func uploadMessage(baseURL: String, token: String, deviceID: String, message: CloudSMSMessage) async throws {
        var request = try makeRequest(baseURL: baseURL, token: token, deviceID: deviceID, suffix: "/messages", method: "POST")
        request.httpBody = try JSONEncoder().encode(message)
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let (_, response) = try await session.data(for: request)
        try validate(response)
    }

    func enqueueSMS(baseURL: String, token: String, deviceID: String, to: String, body: String) async throws -> String {
        var request = try makeRequest(baseURL: baseURL, token: token, deviceID: deviceID, suffix: "/commands", method: "POST")
        request.httpBody = try JSONEncoder().encode(["type": "send_sms", "to": to, "body": body])
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let (data, response) = try await session.data(for: request)
        try validate(response)
        return try JSONDecoder().decode(CommandEnvelope.self, from: data).id
    }

    private func makeRequest(baseURL: String, token: String, deviceID: String, suffix: String, method: String) throws -> URLRequest {
        guard let base = URL(string: baseURL.trimmingCharacters(in: .whitespacesAndNewlines).trimmingCharacters(in: CharacterSet(charactersIn: "/"))),
              !deviceID.isEmpty,
              let encodedDeviceID = deviceID.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed),
              var components = URLComponents(url: base, resolvingAgainstBaseURL: false) else {
            throw CloudSMSError.invalidConfiguration
        }
        let basePath = components.path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        components.path = "/\(basePath.isEmpty ? "" : "\(basePath)/")api/v1/devices/\(encodedDeviceID)\(suffix)"
        guard let url = components.url else { throw CloudSMSError.invalidConfiguration }
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        return request
    }

    private func validate(_ response: URLResponse) throws {
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw CloudSMSError.serverRejected
        }
    }

    private struct MessageEnvelope: Codable { let messages: [CloudSMSMessage] }
    private struct CommandEnvelope: Codable { let id: String }
}

enum CloudSMSError: LocalizedError {
    case invalidConfiguration
    case serverRejected

    var errorDescription: String? {
        switch self {
        case .invalidConfiguration: return "请先填写云服务器地址、设备 ID 和访问令牌"
        case .serverRejected: return "云端请求失败，请检查地址、令牌和服务日志"
        }
    }
}
