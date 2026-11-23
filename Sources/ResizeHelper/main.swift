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
    let sessionApp: Bool
    let clients = DispatchSemaphore(value: 8)

    /// `uiPath`: the checkra1n session's app executable (already validated by
    /// SessionTrust); nil serves only the palera1n overlay's app, as before.
    init(source: DeviceSource, stateDirectory: URL, ipcDirectory: URL, executable: String, uiPath: String? = nil) throws {
        #if os(iOS)
        guard geteuid() == 0, !source.isFixture else { throw ResizeError("The device helper must run as root and cannot use fixture mode.") }
        mobileUID = getpwnam("mobile")?.pointee.pw_uid ?? 501
        mobileGID = getpwnam("mobile")?.pointee.pw_gid ?? 501
        #else
        guard source.isFixture else { throw ResizeError("Host execution requires an explicit regular-file --fixture. Host disks are never opened.") }
        mobileUID = geteuid(); mobileGID = getegid()
        #endif
        self.ipcDirectory = ipcDirectory
        expectedUIPath = uiPath ?? URL(fileURLWithPath: "/cores/binpack/Applications/palera1nLoader.app/ResizeAPFS").resolvingSymlinksInPath().path
        sessionApp = uiPath != nil
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
        try Data(token.utf8).write(to: credentials, options: DeviceJournal.writing)
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
        AppOpener(executable: expectedUIPath, registerWithUICache: !sessionApp).start()
        Thread { [engine] in
            while true {
                engine.refresh()
                Thread.sleep(forTimeInterval: 5)
            }
        }.start()
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
                        throw ResizeError(sessionApp ? "Only this session's Resize APFS app may use this helper."
                                                     : "Only the Resize APFS app from the read-only overlay may use this helper.")
                    }
                    #endif
                    // Authenticate the peer executable once per connection. Reuse
                    // the established socket so heartbeats need no filesystem
                    // pathname lookup while APFS is freezing filesystem I/O.
                    while true {
                    let request = try JSONDecoder().decode(LocalRPCRequest.self, from: LocalFrames.read(from: fd))
                    guard constantTimeEqual(request.token, token) else { throw ResizeError("Invalid local helper credentials.") }
                    // The response may be delayed by initial inspection. The client
                    // times out without resubmitting mutations; state lives here.
                    // The engine releases its lock during disk reads, so a slow
                    // request on one connection never stalls status on another.
                    let response: LocalRPCResponse
                    do {
                        let encoder = JSONEncoder(), decoder = JSONDecoder()
                        let body: Data
                        switch request.method {
                        case "snapshot": body = try encoder.encode(engine.snapshot())
                        case "plan":
                            guard let data = request.body else { throw ResizeError("Missing review request.") }
                            body = try encoder.encode(engine.plan(decoder.decode(PlanRequest.self, from: data)))
                        case "start":
                            guard let data = request.body else { throw ResizeError("Missing start request.") }
                            body = try encoder.encode(engine.start(decoder.decode(StartRequest.self, from: data)))
                        case "removeSnapshot", "takeSnapshot":
                            guard let data = request.body else { throw ResizeError("Missing snapshot request.") }
                            let snapshotRequest = try decoder.decode(SnapshotRequest.self, from: data)
                            body = try encoder.encode(request.method == "removeSnapshot" ? engine.removeSnapshot(snapshotRequest) : engine.takeSnapshot(snapshotRequest))
                        default: throw ResizeError("Unsupported operation. No shell or arbitrary-file API is exposed.")
                        }
                        response = LocalRPCResponse(body: body)
                    } catch { response = LocalRPCResponse(error: ResizeError(error.localizedDescription)) }
                    try? LocalFrames.write(JSONEncoder().encode(response), to: fd)
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

#if os(iOS)
let isDevice = true
#else
let isDevice = false
#endif
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
    let stateDirectory = URL(fileURLWithPath: argument("--state-dir") ?? "/var/root/Library/ResizeAPFS")
    // iOS 12-14 session commands (scripts/checkra1n_route.py, Device/README.md).
    if let app = argument("--register-app") {
        try AppRegistration.register(app)
        exit(0)
    }
    if let app = argument("--unregister-app") {
        try AppRegistration.unregister(app)
        exit(0)
    }
    // Testing only, not part of a route: ask the kernel to read disk0's GPT again and
    // report the partition's size before and after. Changes nothing on disk.
    if let partition = argument("--reprobe") {
        exit(PartitionReprobe.attempt(partition: partition, target: nil, journal: stateDirectory) == nil ? 2 : 0)
    }
    if CommandLine.arguments.contains("--operation-active") {
        exit(DeviceEngine.operationActive(directory: stateDirectory) ? 0 : 1)
    }
    let session = CommandLine.arguments.contains("--session")
    let uiPath = argument("--ui-path")
    guard session == (uiPath != nil) || !isDevice else {
        throw ResizeError("--session and --ui-path belong together: a session serves exactly the app it names.")
    }
    let fixture = argument("--fixture")
    // Nothing the helper serves works before the first unlock: its journal (if an
    // earlier helper wrote it with class C), its token and the app all need it.
    if isDevice && fixture == nil { FirstUnlock.wait() }
    let source = DeviceSource(path: fixture ?? "/dev/disk0", fixtureSectorSize: fixture == nil ? nil : Int64(argument("--sector-size") ?? "512"),
                              writesEnabled: CommandLine.arguments.contains("--allow-writes"))
    let server = try HelperServer(source: source,
                                  stateDirectory: stateDirectory,
                                  ipcDirectory: URL(fileURLWithPath: argument("--ipc-dir") ?? "/var/run/resize-apfs"),
                                  executable: URL(fileURLWithPath: CommandLine.arguments[0]).standardizedFileURL.path,
                                  uiPath: try uiPath.map(SessionTrust.validatedUIPath))
    print("Resize APFS helper: local IPC only; writes \(source.writesEnabled ? "enabled, subject to app authorization" : "disabled")")
    server.run()
} catch {
    fputs("Resize APFS helper stopped: \(error.localizedDescription)\n", stderr)
    exit(1)
}
