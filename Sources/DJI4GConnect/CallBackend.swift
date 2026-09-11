import AppKit
import Foundation

enum CallBackendError: LocalizedError {
    case unavailable(String)
    case request(String)

    var errorDescription: String? {
        switch self {
        case .unavailable(let message), .request(let message): return message
        }
    }
}

/// Runs DJOneHub's verified QDC507 USB/ADB call backend locally.
final class CallBackend: @unchecked Sendable {
    private let token = "dji4g-" + UUID().uuidString
    private let socketPath = NSTemporaryDirectory() + "dji4g-connect-\(getpid()).sock"
    private var process: Process?
    private var logHandle: FileHandle?
    private var terminationObserver: NSObjectProtocol?

    var isRunning: Bool {
        process?.isRunning == true && FileManager.default.fileExists(atPath: socketPath)
    }

    init() {
        terminationObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.willTerminateNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in self?.stop() }
    }

    deinit {
        if let terminationObserver { NotificationCenter.default.removeObserver(terminationObserver) }
        stop()
    }

    func start() throws {
        if isRunning { return }
        guard let executable = Bundle.main.url(forResource: "djonehubd", withExtension: nil, subdirectory: "backend") else {
            throw CallBackendError.unavailable("缺少通话后端 djonehubd")
        }
        try? FileManager.default.removeItem(atPath: socketPath)

        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("DJI4GConnect", isDirectory: true)
        try FileManager.default.createDirectory(at: support, withIntermediateDirectories: true)
        let logURL = support.appendingPathComponent("call-backend.log")
        if !FileManager.default.fileExists(atPath: logURL.path) {
            FileManager.default.createFile(atPath: logURL.path, contents: nil)
        }
        let handle = try FileHandle(forWritingTo: logURL)
        try handle.seekToEnd()

        let child = Process()
        child.executableURL = URL(fileURLWithPath: "/bin/sh")
        child.arguments = [
            "-c",
            #""$DJI_CALL_BACKEND" -listen "unix:$DJI_CALL_SOCKET" & backend_pid=$!; trap 'kill "$backend_pid" 2>/dev/null; wait "$backend_pid" 2>/dev/null' EXIT TERM INT; while kill -0 "$DJI_CALL_PARENT" 2>/dev/null && kill -0 "$backend_pid" 2>/dev/null; do sleep 1; done"#,
        ]
        var environment = ProcessInfo.processInfo.environment
        environment["DJONEHUB_APP_TOKEN"] = token
        environment["DJI_CALL_BACKEND"] = executable.path
        environment["DJI_CALL_SOCKET"] = socketPath
        environment["DJI_CALL_PARENT"] = String(getpid())
        child.environment = environment
        child.standardOutput = handle
        child.standardError = handle
        try child.run()
        process = child
        logHandle = handle

        for _ in 0..<50 {
            if isRunning { return }
            if !child.isRunning { break }
            Thread.sleep(forTimeInterval: 0.1)
        }
        stop()
        throw CallBackendError.unavailable("通话后端启动失败")
    }

    func stop() {
        if process?.isRunning == true { process?.terminate() }
        process = nil
        try? logHandle?.close()
        logHandle = nil
        try? FileManager.default.removeItem(atPath: socketPath)
    }

    func request(_ path: String, method: String = "GET", body: [String: Any]? = nil, timeout: TimeInterval = 30) throws -> [String: Any] {
        guard isRunning else { throw CallBackendError.unavailable("通话后端未运行") }
        var arguments = [
            "--silent", "--show-error", "--max-time", String(Int(timeout)),
            "--unix-socket", socketPath,
            "-H", "X-DJOneHub-App-Token: \(token)",
            "-X", method,
        ]
        if let body {
            let data = try JSONSerialization.data(withJSONObject: body)
            arguments += ["-H", "Content-Type: application/json", "--data-binary", String(decoding: data, as: UTF8.self)]
        }
        arguments.append("http://localhost/" + path.trimmingCharacters(in: CharacterSet(charactersIn: "/")))

        let output = Pipe()
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/curl")
        task.arguments = arguments
        task.standardOutput = output
        task.standardError = output
        try task.run()
        task.waitUntilExit()
        let data = output.fileHandleForReading.readDataToEndOfFile()
        guard let value = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            let message = String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
            throw CallBackendError.request(message.isEmpty ? "通话后端未返回有效数据" : message)
        }
        if task.terminationStatus != 0 || value["error"] != nil {
            throw CallBackendError.request(value["error"] as? String ?? "通话后端请求失败")
        }
        return value
    }
}

final class BackendATChannel: ATChannel {
    private let backend: CallBackend

    init(backend: CallBackend) { self.backend = backend }

    func send(_ command: String, timeout: TimeInterval) throws -> String {
        let value = try backend.request("api/at", method: "POST", body: ["command": command], timeout: max(2, timeout + 2))
        return value["response"] as? String ?? ""
    }

    func sendSMS(to recipient: String, body: String) throws -> String {
        let value = try backend.request("api/sms/send", method: "POST", body: ["phone": recipient, "message": body], timeout: 30)
        guard value["sent"] as? Bool == true else { throw CallBackendError.request("短信未发送") }
        return "OK"
    }

    func close() {}
}
