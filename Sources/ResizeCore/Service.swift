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

public struct Operation: Codable, Equatable, Identifiable, Sendable {
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
    public var currentStep: OperationStep? { plan.steps.indices.contains(stepIndex) ? plan.steps[stepIndex] : nil }
    public var isActive: Bool { status == .running }

    public init(id: UUID, requestID: UUID, plan: ResizePlan, status: OperationStatus, stepIndex: Int,
                completedSteps: [OperationStep], startedAt: Date, stepStartedAt: Date,
                lastConfirmedAt: Date?, observedCapacityBytes: Int64?, observedAt: Date?,
                workerPID: Int32?, message: String?) {
        self.id = id; self.requestID = requestID; self.plan = plan; self.status = status
        self.stepIndex = stepIndex; self.completedSteps = completedSteps; self.startedAt = startedAt
        self.stepStartedAt = stepStartedAt; self.lastConfirmedAt = lastConfirmedAt
        self.observedCapacityBytes = observedCapacityBytes; self.observedAt = observedAt
        self.workerPID = workerPID; self.message = message
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

public enum MockScenario: String, Codable, CaseIterable, Identifiable, Sendable {
    case normal, freeSpace, mismatch, linuxBlocked, longSilence, disconnect
    case resizeError, partitionError, verificationError, workerCrash, rejectedSizing, noPrivileges, invalidLayout
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
        }
    }
}

public struct StartRequest: Codable, Sendable {
    public var planID: UUID
    public var requestID: UUID
    public init(planID: UUID, requestID: UUID) { self.planID = planID; self.requestID = requestID }
}

public struct ScenarioRequest: Codable, Sendable {
    public var scenario: MockScenario
    public var timeScale: Double
    public var discardSimulation: Bool
    public init(scenario: MockScenario, timeScale: Double, discardSimulation: Bool = false) {
        self.scenario = scenario; self.timeScale = timeScale; self.discardSimulation = discardSimulation
    }
}

public protocol ResizeService: Sendable {
    func snapshot() async throws -> ServiceSnapshot
    func plan(_ request: PlanRequest) async throws -> ResizePlan
    func start(_ request: StartRequest) async throws -> ServiceSnapshot
    func configureMock(_ request: ScenarioRequest) async throws -> ServiceSnapshot
}

public struct HTTPResizeService: ResizeService {
    public let baseURL: URL
    public init(baseURL: URL = URL(string: "http://127.0.0.1:8472")!) { self.baseURL = baseURL }
    public func snapshot() async throws -> ServiceSnapshot { try await call("snapshot") }
    public func plan(_ request: PlanRequest) async throws -> ResizePlan { try await call("plan", body: request) }
    public func start(_ request: StartRequest) async throws -> ServiceSnapshot { try await call("operations", body: request) }
    public func configureMock(_ request: ScenarioRequest) async throws -> ServiceSnapshot { try await call("admin/scenario", body: request) }

    private func call<T: Decodable>(_ path: String) async throws -> T {
        try await send(path, body: nil)
    }
    private func call<T: Decodable, B: Encodable>(_ path: String, body: B) async throws -> T {
        try await send(path, body: JSONEncoder().encode(body))
    }
    private func send<T: Decodable>(_ path: String, body: Data?) async throws -> T {
        var request = URLRequest(url: baseURL.appendingPathComponent(path))
        request.timeoutInterval = 4
        request.cachePolicy = .reloadIgnoringLocalCacheData
        if let body {
            request.httpMethod = "POST"; request.httpBody = body
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw ResizeError("Invalid service response.") }
        if !(200..<300).contains(http.statusCode) {
            throw (try? JSONDecoder().decode(ResizeError.self, from: data)) ?? ResizeError("Service returned HTTP \(http.statusCode).")
        }
        return try JSONDecoder().decode(T.self, from: data)
    }
}

// Device builds cannot accidentally use the simulator's mock as a real disk backend.
public struct UnavailableDeviceService: ResizeService {
    public init() {}
    private var error: ResizeError { ResizeError("The on-device privileged helper is not installed. This build cannot resize real storage.") }
    public func snapshot() async throws -> ServiceSnapshot { throw error }
    public func plan(_ request: PlanRequest) async throws -> ResizePlan { throw error }
    public func start(_ request: StartRequest) async throws -> ServiceSnapshot { throw error }
    public func configureMock(_ request: ScenarioRequest) async throws -> ServiceSnapshot { throw error }
}
