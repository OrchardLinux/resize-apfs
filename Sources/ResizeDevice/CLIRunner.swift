import Foundation
import Darwin
import ResizeCore
import NativeSystem

public enum CLIRunner {
    public struct Options: Equatable {
        public enum Action: Equatable {
            case help
            case layout
            case status
            case shrink(String)
        }
        public var action: Action = .layout
        public var diskPath: String = "/dev/disk0"
        public var fixturePath: String?
        public var sectorSize: Int64 = 4096
        public var stateDirectory: String = "/var/root/Library/ResizeAPFS"
        public var confirmYes: Bool = false
        public var createLinux: Bool = false
        public var allowOtherPartitions: Bool = false
        public var minFreeMiB: Int64 = 512
        public var jsonOutput: Bool = false
        public init() {}
    }

    private struct Record: Codable {
        var operation: ResizeCore.Operation
        var workerJob: URL?
        var bootIdentity: String
    }

    private struct LayoutReport: Codable {
        var environment: RuntimeEnvironment
        var layout: StorageLayout
        var transactionID: UInt64
        var minimumQueryStatus: Int32?
        var snapshots: [VolumeSnapshots]
    }

    private struct PlanReport: Codable {
        var environment: RuntimeEnvironment
        var dryRun: Bool
        var plan: ResizePlan
        var snapshots: [VolumeSnapshots]
        var releasedTrailingBytes: Int64
    }

    public static func hasCLIFlags(_ args: [String]) -> Bool {
        let flags: Set<String> = ["--layout", "--shrink-to", "--status", "--help", "-h", "--json"]
        return args.contains { flags.contains($0) }
    }

    public static func parseOptions(_ args: [String]) throws -> Options {
        var options = Options()
        var i = 1
        while i < args.count {
            let arg = args[i]
            func nextValue(_ flag: String) throws -> String {
                guard i + 1 < args.count else { throw ResizeError("Missing value for \(flag).") }
                i += 1
                return args[i]
            }
            switch arg {
            case "--help", "-h": options.action = .help
            case "--layout": options.action = .layout
            case "--status": options.action = .status
            case "--shrink-to": options.action = .shrink(try nextValue(arg))
            case "--disk": options.diskPath = try nextValue(arg)
            case "--fixture": options.fixturePath = try nextValue(arg)
            case "--sector-size":
                let raw = try nextValue(arg)
                guard let value = Int64(raw), value >= 512 else { throw ResizeError("Invalid --sector-size value.") }
                options.sectorSize = value
            case "--state-dir": options.stateDirectory = try nextValue(arg)
            case "--yes": options.confirmYes = true
            case "--create-linux": options.createLinux = true
            case "--allow-other-partitions": options.allowOtherPartitions = true
            case "--min-free-mib":
                let raw = try nextValue(arg)
                guard let value = Int64(raw), value >= 0 else { throw ResizeError("Invalid --min-free-mib value.") }
                options.minFreeMiB = value
            case "--json": options.jsonOutput = true
            case "--allow-writes": break
            default:
                throw ResizeError("Unknown argument: \(arg). Run with --help for usage.")
            }
            i += 1
        }
        return options
    }

    /// Parses a target size string. Bare numbers are interpreted as GiB (base-2,
    /// 1024^3 bytes); explicit suffixes GiB, GB, MiB, MB, and B are also accepted.
    public static func parseTargetBytes(_ raw: String) throws -> Int64 {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw ResizeError("Empty size value.") }
        let lower = trimmed.lowercased()
        let multiplier: Decimal
        let numberPart: String
        if lower.hasSuffix("gib") {
            multiplier = Decimal(1_073_741_824); numberPart = String(trimmed.dropLast(3))
        } else if lower.hasSuffix("gb") {
            multiplier = Decimal(1_000_000_000); numberPart = String(trimmed.dropLast(2))
        } else if lower.hasSuffix("mib") {
            multiplier = Decimal(1_048_576); numberPart = String(trimmed.dropLast(3))
        } else if lower.hasSuffix("mb") {
            multiplier = Decimal(1_000_000); numberPart = String(trimmed.dropLast(2))
        } else if lower.hasSuffix("b") {
            multiplier = Decimal(1); numberPart = String(trimmed.dropLast(1))
        } else {
            multiplier = Decimal(1_073_741_824); numberPart = trimmed
        }
        let normalized = numberPart.trimmingCharacters(in: .whitespaces)
        guard !normalized.isEmpty, normalized.contains(where: { $0.isNumber }),
              normalized.allSatisfy({ $0.isASCII && ($0.isNumber || $0 == ".") }),
              normalized.filter({ $0 == "." }).count <= 1,
              let value = Decimal(string: normalized, locale: Locale(identifier: "en_US_POSIX")),
              value > 0 else {
            throw ResizeError("Invalid target size '\(raw)'. Use e.g. 10 (GiB), 10GiB, 10GB, or 10737418240B.")
        }
        let product = value * multiplier
        guard product <= Decimal(Int64.max) else { throw ResizeError("Target size overflows 64-bit byte count.") }
        let bytes = NSDecimalNumber(decimal: product).int64Value
        guard bytes > 0 else { throw ResizeError("Target size must be positive.") }
        return bytes
    }

    public static func run(arguments: [String] = CommandLine.arguments, executable: String) throws {
        let options = try parseOptions(arguments)
        if options.action == .help {
            printUsage(executable: URL(fileURLWithPath: executable).lastPathComponent)
            return
        }
        let isFixture = options.fixturePath != nil
        #if os(iOS)
        guard geteuid() == 0, !isFixture else {
            throw ResizeError("The device CLI must run as root and cannot use --fixture.")
        }
        #else
        guard isFixture || options.action == .status else {
            throw ResizeError("Host execution requires --fixture <file>. Host disks are never opened.")
        }
        #endif

        let env = RuntimeEnvironment.detect(isFixture: isFixture)
        let stateURL = URL(fileURLWithPath: options.stateDirectory)

        switch options.action {
        case .help:
            return
        case .status:
            try printStatus(stateDirectory: stateURL, env: env, json: options.jsonOutput)
        case .layout:
            let source = DeviceSource(path: options.fixturePath ?? options.diskPath,
                                      fixtureSectorSize: isFixture ? options.sectorSize : nil,
                                      writesEnabled: false)
            let inspection = try DeviceInspector.inspect(source, queryMinimum: true, allowReadOnlyMinimum: true)
            try printLayout(inspection, env: env, json: options.jsonOutput)
        case .shrink(let rawTarget):
            let requestedBytes = try parseTargetBytes(rawTarget)
            try runShrink(requestedBytes: requestedBytes, options: options, env: env,
                          stateDirectory: stateURL, executable: executable)
        }
    }

    private static func runShrink(requestedBytes: Int64, options: Options, env: RuntimeEnvironment,
                                  stateDirectory: URL, executable: String) throws {
        let isFixture = options.fixturePath != nil
        let source = DeviceSource(path: options.fixturePath ?? options.diskPath,
                                  fixtureSectorSize: isFixture ? options.sectorSize : nil,
                                  writesEnabled: options.confirmYes)
        let inspection = try DeviceInspector.inspect(source, queryMinimum: true, allowReadOnlyMinimum: true)
        var layout = inspection.layout
        // Clear read-only overlay note when computing a dry-run plan for display.
        if !options.confirmYes { layout.issue = nil }
        try validateShrinkSafety(inspection: inspection, layout: layout, requestedBytes: requestedBytes,
                                 options: options, isFixture: isFixture)
        let plan = try Planner.make(PlanRequest(revision: layout.revision,
                                                requestedBytes: requestedBytes,
                                                createLinux: options.createLinux), on: layout)
        let addition = plan.after.partitions.first { candidate in
            !layout.partitions.contains(where: { $0.id == candidate.id })
        }
        _ = try inspection.gpt.changingEnd(partitionID: layout.backingPartitionID,
                                           to: plan.after.apfs.lastLBA, adding: addition)
        let released = layout.backingBytes - plan.after.backingBytes
        if !options.confirmYes {
            try printPlan(plan, inspection: inspection, env: env, releasedBytes: released,
                          dryRun: true, json: options.jsonOutput)
            return
        }

        try FileManager.default.createDirectory(at: stateDirectory, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        let lockFD = open(stateDirectory.appendingPathComponent("helper.lock").path,
                          O_RDWR | O_CREAT | O_CLOEXEC | O_NOFOLLOW, 0o600)
        guard lockFD >= 0, flock(lockFD, LOCK_EX | LOCK_NB) == 0 else {
            if lockFD >= 0 { close(lockFD) }
            throw ResizeError("Another resize operation owns \(stateDirectory.path).")
        }
        defer { close(lockFD) }

        let stateFile = stateDirectory.appendingPathComponent("operation.json")
        if FileManager.default.fileExists(atPath: stateFile.path) {
            let prior = try JSONDecoder().decode(Record.self, from: Data(contentsOf: stateFile))
            if prior.operation.status == .running || prior.operation.status == .unknown {
                throw ResizeError("A prior operation (\(prior.operation.id.uuidString)) is \(prior.operation.status.rawValue). Run --status and inspect --layout before attempting any new change.")
            }
        }

        try printPlan(plan, inspection: inspection, env: env, releasedBytes: released,
                      dryRun: false, json: false)
        let now = Date()
        var record = Record(
            operation: ResizeCore.Operation(id: UUID(), requestID: UUID(), plan: plan, status: .running,
                                            stepIndex: 0, completedSteps: [], startedAt: now, stepStartedAt: now,
                                            lastConfirmedAt: now, observedCapacityBytes: layout.containerBytes,
                                            observedAt: inspection.observedAt, workerPID: nil, message: nil),
            workerJob: nil, bootIdentity: bootIdentity()
        )
        let backupURL = stateDirectory.appendingPathComponent("backups/\(record.operation.id.uuidString).gpt.json")
        try DeviceJournal.write(inspection.gpt, to: backupURL)
        try DeviceJournal.write(record, to: stateFile)
        print("Original GPT backed up to: \(backupURL.path)")
        fflush(stdout)

        // Do not let a dropped SSH session kill the coordinator mid-mutation.
        signal(SIGHUP, SIG_IGN)
        signal(SIGPIPE, SIG_IGN)

        do {
            while record.operation.status == .running, let step = record.operation.currentStep {
                let before = try DeviceInspector.inspect(source, queryMinimum: step == .checking || step.isResize,
                                                         allowReadOnlyMinimum: true)
                print("[\(record.operation.stepIndex + 1)/\(plan.steps.count)] \(step.title)...")
                fflush(stdout)
                if step == .checking {
                    guard before.layout.revision == plan.before.revision,
                          before.layout.diskID == plan.before.diskID,
                          before.layout.containerID == plan.before.containerID else {
                        throw ResizeError("Storage changed after plan creation. No worker was started.")
                    }
                    _ = try Planner.make(plan.request, on: before.layout)
                } else if [.expandPartition, .shrinkPartition, .shrinkAPFS, .growAPFS, .createLinux].contains(step) {
                    let job = DeviceJob(source: source, step: step, plan: plan, expectedGPT: before.gpt,
                                        expectedContainerBytes: before.layout.containerBytes)
                    let result = try runWorker(job: job, record: &record, stateDirectory: stateDirectory,
                                               stateFile: stateFile, executable: executable)
                    if result.outcome != .success {
                        record.operation.status = result.outcome == .unknown ? .unknown : .stopped
                        record.operation.workerPID = nil
                        record.operation.message = result.message
                        try? DeviceJournal.write(record, to: stateFile)
                        throw ResizeError(result.message)
                    }
                    let after = try DeviceInspector.inspect(source, queryMinimum: false)
                    if step.isResize {
                        guard after.layout.containerBytes == plan.targetBytes, after.gpt == before.gpt else {
                            throw ResizeError("APFS resize returned success, but independent APFS/GPT readback did not match the plan.")
                        }
                    } else {
                        let stepAdd = step == .createLinux ? plan.after.partitions.first { candidate in
                            !before.layout.partitions.contains(where: { $0.id == candidate.id })
                        } : nil
                        let expected = try before.gpt.changingEnd(partitionID: before.layout.backingPartitionID,
                                                                 to: step == .createLinux ? before.layout.apfs.lastLBA : plan.after.apfs.lastLBA,
                                                                 adding: stepAdd)
                        guard after.gpt == expected else {
                            throw ResizeError("GPT write returned success, but independent readback did not match.")
                        }
                    }
                } else if step == .verifyAPFS {
                    guard before.layout.containerBytes == plan.targetBytes else {
                        throw ResizeError("APFS container capacity (\(before.layout.containerBytes)) did not match target (\(plan.targetBytes)).")
                    }
                } else if step == .verifyPartition {
                    guard before.layout.backingBytes == plan.targetBytes else {
                        throw ResizeError("Backing partition size (\(before.layout.backingBytes)) did not match target (\(plan.targetBytes)).")
                    }
                } else if step == .verifyLayout {
                    let originalGPT = try JSONDecoder().decode(GPTImage.self, from: Data(contentsOf: backupURL))
                    guard before.layout.containerBytes == plan.targetBytes,
                          before.layout.backingBytes == plan.targetBytes,
                          samePartitions(before.layout.partitions, plan.after.partitions),
                          before.gpt.mbr == originalGPT.mbr else {
                        throw ResizeError("Final layout verification failed against approved plan.")
                    }
                }
                record.operation.completedSteps.append(step)
                record.operation.stepIndex += 1
                record.operation.stepStartedAt = Date()
                record.operation.workerPID = nil
                record.workerJob = nil
                try DeviceJournal.write(record, to: stateFile)
            }
            let final = try DeviceInspector.inspect(source, queryMinimum: true, allowReadOnlyMinimum: true)
            record.operation.status = .completed
            record.operation.observedCapacityBytes = final.layout.containerBytes
            record.operation.observedAt = final.observedAt
            record.operation.message = "Completed and verified from APFS superblock/checkpoint ring and both GPT copies."
            try DeviceJournal.write(record, to: stateFile)
            print("")
            print("SUCCESS: \(record.operation.message ?? "")")
            try printLayout(final, env: env, json: options.jsonOutput)
        } catch {
            if record.operation.status == .running {
                record.operation.status = .unknown
                record.operation.workerPID = nil
                record.operation.message = error.localizedDescription + " No remaining stage was attempted."
                try? DeviceJournal.write(record, to: stateFile)
            }
            throw error
        }
    }

    private static func validateShrinkSafety(inspection: DeviceInspection, layout: StorageLayout,
                                             requestedBytes: Int64, options: Options, isFixture: Bool) throws {
        let alignment = max(Int64(4096), layout.sectorSize)
        let alignedTarget = alignDown(requestedBytes, to: alignment)
        guard alignedTarget > 0 else { throw ResizeError("Target size is too small after sector alignment.") }
        guard alignedTarget <= layout.containerBytes else {
            throw ResizeError("Refusing to grow with --shrink-to: requested \(formatSize(alignedTarget)) exceeds current APFS container \(formatSize(layout.containerBytes)).")
        }
        guard alignedTarget < layout.backingBytes else {
            throw ResizeError("Target \(formatSize(alignedTarget)) does not shrink the backing partition (\(formatSize(layout.backingBytes))).")
        }
        let trailing = layout.partitions.filter { $0.firstLBA > layout.apfs.lastLBA }
        if !trailing.isEmpty {
            let names = trailing.map { "\($0.bsdName) (\($0.kind.rawValue))" }.joined(separator: ", ")
            throw ResizeError("Refusing to shrink while partition(s) exist after APFS: \(names).")
        }
        if !options.allowOtherPartitions {
            let unknown = layout.partitions.filter { $0.kind == .other }
            if !unknown.isEmpty {
                let names = unknown.map { "\($0.bsdName) type=\($0.typeGUID)" }.joined(separator: ", ")
                throw ResizeError("Refusing unknown partition(s) on \(layout.diskName): \(names). Pass --allow-other-partitions only if verified safe.")
            }
        }
        if !isFixture && alignedTarget < layout.containerBytes {
            guard let minimum = layout.minimumContainerBytes else {
                let statusText = inspection.minimumQueryStatus.map { DeviceWorker.describeAPFSStatus($0) } ?? "unavailable"
                throw ResizeError("APFSContainerGetMinimalSize did not return a valid shrink floor (status: \(statusText)). Refusing to shrink.")
            }
            if alignedTarget < minimum {
                var detail = "Requested \(formatSize(alignedTarget)) is below the kernel's minimum container size \(formatSize(minimum))."
                let allSnaps = inspection.snapshots.flatMap { vol in vol.names.map { "\(vol.mountPoint):\($0)" } }
                if !allSnaps.isEmpty {
                    detail += " Active APFS snapshots can pin the minimum size via their block tidemark: \(allSnaps.joined(separator: ", "))."
                }
                throw ResizeError(detail)
            }
        }
        let minFreeBytes = options.minFreeMiB * 1_048_576
        if alignedTarget - layout.allocatedBytes < minFreeBytes {
            throw ResizeError("Requested \(formatSize(alignedTarget)) leaves less than \(options.minFreeMiB) MiB free inside APFS (allocated \(formatSize(layout.allocatedBytes))). Increase target size or pass --min-free-mib.")
        }
    }

    private static func runWorker(job: DeviceJob, record: inout Record, stateDirectory: URL,
                                  stateFile: URL, executable: String) throws -> WorkerResult {
        let jobURL = stateDirectory.appendingPathComponent("jobs/\(job.id.uuidString).job.json")
        try DeviceJournal.write(job, to: jobURL)
        record.workerJob = jobURL
        try DeviceJournal.write(record, to: stateFile)
        var pid: pid_t = 0
        var releaseFD: Int32 = -1
        let spawnStatus = raf_spawn_worker(executable, jobURL.path, &pid, &releaseFD)
        guard spawnStatus == 0 else {
            return WorkerResult(jobID: job.id, outcome: .refused,
                                message: "Could not start worker: \(String(cString: strerror(spawnStatus))).")
        }
        defer { if releaseFD >= 0 { close(releaseFD) } }
        record.operation.workerPID = pid
        record.operation.lastConfirmedAt = Date()
        try DeviceJournal.write(record, to: stateFile)
        guard raf_release_worker(releaseFD) == 0 else {
            throw ResizeError("Could not release prepared worker.")
        }
        close(releaseFD); releaseFD = -1

        let started = Date()
        var lastTick = 0
        while true {
            var exitStatus: Int32 = 0
            let state = raf_poll_worker(pid, &exitStatus)
            if state != 0 {
                record.operation.workerPID = nil
                guard state == 1, exitStatus == 0,
                      let data = try? Data(contentsOf: DeviceWorker.resultURL(for: jobURL)),
                      let result = try? JSONDecoder().decode(WorkerResult.self, from: data),
                      result.jobID == job.id else {
                    return WorkerResult(jobID: job.id, outcome: .unknown,
                                        message: "Worker (pid \(pid)) exited with status \(exitStatus) without a valid completion record.")
                }
                return result
            }
            let elapsed = Int(Date().timeIntervalSince(started))
            if elapsed >= lastTick + 5 {
                lastTick = elapsed
                print("  ... worker pid \(pid) running (\(elapsed)s elapsed)")
                fflush(stdout)
            }
            usleep(500_000)
        }
    }

    private static func printLayout(_ inspection: DeviceInspection, env: RuntimeEnvironment, json: Bool) throws {
        if json {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            let report = LayoutReport(environment: env, layout: inspection.layout,
                                      transactionID: inspection.transactionID,
                                      minimumQueryStatus: inspection.minimumQueryStatus,
                                      snapshots: inspection.snapshots)
            print(String(decoding: try encoder.encode(report), as: UTF8.self))
            return
        }
        let l = inspection.layout
        print("=== Resize APFS Storage Layout ===")
        print("Environment     : \(env.summary)")
        print("Disk            : \(l.diskName) (\(l.deviceName))")
        print("Disk GUID       : \(l.diskID.uuidString)")
        print("Geometry        : \(l.totalBlocks) sectors x \(l.sectorSize) B = \(formatSize(l.totalBytes))")
        print("Usable LBAs     : \(l.firstUsableLBA) .. \(l.lastUsableLBA)")
        print("")
        print("GPT Partitions (\(l.partitions.count)):")
        for p in l.partitions {
            let bytes = p.blocks * l.sectorSize
            print("  \(p.bsdName)  [\(p.kind.rawValue)]  LBA \(p.firstLBA)..\(p.lastLBA)  \(formatSize(bytes))  name=\"\(p.name)\"  type=\(p.typeGUID)")
        }
        print("")
        print("APFS Container (\(l.apfs.bsdName)):")
        print("  Container UUID : \(l.containerID.uuidString)")
        print("  Checkpoint XID : \(inspection.transactionID)")
        print("  Backing part   : \(formatSize(l.backingBytes))")
        print("  Container size : \(formatSize(l.containerBytes))")
        print("  Allocated      : \(formatSize(l.allocatedBytes))")
        print("  Free inside    : \(formatSize(l.freeInsideBytes))")
        if let minBytes = l.minimumContainerBytes {
            let maxRelease = max(0, l.backingBytes - minBytes)
            print("  Kernel minimum : \(formatSize(minBytes))  (max releasable: \(formatSize(maxRelease)))")
        } else if let st = inspection.minimumQueryStatus {
            print("  Kernel minimum : unavailable (APFSContainerGetMinimalSize returned \(DeviceWorker.describeAPFSStatus(st)))")
        } else {
            print("  Kernel minimum : not queried (fixture mode)")
        }
        print("  Unallocated    : \(formatSize(l.allUnallocatedBytes)) (adjacent after APFS: \(formatSize(l.adjacentFreeBytes)))")
        if !inspection.snapshots.isEmpty {
            print("")
            print("APFS Snapshots (read-only check; snapshots pin kernel minimum via block tidemark):")
            for vol in inspection.snapshots {
                if let err = vol.error {
                    print("  \(vol.mountPoint): query error \(err) (\(String(cString: strerror(err))))")
                } else if vol.names.isEmpty {
                    print("  \(vol.mountPoint): none")
                } else {
                    print("  \(vol.mountPoint): \(vol.names.joined(separator: ", "))")
                }
            }
        }
    }

    private static func printPlan(_ plan: ResizePlan, inspection: DeviceInspection, env: RuntimeEnvironment,
                                  releasedBytes: Int64, dryRun: Bool, json: Bool) throws {
        if json {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            let report = PlanReport(environment: env, dryRun: dryRun, plan: plan,
                                    snapshots: inspection.snapshots, releasedTrailingBytes: releasedBytes)
            print(String(decoding: try encoder.encode(report), as: UTF8.self))
            return
        }
        print(dryRun ? "=== DRY-RUN SHRINK PLAN (no changes made) ===" : "=== EXECUTING SHRINK PLAN ===")
        print("Environment     : \(env.summary)")
        print("Target APFS     : \(formatSize(plan.targetBytes))\(plan.alignmentChanged ? " (aligned down from \(plan.request.requestedBytes) B)" : "")")
        print("Before APFS     : \(formatSize(plan.before.containerBytes))  LBA \(plan.before.apfs.firstLBA)..\(plan.before.apfs.lastLBA)")
        print("After  APFS     : \(formatSize(plan.after.containerBytes))  LBA \(plan.after.apfs.firstLBA)..\(plan.after.apfs.lastLBA)")
        print("Allocated       : \(formatSize(plan.before.allocatedBytes))  (free after shrink: \(formatSize(plan.targetBytes - plan.before.allocatedBytes)))")
        if let minBytes = plan.before.minimumContainerBytes {
            print("Kernel minimum  : \(formatSize(minBytes))")
        }
        let trailingFirst = plan.after.apfs.lastLBA + 1
        let trailingLast = plan.after.lastUsableLBA
        print("Freed space     : \(formatSize(releasedBytes))  (unallocated LBAs \(trailingFirst)..\(trailingLast))")
        print("Steps           : \(plan.steps.map(\.rawValue).joined(separator: " -> "))")
        if dryRun {
            print("")
            print("Dry-run checks PASSED. Re-run with --yes to execute.")
        }
    }

    private static func printStatus(stateDirectory: URL, env: RuntimeEnvironment, json: Bool) throws {
        let stateFile = stateDirectory.appendingPathComponent("operation.json")
        guard FileManager.default.fileExists(atPath: stateFile.path) else {
            if json { print("{\"status\":\"idle\"}") }
            else { print("Environment: \(env.summary)\nNo recorded operation in \(stateDirectory.path).") }
            return
        }
        let data = try Data(contentsOf: stateFile)
        if json {
            print(String(decoding: data, as: UTF8.self))
            return
        }
        let record = try JSONDecoder().decode(Record.self, from: data)
        let op = record.operation
        print("Environment : \(env.summary)")
        print("Operation   : \(op.id.uuidString)")
        print("Status      : \(op.status.rawValue)")
        print("Target      : \(formatSize(op.plan.targetBytes))")
        print("Steps done  : \(op.completedSteps.map(\.rawValue).joined(separator: ", "))")
        if let msg = op.message { print("Message     : \(msg)") }
    }

    private static func printUsage(executable: String) {
        print("""
        Usage: \(executable) [options]

        Modes:
          --layout                 Inspect disk0 GPT, APFS container, kernel minimum, and snapshots (read-only).
          --shrink-to <size>       Plan shrinking APFS + GPT partition to <size> (dry-run unless --yes is passed).
                                   Bare numbers are GiB (e.g. 10 = 10 GiB); suffixes GiB, GB, MiB, MB, B accepted.
          --status                 Show the last recorded operation and backup state.
          --daemon                 Run the local IPC daemon for the iOS 15+ Resize APFS app (palera1n overlay).

        Options:
          --yes                    Execute the planned shrink (requires --shrink-to).
          --create-linux           Also create an unformatted Linux GPT partition in the freed space.
          --min-free-mib <MiB>     Minimum free headroom kept inside APFS (default: 512).
          --allow-other-partitions Permit shrinking when non-APFS partitions precede APFS on disk0.
          --state-dir <path>       Journal & GPT backup directory (default: /var/root/Library/ResizeAPFS).
          --json                   Output layout/plan/status as JSON.
          --fixture <file>         Host-only regular-file disk fixture (refused on iOS).
          --sector-size <bytes>    Sector size for --fixture (default: 4096).
          -h, --help               Show this help.
        """)
    }

    private static func formatSize(_ bytes: Int64) -> String {
        let gib = Double(bytes) / 1_073_741_824.0
        let gb = Double(bytes) / 1_000_000_000.0
        return String(format: "%.2f GiB (%.2f GB, %lld B)", gib, gb, bytes)
    }

    private static func samePartitions(_ lhs: [Partition], _ rhs: [Partition]) -> Bool {
        lhs.count == rhs.count && lhs.allSatisfy { p in
            rhs.contains { q in
                p.id == q.id && p.name == q.name && p.firstLBA == q.firstLBA
                    && p.lastLBA == q.lastLBA && p.typeGUID == q.typeGUID
            }
        }
    }

    private static func bootIdentity() -> String {
        var time = timeval(), length = MemoryLayout<timeval>.size
        guard sysctlbyname("kern.boottime", &time, &length, nil, 0) == 0 else { return "unknown-boot" }
        return "\(time.tv_sec):\(time.tv_usec)"
    }
}
