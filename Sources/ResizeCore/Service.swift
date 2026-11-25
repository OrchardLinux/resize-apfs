import Foundation

public enum OperationStatus: String, Codable, Sendable { case running, completed, stopped, unknown }

public enum WorkerConfirmation {
    public static let freshnessLimit: TimeInterval = 15
    public static func isFresh(pid: Int32?, confirmedAt: Date?, connectionAvailable: Bool, now: Date) -> Bool {
        guard connectionAvailable, let pid, pid > 0, let confirmedAt else { return false }
        let age = now.timeIntervalSince(confirmedAt)
        return age >= -5 && age <= freshnessLimit
    }
}

public struct Operation: Codable, Equatable, Sendable {
    public var id: UUID
    public var requestID: UUID
    public var plan: ResizePlan
    public var status: OperationStatus
    public var stepIndex: Int
    public var completedSteps: [OperationStep]
    public var startedAt: Date
    public var stepStartedAt: Date
    public var lastConfirmedAt: Date?
    public var observedCapacityBytes: Int64?
    public var observedAt: Date?
    public var workerPID: Int32?
    public var message: String?
    /// While shrinking APFS in several calls: the call running or last run.
    /// Absent in records from before shrinks ran in steps, and for growth.
    public var apfsStep: APFSStepProgress?
    /// The user asked to stop after the running shrink step. Absent: not asked.
    public var stopRequested: Bool?
    /// The operation ended because of that request, not because of an error.
    public var stoppedByUser: Bool?
    public var currentStep: OperationStep? { plan.steps.indices.contains(stepIndex) ? plan.steps[stepIndex] : nil }
    public var isActive: Bool { status == .running }

    public init(id: UUID, requestID: UUID, plan: ResizePlan, status: OperationStatus, stepIndex: Int,
                completedSteps: [OperationStep], startedAt: Date, stepStartedAt: Date,
                lastConfirmedAt: Date?, observedCapacityBytes: Int64?, observedAt: Date?,
                workerPID: Int32?, message: String?, apfsStep: APFSStepProgress? = nil) {
        self.id = id; self.requestID = requestID; self.plan = plan; self.status = status
        self.stepIndex = stepIndex; self.completedSteps = completedSteps; self.startedAt = startedAt
        self.stepStartedAt = stepStartedAt; self.lastConfirmedAt = lastConfirmedAt
        self.observedCapacityBytes = observedCapacityBytes; self.observedAt = observedAt
        self.workerPID = workerPID; self.message = message; self.apfsStep = apfsStep
    }
}

public struct ServiceSnapshot: Codable, Equatable, Sendable {
    public var mode: String = "mock"
    public var layout: StorageLayout
    public var operation: Operation?
    public var scenario: MockScenario
    public var capturedAt: Date
    public init(mode: String = "mock", layout: StorageLayout, operation: Operation?,
                scenario: MockScenario = .normal, capturedAt: Date = Date()) {
        self.mode = mode; self.layout = layout; self.operation = operation
        self.scenario = scenario; self.capturedAt = capturedAt
    }
}

public enum MockScenario: String, Codable, CaseIterable, Sendable {
    case normal, freeSpace, mismatch, linuxBlocked, longSilence, disconnect
    case resizeError, partitionError, verificationError, workerCrash, rejectedSizing, noPrivileges, invalidLayout
    case snapshot, snapshotProtected
    public var id: String { rawValue }
    public var title: String {
        switch self {
        case .normal: return "Normal shrink"
        case .freeSpace: return "Grow into adjacent space"
        case .mismatch: return "Container smaller than partition"
        case .linuxBlocked: return "Linux partition blocks growth"
        case .longSilence: return "Long resize, no capacity changes"
        case .disconnect: return "Connection lost, operation continues"
        case .resizeError: return "Resize call reports an error"
        case .partitionError: return "APFS succeeds, partition update fails"
        case .verificationError: return "Final verification fails"
        case .workerCrash: return "Worker disappears, outcome unknown"
        case .rejectedSizing: return "Sizing rejected by service"
        case .noPrivileges: return "Privileged helper unavailable"
        case .invalidLayout: return "GPT copies disagree"
        case .snapshot: return "orig-fs snapshot holds space (iOS 12-14)"
        case .snapshotProtected: return "orig-fs is the snapshot iOS reverts to"
        }
    }
}

public struct StartRequest: Codable, Sendable {
    public var planID: UUID
    public var requestID: UUID
    public init(planID: UUID, requestID: UUID) { self.planID = planID; self.requestID = requestID }
}

/// Remove or take the system snapshot. The revision is the layout the user saw;
/// the service refuses if storage changed since.
public struct SnapshotRequest: Codable, Sendable {
    public var revision: UUID
    public var name: String
    public init(revision: UUID, name: String) { self.revision = revision; self.name = name }
}

/// Stop a stepwise shrink after the step now running.
public struct StopRequest: Codable, Sendable {
    public var operationID: UUID
    public init(operationID: UUID) { self.operationID = operationID }
}

public struct ScenarioRequest: Codable, Sendable {
    public var scenario: MockScenario
    public var timeScale: Double
    public var discardSimulation: Bool
    public init(scenario: MockScenario, timeScale: Double, discardSimulation: Bool = false) {
        self.scenario = scenario; self.timeScale = timeScale; self.discardSimulation = discardSimulation
    }
}

/// Completion-based so it runs on iOS 12, which has no Swift concurrency.
/// Completions arrive on an arbitrary queue; UI callers hop to the main queue.
/// The async forms below wrap exactly these calls on systems that have it.
public typealias ServiceCompletion<T> = @Sendable (Result<T, Error>) -> Void

public protocol ResizeService: Sendable {
    func snapshot(completion: @escaping ServiceCompletion<ServiceSnapshot>)
    func plan(_ request: PlanRequest, completion: @escaping ServiceCompletion<ResizePlan>)
    func start(_ request: StartRequest, completion: @escaping ServiceCompletion<ServiceSnapshot>)
    func stop(_ request: StopRequest, completion: @escaping ServiceCompletion<ServiceSnapshot>)
    /// Drops an open connection; the next request opens a new one.
    func disconnect()
    func configureMock(_ request: ScenarioRequest, completion: @escaping ServiceCompletion<ServiceSnapshot>)
    func removeSnapshot(_ request: SnapshotRequest, completion: @escaping ServiceCompletion<ServiceSnapshot>)
    func takeSnapshot(_ request: SnapshotRequest, completion: @escaping ServiceCompletion<ServiceSnapshot>)
}

public extension ResizeService {
    func disconnect() {}
}

@available(iOS 13, macOS 10.15, *)
public extension ResizeService {
    func snapshot() async throws -> ServiceSnapshot {
        try await withCheckedThrowingContinuation { c in snapshot { c.resume(with: $0) } }
    }
    func plan(_ request: PlanRequest) async throws -> ResizePlan {
        try await withCheckedThrowingContinuation { c in plan(request) { c.resume(with: $0) } }
    }
    func start(_ request: StartRequest) async throws -> ServiceSnapshot {
        try await withCheckedThrowingContinuation { c in start(request) { c.resume(with: $0) } }
    }
    func stop(_ request: StopRequest) async throws -> ServiceSnapshot {
        try await withCheckedThrowingContinuation { c in stop(request) { c.resume(with: $0) } }
    }
    func configureMock(_ request: ScenarioRequest) async throws -> ServiceSnapshot {
        try await withCheckedThrowingContinuation { c in configureMock(request) { c.resume(with: $0) } }
    }
    func removeSnapshot(_ request: SnapshotRequest) async throws -> ServiceSnapshot {
        try await withCheckedThrowingContinuation { c in removeSnapshot(request) { c.resume(with: $0) } }
    }
    func takeSnapshot(_ request: SnapshotRequest) async throws -> ServiceSnapshot {
        try await withCheckedThrowingContinuation { c in takeSnapshot(request) { c.resume(with: $0) } }
    }
}

public struct HTTPResizeService: ResizeService {
    public let baseURL: URL
    public init(baseURL: URL = URL(string: "http://127.0.0.1:8472")!) { self.baseURL = baseURL }
    public func snapshot(completion: @escaping ServiceCompletion<ServiceSnapshot>) { send("snapshot", body: nil, completion: completion) }
    public func plan(_ request: PlanRequest, completion: @escaping ServiceCompletion<ResizePlan>) { send("plan", encoding: request, completion: completion) }
    public func start(_ request: StartRequest, completion: @escaping ServiceCompletion<ServiceSnapshot>) { send("operations", encoding: request, completion: completion) }
    public func stop(_ request: StopRequest, completion: @escaping ServiceCompletion<ServiceSnapshot>) { send("operations/stop", encoding: request, completion: completion) }
    public func configureMock(_ request: ScenarioRequest, completion: @escaping ServiceCompletion<ServiceSnapshot>) { send("admin/scenario", encoding: request, completion: completion) }
    public func removeSnapshot(_ request: SnapshotRequest, completion: @escaping ServiceCompletion<ServiceSnapshot>) { send("snapshots/remove", encoding: request, completion: completion) }
    public func takeSnapshot(_ request: SnapshotRequest, completion: @escaping ServiceCompletion<ServiceSnapshot>) { send("snapshots/take", encoding: request, completion: completion) }

    private func send<T: Decodable, B: Encodable>(_ path: String, encoding body: B, completion: @escaping ServiceCompletion<T>) {
        let data: Data
        do { data = try JSONEncoder().encode(body) } catch { completion(.failure(error)); return }
        send(path, body: data, completion: completion)
    }
    private func send<T: Decodable>(_ path: String, body: Data?, completion: @escaping ServiceCompletion<T>) {
        var request = URLRequest(url: baseURL.appendingPathComponent(path))
        request.timeoutInterval = 4
        request.cachePolicy = .reloadIgnoringLocalCacheData
        if let body {
            request.httpMethod = "POST"; request.httpBody = body
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
        URLSession.shared.dataTask(with: request) { data, response, error in
            completion(Result {
                if let error { throw error }
                guard let http = response as? HTTPURLResponse else { throw ResizeError("Invalid service response.") }
                let data = data ?? Data()
                if !(200..<300).contains(http.statusCode) {
                    throw (try? JSONDecoder().decode(ResizeError.self, from: data)) ?? ResizeError("Service returned HTTP \(http.statusCode).")
                }
                return try JSONDecoder().decode(T.self, from: data)
            })
        }.resume()
    }
}

// Device builds cannot accidentally use the simulator's mock as a real disk backend.
public struct UnavailableDeviceService: ResizeService {
    public init() {}
    private var error: ResizeError { ResizeError("The on-device privileged helper is not installed. This build cannot resize real storage.") }
    public func snapshot(completion: @escaping ServiceCompletion<ServiceSnapshot>) { completion(.failure(error)) }
    public func plan(_ request: PlanRequest, completion: @escaping ServiceCompletion<ResizePlan>) { completion(.failure(error)) }
    public func start(_ request: StartRequest, completion: @escaping ServiceCompletion<ServiceSnapshot>) { completion(.failure(error)) }
    public func stop(_ request: StopRequest, completion: @escaping ServiceCompletion<ServiceSnapshot>) { completion(.failure(error)) }
    public func configureMock(_ request: ScenarioRequest, completion: @escaping ServiceCompletion<ServiceSnapshot>) { completion(.failure(error)) }
    public func removeSnapshot(_ request: SnapshotRequest, completion: @escaping ServiceCompletion<ServiceSnapshot>) { completion(.failure(error)) }
    public func takeSnapshot(_ request: SnapshotRequest, completion: @escaping ServiceCompletion<ServiceSnapshot>) { completion(.failure(error)) }
}
