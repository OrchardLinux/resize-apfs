import Foundation

public enum OperationStep: String, Codable, CaseIterable, Sendable {
    case checking, preparing, expandPartition, verifyPartition, shrinkAPFS, growAPFS
    case verifyAPFS, shrinkPartition, createLinux, verifyLayout

    public var title: String {
        switch self {
        case .checking: return "Checking storage"
        case .preparing: return "Preparing changes"
        case .expandPartition: return "Expanding backing partition"
        case .verifyPartition: return "Verifying partition table"
        case .shrinkAPFS: return "Shrinking APFS"
        case .growAPFS: return "Growing APFS"
        case .verifyAPFS: return "Verifying APFS"
        case .shrinkPartition: return "Shrinking backing partition"
        case .createLinux: return "Creating Linux partition"
        case .verifyLayout: return "Verifying storage layout"
        }
    }
    public var isResize: Bool { self == .shrinkAPFS || self == .growAPFS }
    public var detail: String {
        switch self {
        case .shrinkAPFS, .growAPFS: return "Use the explicit approved container size."
        case .expandPartition, .shrinkPartition: return "Keep the partition's starting position and identity."
        case .verifyPartition: return "Check both GPT copies before growing APFS."
        case .verifyAPFS: return "Confirm the container size before continuing."
        case .createLinux: return "Create an unformatted Linux filesystem-data partition."
        case .verifyLayout: return "Check the resulting layout against the approved plan."
        default: return "Validate the selected storage and operation."
        }
    }
}

public struct PlanRequest: Codable, Equatable, Sendable {
    public var revision: UUID
    public var requestedBytes: Int64
    public var createLinux: Bool
    public init(revision: UUID, requestedBytes: Int64, createLinux: Bool) {
        self.revision = revision; self.requestedBytes = requestedBytes; self.createLinux = createLinux
    }
}

public struct ResizePlan: Codable, Equatable, Identifiable, Sendable {
    public var id: UUID
    public var request: PlanRequest
    public var before: StorageLayout
    public var after: StorageLayout
    public var targetBytes: Int64
    public var steps: [OperationStep]
    public var alignmentChanged: Bool { request.requestedBytes != targetBytes }
}

public enum Planner {
    public static func make(_ request: PlanRequest, on layout: StorageLayout) throws -> ResizePlan {
        try layout.validate()
        guard request.revision == layout.revision else { throw ResizeError("Storage changed. Inspect it again before reviewing changes.") }
        guard request.requestedBytes > 0, request.requestedBytes <= layout.maximumBytes else {
            throw ResizeError("The requested size exceeds the contiguous space available after APFS.")
        }
        let alignment = max(Int64(4096), layout.sectorSize)
        let target = alignDown(request.requestedBytes, to: alignment)
        guard target > 0 else { throw ResizeError("The requested size is too small.") }
        if target < layout.containerBytes {
            guard let minimum = layout.minimumContainerBytes else {
                throw ResizeError("The service could not establish a supported shrink limit.")
            }
            guard target >= minimum, target >= layout.allocatedBytes else {
                throw ResizeError("The requested size is below the service's supported shrink limit.")
            }
        }
        if target > layout.containerBytes && !layout.growthSupported {
            throw ResizeError("Growing APFS is not available from this service.")
        }

        var after = layout
        let index = after.partitions.firstIndex { $0.id == layout.backingPartitionID }!
        after.partitions[index].lastLBA = layout.apfs.firstLBA + target / layout.sectorSize - 1
        after.containerBytes = target
        var steps: [OperationStep] = [.checking, .preparing]
        if target > layout.backingBytes { steps += [.expandPartition, .verifyPartition] }
        if target < layout.containerBytes { steps += [.shrinkAPFS, .verifyAPFS] }
        if target > layout.containerBytes { steps += [.growAPFS, .verifyAPFS] }
        if target < layout.backingBytes { steps.append(.shrinkPartition) }
        if request.createLinux {
            let first = alignUp(after.apfs.lastLBA + 1, to: max(1, 32_768 / layout.sectorSize))
            let last = layout.followingBoundary
            guard first <= last, last - first + 1 >= 1_048_576 / layout.sectorSize else {
                throw ResizeError("There is not enough adjacent unallocated space for a Linux partition.")
            }
            var number = 1
            while after.partitions.contains(where: { $0.bsdName == "\(layout.diskName)s\(number)" }) { number += 1 }
            after.partitions.append(Partition(name: "Linux", bsdName: "\(layout.diskName)s\(number)", kind: .linux,
                                             firstLBA: first, lastLBA: last, typeGUID: linuxTypeGUID,
                                             contents: "Not formatted by Resize APFS"))
            steps.append(.createLinux)
        }
        guard steps.count > 2 else { throw ResizeError("Choose a different size or create a Linux partition.") }
        steps.append(.verifyLayout)
        after.revision = UUID()
        try after.validate()
        return ResizePlan(id: UUID(), request: request, before: layout, after: after,
                          targetBytes: target, steps: steps)
    }
}
