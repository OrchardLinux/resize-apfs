import Foundation
import Darwin
import ResizeCore
import ResizeDevice
import NativeSystem

final class HelperServer: @unchecked Sendable {
    let engine: DeviceEngine
    let socketFD: Int32
    let lockFD: Int32
    let token: String
    let mobileUID: uid_t
    let mobileGID: gid_t
    let ipcDirectory: URL
    let expectedUIPath: String
    let clients = DispatchSemaphore(value: 8)

    init(source: DeviceSource, stateDirectory: URL, ipcDirectory: URL, executable: String) throws {
        #if os(iOS)
        guard geteuid() == 0, !source.isFixture else { throw ResizeError("The device helper must run as root and cannot use fixture mode.") }
        mobileUID = getpwnam("mobile")?.pointee.pw_uid ?? 501
        mobileGID = getpwnam("mobile")?.pointee.pw_gid ?? 501
        #else
        guard source.isFixture else { throw ResizeError("Host execution requires an explicit regular-file --fixture. Host disks are never opened.") }
        mobileUID = geteuid(); mobileGID = getegid()
        #endif
        self.ipcDirectory = ipcDirectory
        expectedUIPath = URL(fileURLWithPath: "/cores/binpack/Applications/palera1nLoader.app/ResizeAPFS").resolvingSymlinksInPath().path
        try FileManager.default.createDirectory(at: stateDirectory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        lockFD = open(stateDirectory.appendingPathComponent("helper.lock").path, O_RDWR | O_CREAT | O_CLOEXEC | O_NOFOLLOW, 0o600)
        guard lockFD >= 0, flock(lockFD, LOCK_EX | LOCK_NB) == 0 else { throw ResizeError("Another helper owns the operation journal.") }
        engine = try DeviceEngine(source: source, directory: stateDirectory, executable: executable)
        try FileManager.default.createDirectory(at: ipcDirectory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        var directoryInfo = stat()
        guard lstat(ipcDirectory.path, &directoryInfo) == 0,
              directoryInfo.st_mode & S_IFMT == S_IFDIR,
              directoryInfo.st_uid == geteuid(),
              chown(ipcDirectory.path, geteuid(), mobileGID) == 0,
              chmod(ipcDirectory.path, 0o750) == 0 else { throw ResizeError("Cannot protect the root-owned local IPC directory.") }
        var bytes = [UInt8](repeating: 0, count: 32)
        arc4random_buf(&bytes, bytes.count)
        token = bytes.map { String(format: "%02x", $0) }.joined()
        let credentials = ipcDirectory.appendingPathComponent("client.token")
        try Data(token.utf8).write(to: credentials, options: .atomic)
        guard chmod(credentials.path, 0o640) == 0, chown(credentials.path, geteuid(), mobileGID) == 0 else { throw ResizeError("Cannot protect local IPC credentials.") }
        let path = ipcDirectory.appendingPathComponent("helper.sock").path
        unlink(path)
        socketFD = socket(AF_UNIX, SOCK_STREAM, 0)
        if socketFD >= 0 { _ = fcntl(socketFD, F_SETFD, FD_CLOEXEC) }
        guard socketFD >= 0 else { throw ResizeError("Cannot create local IPC socket.") }
        var address = try LocalFrames.address(path)
        let result = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(socketFD, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
        }
        guard result == 0, chmod(path, 0o660) == 0, chown(path, geteuid(), mobileGID) == 0,
              listen(socketFD, 8) == 0 else { throw ResizeError("Cannot publish the protected local helper socket.") }
    }

    func run() {
        Task {
            while !Task.isCancelled {
                await engine.refresh()
                try? await Task.sleep(nanoseconds: 5_000_000_000)
            }
        }
        while true {
            clients.wait()
            let fd = accept(socketFD, nil, nil)
            if fd < 0 { clients.signal(); if errno == EINTR { continue }; break }
            _ = fcntl(fd, F_SETFD, FD_CLOEXEC)
            DispatchQueue.global(qos: .userInitiated).async { [self] in
                defer { close(fd); clients.signal() }
                do {
                    try LocalFrames.configure(fd)
                    var uid: uid_t = 0
                    guard raf_peer_uid(fd, &uid) == 0, uid == mobileUID || uid == 0 else { throw ResizeError("Local caller identity is not permitted.") }
                    #if os(iOS)
                    guard uid == 0 || raf_peer_is_executable(fd, expectedUIPath) == 1 else {
                        throw ResizeError("Only the Resize APFS app from the read-only overlay may use this helper.")
                    }
                    #endif
                    // Authenticate the peer executable once per connection. Reuse
                    // the established socket so heartbeats need no filesystem
                    // pathname lookup while APFS is freezing filesystem I/O.
                    while true {
                    let request = try JSONDecoder().decode(LocalRPCRequest.self, from: LocalFrames.read(from: fd))
                    guard constantTimeEqual(request.token, token) else { throw ResizeError("Invalid local helper credentials.") }
                    let semaphore = DispatchSemaphore(value: 0)
                    // The response may be delayed by initial inspection. The client
                    // times out without resubmitting mutations; state lives here.
                    Task {
                        let response: LocalRPCResponse
                        do {
                            let encoder = JSONEncoder(), decoder = JSONDecoder()
                            let body: Data
                            switch request.method {
                            case "snapshot": body = try encoder.encode(await engine.snapshot())
                            case "plan":
                                guard let data = request.body else { throw ResizeError("Missing review request.") }
                                body = try encoder.encode(await engine.plan(decoder.decode(PlanRequest.self, from: data)))
                            case "start":
                                guard let data = request.body else { throw ResizeError("Missing start request.") }
                                body = try encoder.encode(await engine.start(decoder.decode(StartRequest.self, from: data)))
                            default: throw ResizeError("Unsupported operation. No shell or arbitrary-file API is exposed.")
                            }
                            response = LocalRPCResponse(body: body)
                        } catch { response = LocalRPCResponse(error: ResizeError(error.localizedDescription)) }
                        try? LocalFrames.write(JSONEncoder().encode(response), to: fd)
                        semaphore.signal()
                    }
                    semaphore.wait()
                    }
                } catch { try? LocalFrames.write(JSONEncoder().encode(LocalRPCResponse(error: ResizeError(error.localizedDescription))), to: fd) }
            }
        }
    }
    private func constantTimeEqual(_ lhs: String, _ rhs: String) -> Bool {
        let a = Array(lhs.utf8), b = Array(rhs.utf8)
        guard a.count == b.count else { return false }
        return zip(a, b).reduce(UInt8(0)) { $0 | ($1.0 ^ $1.1) } == 0
    }
}

func argument(_ name: String) -> String? {
    let args = CommandLine.arguments
    return args.firstIndex(of: name).flatMap { $0 + 1 < args.count ? args[$0 + 1] : nil }
}
signal(SIGPIPE, SIG_IGN)
do {
    if let job = argument("--worker") {
        guard let gate = argument("--gate-fd").flatMap(Int32.init), raf_wait_for_release(gate) == 0 else {
            throw ResizeError("Worker was not released by its supervising helper; no mutation was attempted.")
        }
        close(gate)
        try DeviceWorker.runFile(URL(fileURLWithPath: job))
        exit(0)
    }
    let fixture = argument("--fixture")
    let source = DeviceSource(path: fixture ?? "/dev/disk0", fixtureSectorSize: fixture == nil ? nil : Int64(argument("--sector-size") ?? "512"),
                              writesEnabled: CommandLine.arguments.contains("--allow-writes"))
    let server = try HelperServer(source: source,
                                  stateDirectory: URL(fileURLWithPath: argument("--state-dir") ?? "/var/root/Library/ResizeAPFS"),
                                  ipcDirectory: URL(fileURLWithPath: argument("--ipc-dir") ?? "/var/run/resize-apfs"),
                                  executable: URL(fileURLWithPath: CommandLine.arguments[0]).standardizedFileURL.path)
    print("Resize APFS helper: local IPC only; writes \(source.writesEnabled ? "enabled, subject to app authorization" : "disabled")")
    server.run()
} catch {
    fputs("Resize APFS helper stopped: \(error.localizedDescription)\n", stderr)
    exit(1)
}
