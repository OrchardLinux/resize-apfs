import Foundation
import Darwin

public struct LocalRPCRequest: Codable, Sendable {
    public var token: String
    public var method: String
    public var body: Data?
    public init(token: String, method: String, body: Data? = nil) { self.token = token; self.method = method; self.body = body }
}
public struct LocalRPCResponse: Codable, Sendable {
    public var body: Data?
    public var error: ResizeError?
    public init(body: Data? = nil, error: ResizeError? = nil) { self.body = body; self.error = error }
}

public enum LocalFrames {
    public static let limit = 1_048_576
    public static func configure(_ fd: Int32) throws {
        var timeout = timeval(tv_sec: 4, tv_usec: 0)
        var yes: Int32 = 1
        guard setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout.size(ofValue: timeout))) == 0,
              setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &timeout, socklen_t(MemoryLayout.size(ofValue: timeout))) == 0,
              setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &yes, socklen_t(MemoryLayout.size(ofValue: yes))) == 0 else {
            throw ResizeError("Cannot configure local IPC timeouts.")
        }
    }
    public static func address(_ path: String) throws -> sockaddr_un {
        var address = sockaddr_un()
        let bytes = Array(path.utf8) + [0]
        guard bytes.count <= MemoryLayout.size(ofValue: address.sun_path) else { throw ResizeError("Local socket path is too long.") }
        address.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
        address.sun_family = sa_family_t(AF_UNIX)
        withUnsafeMutableBytes(of: &address.sun_path) { $0.copyBytes(from: bytes + Array(repeating: 0, count: $0.count - bytes.count)) }
        return address
    }
    public static func write(_ data: Data, to fd: Int32) throws {
        guard data.count <= limit else { throw ResizeError("Local IPC message exceeds the limit.") }
        let size = UInt32(data.count)
        let prefix = Data([UInt8(truncatingIfNeeded: size >> 24), UInt8(truncatingIfNeeded: size >> 16), UInt8(truncatingIfNeeded: size >> 8), UInt8(truncatingIfNeeded: size)])
        try (prefix + data).withUnsafeBytes { buffer in
            var written = 0
            while written < buffer.count {
                let n = Darwin.write(fd, buffer.baseAddress!.advanced(by: written), buffer.count - written)
                if n < 0 && errno == EINTR { continue }
                guard n > 0 else { throw ResizeError("Local helper connection closed while sending.") }
                written += n
            }
        }
    }
    public static func read(from fd: Int32) throws -> Data {
        let header = try exact(4, fd: fd)
        let size = header.reduce(UInt32(0)) { ($0 << 8) | UInt32($1) }
        guard size > 0, size <= limit else { throw ResizeError("Invalid local IPC frame size.") }
        return try exact(Int(size), fd: fd)
    }
    private static func exact(_ count: Int, fd: Int32) throws -> Data {
        var data = Data(count: count)
        try data.withUnsafeMutableBytes { buffer in
            var received = 0
            while received < count {
                let n = Darwin.read(fd, buffer.baseAddress!.advanced(by: received), count - received)
                if n < 0 && errno == EINTR { continue }
                guard n > 0 else { throw ResizeError("Local helper connection closed or timed out.") }
                received += n
            }
        }
        return data
    }
}

private final class LocalSocketTransport: @unchecked Sendable {
    private let directory: URL
    private let queue = DispatchQueue(label: "resize.ipc.client", qos: .userInitiated)
    private var fd: Int32 = -1
    private var token: String?
    init(directory: URL) { self.directory = directory }
    deinit { if fd >= 0 { Darwin.close(fd) } }

    func exchange<T: Decodable & Sendable>(_ method: String, body: Data?) async throws -> T {
        try await withCheckedThrowingContinuation { continuation in
            queue.async { [self] in
                do {
                    try connectIfNeeded()
                    try LocalFrames.write(JSONEncoder().encode(LocalRPCRequest(token: token!, method: method, body: body)), to: fd)
                    let response = try JSONDecoder().decode(LocalRPCResponse.self, from: LocalFrames.read(from: fd))
                    if let error = response.error {
                        if error.message == "Invalid local helper credentials." { token = nil }
                        throw error
                    }
                    guard let payload = response.body else { throw ResizeError("The privileged helper returned an empty result.") }
                    continuation.resume(returning: try JSONDecoder().decode(T.self, from: payload))
                } catch {
                    if fd >= 0 { Darwin.close(fd); fd = -1 }
                    // Never replay a frame, especially a start request. A later
                    // snapshot may establish a fresh connection and inspect state.
                    continuation.resume(throwing: error)
                }
            }
        }
    }
    private func connectIfNeeded() throws {
        guard fd < 0 else { return }
        if token == nil {
            guard let value = try? String(contentsOf: directory.appendingPathComponent("client.token"), encoding: .utf8)
                .trimmingCharacters(in: .whitespacesAndNewlines), value.count == 64 else {
                throw ResizeError("The privileged helper has not published its local connection credentials yet.")
            }
            token = value
        }
        let socket = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
        guard socket >= 0 else { throw ResizeError("Cannot open a local helper connection.") }
        do {
            _ = fcntl(socket, F_SETFD, FD_CLOEXEC)
            try LocalFrames.configure(socket)
            var address = try LocalFrames.address(directory.appendingPathComponent("helper.sock").path)
            let connected = withUnsafePointer(to: &address) { pointer in
                pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    Darwin.connect(socket, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
                }
            }
            guard connected == 0 else { throw ResizeError("The privileged helper is not connected. Boot the custom overlay and try opening the app again.") }
            fd = socket
        } catch { Darwin.close(socket); throw error }
    }
}

public struct LocalSocketResizeService: ResizeService {
    public let directory: URL
    private let transport: LocalSocketTransport
    public init(directory: URL = URL(fileURLWithPath: "/var/run/resize-apfs")) {
        self.directory = directory
        transport = LocalSocketTransport(directory: directory)
    }
    public func snapshot() async throws -> ServiceSnapshot { try await call("snapshot", body: nil) }
    public func plan(_ request: PlanRequest) async throws -> ResizePlan { try await call("plan", body: JSONEncoder().encode(request)) }
    public func start(_ request: StartRequest) async throws -> ServiceSnapshot { try await call("start", body: JSONEncoder().encode(request)) }
    public func configureMock(_ request: ScenarioRequest) async throws -> ServiceSnapshot { throw ResizeError("Mock configuration is not available on a device.") }

    private func call<T: Decodable & Sendable>(_ method: String, body: Data?) async throws -> T {
        try await transport.exchange(method, body: body)
    }
}
