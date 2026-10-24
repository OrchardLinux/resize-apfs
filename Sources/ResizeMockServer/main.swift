import Foundation
import Network
import ResizeCore
import Darwin

// Loopback-only HTTP/1.1, one request per connection. No filesystem paths or
// commands are accepted by the API. All mutations affect the synthetic JSON model.
final class StateFileLock {
    private let descriptor: Int32
    init(url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let fd = Darwin.open(url.path, O_CREAT | O_RDWR, S_IRUSR | S_IWUSR)
        guard fd >= 0 else { throw ResizeError("Cannot create the mock service lock.") }
        guard flock(fd, LOCK_EX | LOCK_NB) == 0 else {
            close(fd)
            throw ResizeError("Another mock service owns this journal. Use a different --state path.")
        }
        descriptor = fd
    }
    deinit { close(descriptor) }
}

final class HTTPServer: @unchecked Sendable {
    let stateLock: StateFileLock
    let engine: MockEngine
    let queue = DispatchQueue(label: "resize.mock.http")
    let listener: NWListener
    var ticker: Task<Void, Never>?

    init(port: UInt16, stateURL: URL, timeScale: Double) throws {
        stateLock = try StateFileLock(url: stateURL.appendingPathExtension("lock"))
        engine = try MockEngine(stateURL: stateURL, timeScale: timeScale, workerPID: getpid())
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: NWEndpoint.Port(rawValue: port)!)
        parameters.allowLocalEndpointReuse = true
        listener = try NWListener(using: parameters)
    }

    func run() {
        listener.stateUpdateHandler = { state in
            if case .failed(let error) = state { fputs("Server failed: \(error)\n", stderr); exit(1) }
        }
        listener.newConnectionHandler = { [self] connection in
            connection.start(queue: queue)
            receive(connection, buffer: Data())
            queue.asyncAfter(deadline: .now() + 10) { connection.cancel() }
        }
        listener.start(queue: queue)
        ticker = Task {
            while !Task.isCancelled {
                do { try await engine.tick() }
                catch {
                    // Persistence failure is fatal: never keep reporting a worker
                    // whose durable state can no longer be recorded.
                    fputs("Mock worker stopped: \(error)\n", stderr); exit(1)
                }
                try? await Task.sleep(nanoseconds: 250_000_000)
            }
        }
    }

    private func receive(_ connection: NWConnection, buffer: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65_536) { [self] data, _, complete, error in
            var buffer = buffer
            if let data { buffer.append(data) }
            guard buffer.count <= 1_048_576 else { connection.cancel(); return }
            if let boundary = buffer.range(of: Data("\r\n\r\n".utf8)) {
                let header = String(decoding: buffer[..<boundary.lowerBound], as: UTF8.self)
                let lengthLine = header.components(separatedBy: "\r\n").first { $0.lowercased().hasPrefix("content-length:") }
                let lengthText = lengthLine?.split(separator: ":", maxSplits: 1).last?.trimmingCharacters(in: .whitespaces)
                let length = lengthText.flatMap(Int.init) ?? 0
                guard length >= 0, length <= 1_048_576 else { connection.cancel(); return }
                if buffer.count >= boundary.upperBound + length {
                    let firstLine = header.components(separatedBy: "\r\n")[0].split(separator: " ")
                    guard firstLine.count >= 2 else { connection.cancel(); return }
                    let method = String(firstLine[0]), path = String(firstLine[1])
                    let body = buffer.subdata(in: boundary.upperBound..<(boundary.upperBound + length))
                    Task { await self.respond(connection, method: method, path: path, body: body) }
                    return
                }
            }
            if complete || error != nil { connection.cancel() }
            else { receive(connection, buffer: buffer) }
        }
    }

    private func respond(_ connection: NWConnection, method: String, path: String, body: Data) async {
        var status = 200
        let data: Data
        do {
            let decoder = JSONDecoder(), encoder = JSONEncoder()
            switch (method, path) {
            case ("GET", "/health"):
                data = Data("{\"mode\":\"mock\",\"status\":\"ready\"}".utf8)
            case ("GET", "/snapshot"):
                data = try encoder.encode(try await engine.snapshot())
            case ("POST", "/plan"):
                data = try encoder.encode(try await engine.plan(decoder.decode(PlanRequest.self, from: body)))
            case ("POST", "/operations"):
                data = try encoder.encode(try await engine.start(decoder.decode(StartRequest.self, from: body)))
            case ("POST", "/admin/scenario"):
                data = try encoder.encode(try await engine.configure(decoder.decode(ScenarioRequest.self, from: body)))
            default:
                status = 404; data = try encoder.encode(ResizeError("Unknown endpoint."))
            }
        } catch {
            status = method == "GET" ? 503 : 409
            data = (try? JSONEncoder().encode(ResizeError(error.localizedDescription))) ?? Data()
        }
        var response = Data("HTTP/1.1 \(status) \(status == 200 ? "OK" : "Error")\r\nContent-Type: application/json\r\nContent-Length: \(data.count)\r\nCache-Control: no-store\r\nConnection: close\r\n\r\n".utf8)
        response.append(data)
        connection.send(content: response, completion: .contentProcessed { _ in connection.cancel() })
    }
}

let args = CommandLine.arguments
func option(_ flag: String) -> String? { args.firstIndex(of: flag).flatMap { $0 + 1 < args.count ? args[$0 + 1] : nil } }
let port = option("--port").flatMap(UInt16.init) ?? 8472
let state = URL(fileURLWithPath: option("--state") ?? ".mock/state.json")
let speed = option("--time-scale").flatMap(Double.init) ?? 1
do {
    let server = try HTTPServer(port: port, stateURL: state, timeScale: speed)
    server.run()
    print("Resize APFS mock service: http://127.0.0.1:\(port)")
    print("Synthetic storage only. Journal: \(state.path). PID: \(getpid())")
    fflush(stdout)
    withExtendedLifetime(server) { dispatchMain() }
} catch {
    fputs("Cannot start mock service: \(error.localizedDescription)\n", stderr)
    exit(1)
}
