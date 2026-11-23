import Foundation
import Darwin
import ResizeCore
import NativeSystem

public struct DeviceJob: Codable, Sendable {
    public var id: UUID
    public var source: DeviceSource
    public var step: OperationStep
    public var plan: ResizePlan
    public var expectedGPT: GPTImage
    public var expectedContainerBytes: Int64
    /// One step of a shrink in several calls: this call's container size,
    /// between the plan's target and the current size. Nil: the plan's target.
    public var apfsTargetBytes: Int64?
    public init(id: UUID = UUID(), source: DeviceSource, step: OperationStep, plan: ResizePlan,
                expectedGPT: GPTImage, expectedContainerBytes: Int64, apfsTargetBytes: Int64? = nil) {
        self.id = id; self.source = source; self.step = step; self.plan = plan
        self.expectedGPT = expectedGPT; self.expectedContainerBytes = expectedContainerBytes
        self.apfsTargetBytes = apfsTargetBytes
    }
    /// The container size this job's APFS resize call asks for.
    public var resizeTargetBytes: Int64 { apfsTargetBytes ?? plan.targetBytes }
}
public struct WorkerResult: Codable, Sendable {
    public enum Outcome: String, Codable, Sendable { case success, returnedError, refused, unknown }
    public var jobID: UUID
    public var outcome: Outcome
    public var message: String
    public var apiStatus: Int32?
    /// How long the APFS resize call itself took, measured by the worker.
    public var callSeconds: Double?
    public init(jobID: UUID, outcome: Outcome, message: String, apiStatus: Int32? = nil, callSeconds: Double? = nil) {
        self.jobID = jobID; self.outcome = outcome; self.message = message; self.apiStatus = apiStatus
        self.callSeconds = callSeconds
    }
}

public enum DeviceWorker {
    public static func resultURL(for jobURL: URL) -> URL { jobURL.deletingPathExtension().appendingPathExtension("result.json") }

    public static func execute(_ job: DeviceJob) -> WorkerResult {
        var mutationEntered = false
        do {
            guard job.source.writesEnabled else { throw ResizeError("This helper has no storage-write permission.") }
            let observed = try DeviceInspector.inspect(job.source, queryMinimum: job.step.isResize, minimumMaxAge: 0)
            guard observed.gpt == job.expectedGPT,
                  observed.layout.diskID == job.plan.before.diskID,
                  observed.layout.containerID == job.plan.before.containerID,
                  observed.layout.containerBytes == job.expectedContainerBytes else {
                throw ResizeError("Storage changed before the worker started. No mutation was attempted.")
            }
            if job.step.isResize {
                guard !job.source.isFixture else { throw ResizeError("APFS mutation is unavailable for host file fixtures.") }
                let target = try validatedResizeTarget(job, observed.layout)
                mutationEntered = true
                let began = ProcessInfo.processInfo.systemUptime
                let status = raf_apfs_resize(observed.layout.apfs.bsdName, UInt64(target))
                let seconds = ProcessInfo.processInfo.systemUptime - began
                return WorkerResult(jobID: job.id, outcome: status == 0 ? .success : .returnedError,
                                    message: status == 0 ? "The APFS resize call returned success; readback verification is still required." : "The APFS resize call returned error \(status). Changes are not assumed to be undone.",
                                    apiStatus: status, callSeconds: seconds)
            }
            guard [.expandPartition, .shrinkPartition, .createLinux].contains(job.step) else {
                throw ResizeError("The worker does not accept this mutation step.")
            }
            let end = job.step == .createLinux ? observed.layout.apfs.lastLBA : job.plan.after.apfs.lastLBA
            guard observed.layout.containerBytes <= (end - observed.layout.apfs.firstLBA + 1) * observed.layout.sectorSize else {
                throw ResizeError("Refusing to put the GPT boundary inside the APFS container.")
            }
            let existing = Set(observed.layout.partitions.map(\.id))
            let addition = job.step == .createLinux ? job.plan.after.partitions.first { !existing.contains($0.id) && $0.kind == .linux } : nil
            if job.step == .createLinux && addition == nil { throw ResizeError("The reviewed Linux partition is missing or already exists.") }
            // Replacing: exactly the approved partitions still follow APFS.
            let removing = job.step == job.plan.removalStep ? job.plan.request.replacing : []
            if !removing.isEmpty {
                let following = observed.layout.partitions.filter { $0.firstLBA > observed.layout.apfs.lastLBA }.map(\.id)
                guard Set(following) == Set(removing), following.count == removing.count else {
                    throw ResizeError("The partitions after APFS changed since they were approved. No write was attempted.")
                }
            }
            let proposed = try observed.gpt.changingEnd(partitionID: observed.layout.backingPartitionID, to: end, adding: addition, removing: removing)
            let fd = raf_open_gpt_write(job.source.path, job.source.isFixture ? 1 : 0)
            guard fd >= 0 else { throw ResizeError("Cannot open the disk for the limited GPT update: \(String(cString: strerror(errno))). No write was attempted.") }
            defer { close(fd) }
            // Recheck through an independent read descriptor immediately before writing.
            let reader = try RawDisk(job.source)
            guard try reader.gpt() == observed.gpt else { throw ResizeError("GPT changed immediately before writing. No write was attempted.") }
            let freshAPFS = try APFSMetadata.capture(partitionBytes: observed.layout.backingBytes) { offset, count in
                try reader.read(observed.layout.apfs.firstLBA * reader.sectorSize + offset, count)
            }
            guard freshAPFS.containerID == observed.layout.containerID,
                  freshAPFS.capacityBytes == job.expectedContainerBytes,
                  freshAPFS.capacityBytes <= (end - observed.layout.apfs.firstLBA + 1) * observed.layout.sectorSize else {
                throw ResizeError("APFS changed immediately before the partition update. No write was attempted.")
            }
            for (index, region) in proposed.writeRegions.enumerated() {
                mutationEntered = true
                try region.data.withUnsafeBytes { buffer in
                    var done = 0
                    while done < buffer.count {
                        let count = pwrite(fd, buffer.baseAddress!.advanced(by: done), buffer.count - done, off_t(region.offset + Int64(done)))
                        if count < 0 && errno == EINTR { continue }
                        guard count > 0 else { throw ResizeError("A GPT write failed; the result must be inspected. No retry was attempted.") }
                        done += count
                    }
                }
                if index == 1 || index == 3 {
                    guard raf_flush(fd, job.source.isFixture ? 1 : 0) == 0 else { throw ResizeError("Cannot confirm GPT writes reached storage.") }
                }
            }
            let readback = try reader.gpt()
            guard readback == proposed else { throw ResizeError("GPT readback does not match the reviewed update.") }
            return WorkerResult(jobID: job.id, outcome: .success,
                                message: "Both GPT copies were written and verified. iOS may keep its old partition-device cache until a later boot.")
        } catch {
            return WorkerResult(jobID: job.id, outcome: mutationEntered ? .unknown : .refused, message: error.localizedDescription)
        }
    }

    /// The size the APFS call may ask for, checked against what was observed
    /// just now. A shrink step lies between the plan's target and the current
    /// size and above APFS's own minimum; growth asks for the plan's target only.
    public static func validatedResizeTarget(_ job: DeviceJob, _ layout: StorageLayout) throws -> Int64 {
        let target = job.resizeTargetBytes
        if job.step == .shrinkAPFS {
            guard target < layout.containerBytes, target >= job.plan.targetBytes else {
                throw ResizeError("This shrink step's size is not between the approved target and the current size.")
            }
            guard let minimum = layout.minimumContainerBytes, target >= minimum, target >= layout.allocatedBytes else {
                throw ResizeError("The APFS minimum-size query did not validate this shrink target.")
            }
        } else {
            guard job.apfsTargetBytes == nil || target == job.plan.targetBytes else { throw ResizeError("APFS growth runs to the approved size only.") }
            var visibleCapacity: UInt64 = 0
            guard raf_partition_capacity(layout.apfs.bsdName, &visibleCapacity) == 0,
                  visibleCapacity >= UInt64(target) else {
                throw ResizeError("GPT may have grown, but iOS still exposes the old partition boundary. APFS growth was not attempted; the device may need a later reboot before growth can continue.")
            }
        }
        guard target > 0, target % 4096 == 0, target <= layout.backingBytes else { throw ResizeError("Unsafe APFS target size.") }
        return target
    }

    public static func runFile(_ url: URL) throws {
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        guard (attributes[.type] as? FileAttributeType) == .typeRegular,
              (attributes[.ownerAccountID] as? NSNumber)?.uint32Value == geteuid(),
              ((attributes[.posixPermissions] as? NSNumber)?.intValue ?? 0) & 0o077 == 0 else {
            throw ResizeError("The worker job is not a private, owner-controlled regular file.")
        }
        let job = try JSONDecoder().decode(DeviceJob.self, from: Data(contentsOf: url))
        guard url.lastPathComponent == "\(job.id.uuidString).job.json" else { throw ResizeError("Worker job identity mismatch.") }
        try DeviceJournal.write(execute(job), to: resultURL(for: url))
    }
}
