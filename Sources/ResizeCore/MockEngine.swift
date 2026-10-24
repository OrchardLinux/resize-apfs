import Foundation

/// Operates only on a JSON model. It never opens a disk or invokes storage tools.
/// The server drives tick independently of UI connections; tests inject time.
public actor MockEngine {
    private struct Record: Codable {
        var layout: StorageLayout
        var operation: Operation?
        var scenario: MockScenario
        var timeScale: Double
    }
    private var record: Record
    private var pendingPlans: [UUID: ResizePlan] = [:]
    private let stateURL: URL?
    private let workerPID: Int32

    public init(stateURL: URL? = nil, scenario: MockScenario = .normal,
                timeScale: Double = 1, workerPID: Int32 = 1) throws {
        self.stateURL = stateURL
        self.workerPID = workerPID
        if let stateURL, FileManager.default.fileExists(atPath: stateURL.path) {
            record = try JSONDecoder().decode(Record.self, from: Data(contentsOf: stateURL))
            if record.operation?.status == .running {
                record.operation?.status = .unknown
                record.operation?.workerPID = nil
                record.operation?.message = "The mock service restarted during an operation. Its previous worker no longer exists. No operation was retried."
                try Self.persist(record, to: stateURL)
            }
        } else {
            record = Record(layout: .fixture(scenario), operation: nil, scenario: scenario,
                            timeScale: max(0.01, timeScale))
            try Self.persist(record, to: stateURL)
        }
    }

    public func snapshot(at now: Date = Date(), allowOutage: Bool = true) throws -> ServiceSnapshot {
        if allowOutage, record.scenario == .disconnect, let op = record.operation, op.isActive {
            let elapsed = now.timeIntervalSince(op.startedAt) / record.timeScale
            if elapsed >= 3 && elapsed < 9 { throw ResizeError("Simulated connection interruption. The independent worker continues.") }
        }
        return ServiceSnapshot(layout: record.layout, operation: record.operation,
                               scenario: record.scenario, capturedAt: now)
    }

    public func plan(_ request: PlanRequest) throws -> ResizePlan {
        try ensureIdle()
        if record.scenario == .noPrivileges { throw ResizeError("The privileged helper is unavailable. No storage changes were started.") }
        if record.scenario == .rejectedSizing { throw ResizeError("The resize service rejected this target size. No storage changes were started.") }
        let plan = try Planner.make(request, on: record.layout)
        if pendingPlans.count > 32 { pendingPlans.removeAll() }
        pendingPlans[plan.id] = plan
        return plan
    }

    public func start(_ request: StartRequest, at now: Date = Date()) throws -> ServiceSnapshot {
        if let op = record.operation, op.requestID == request.requestID {
            return try snapshot(at: now, allowOutage: false)
        }
        try ensureIdle()
        guard let plan = pendingPlans[request.planID] else { throw ResizeError("This review has expired. Review the operation again.") }
        guard plan.request.revision == record.layout.revision else { throw ResizeError("Storage changed after review. No operation was started.") }
        _ = try Planner.make(plan.request, on: record.layout)
        record.operation = Operation(id: UUID(), requestID: request.requestID, plan: plan, status: .running,
                                     stepIndex: 0, completedSteps: [], startedAt: now, stepStartedAt: now,
                                     lastConfirmedAt: now, observedCapacityBytes: record.layout.containerBytes,
                                     observedAt: now, workerPID: workerPID, message: nil)
        pendingPlans.removeAll()
        try save()
        return try snapshot(at: now, allowOutage: false)
    }

    public func configure(_ request: ScenarioRequest, at now: Date = Date()) throws -> ServiceSnapshot {
        if record.operation?.isActive == true && !request.discardSimulation {
            throw ResizeError("An operation is active. Explicitly discard the simulation to reset it.")
        }
        guard request.timeScale.isFinite, request.timeScale >= 0.01, request.timeScale <= 100 else {
            throw ResizeError("Invalid mock time scale.")
        }
        record = Record(layout: .fixture(request.scenario), operation: nil,
                        scenario: request.scenario, timeScale: request.timeScale)
        pendingPlans.removeAll()
        try save()
        return try snapshot(at: now, allowOutage: false)
    }

    public func tick(at now: Date = Date()) throws {
        guard var op = record.operation, op.isActive, let step = op.currentStep else { return }
        let duration: Double
        if step.isResize { duration = record.scenario == .longSilence ? 90 : 12 }
        else { duration = step == .verifyLayout ? 2 : 0.8 }
        op.lastConfirmedAt = now
        // Capacity is an observation, not interpolated progress. It stays unchanged
        // throughout relocation and changes only when the simulated resize commits.
        op.observedCapacityBytes = record.layout.containerBytes
        op.observedAt = now
        guard now.timeIntervalSince(op.stepStartedAt) >= duration * record.timeScale else {
            record.operation = op
            try save()
            return
        }
        if step.isResize && record.scenario == .workerCrash {
            op.status = .unknown; op.workerPID = nil
            op.message = "The resize worker disappeared. The outcome could not be established. No partition-table update was attempted."
        } else if step.isResize && record.scenario == .resizeError {
            op.status = .stopped; op.workerPID = nil
            op.message = "The simulated APFS resize call reported an error. Inspection confirms the original layout is unchanged."
        } else if [.shrinkPartition, .expandPartition].contains(step) && record.scenario == .partitionError {
            op.status = .stopped; op.workerPID = nil
            op.message = "The simulated partition-table update failed before writing. Verified APFS size: \(Capacity.gb(record.layout.containerBytes)); backing partition: \(Capacity.gb(record.layout.backingBytes))."
        } else if step == .verifyLayout && record.scenario == .verificationError {
            op.status = .unknown; op.workerPID = nil
            op.message = "Final storage verification could not establish a consistent result. Changes may have been applied. No automatic retry is available."
        } else {
            switch step {
            case .shrinkAPFS, .growAPFS:
                record.layout.containerBytes = op.plan.targetBytes
                record.layout.revision = UUID()
                op.observedCapacityBytes = record.layout.containerBytes
            case .expandPartition, .shrinkPartition:
                let index = record.layout.partitions.firstIndex { $0.id == record.layout.backingPartitionID }!
                record.layout.partitions[index].lastLBA = op.plan.after.apfs.lastLBA
                record.layout.revision = UUID()
            case .createLinux:
                let existing = Set(record.layout.partitions.map(\.id))
                record.layout.partitions += op.plan.after.partitions.filter { !existing.contains($0.id) }
                record.layout.revision = UUID()
            case .verifyAPFS:
                guard record.layout.containerBytes == op.plan.targetBytes else { throw ResizeError("Mock APFS verification failed.") }
            case .verifyLayout:
                try record.layout.validate()
                guard record.layout.containerBytes == op.plan.targetBytes,
                      record.layout.partitions == op.plan.after.partitions else { throw ResizeError("Mock layout verification failed.") }
            default: break
            }
            op.completedSteps.append(step)
            op.stepIndex += 1
            op.stepStartedAt = now
            if op.stepIndex == op.plan.steps.count {
                op.status = .completed; op.workerPID = nil
                op.message = "The requested simulated layout has been completed and verified."
            }
        }
        record.operation = op
        try save()
    }

    private func ensureIdle() throws {
        guard record.operation?.status != .running, record.operation?.status != .unknown else {
            throw ResizeError("A previous operation is active or its outcome is unknown. No new operation was started.")
        }
    }
    private func save() throws { try Self.persist(record, to: stateURL) }
    private static func persist(_ record: Record, to url: URL?) throws {
        guard let url else { return }
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        let data = try JSONEncoder().encode(record)
        try data.write(to: url, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }
}
