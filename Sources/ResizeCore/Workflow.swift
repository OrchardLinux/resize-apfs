import Foundation

public enum ScreenState: String, Equatable, Sendable {
    case loading, overview, editor, review, submitting, running, verifying, completed, stopped, reconnecting
}

public struct WorkflowMachine: Sendable {
    public private(set) var state: ScreenState = .loading
    public private(set) var acknowledgedOperationID: UUID?
    public init(acknowledgedOperationID: UUID? = nil) { self.acknowledgedOperationID = acknowledgedOperationID }
    public var isLocked: Bool { [.loading, .submitting, .running, .verifying, .reconnecting].contains(state) }

    public mutating func receive(_ snapshot: ServiceSnapshot) {
        if let op = snapshot.operation {
            switch op.status {
            case .running:
                state = [.verifyAPFS, .verifyPartition, .verifyLayout].contains(op.currentStep) ? .verifying : .running
            case .unknown: state = .stopped
            case .completed, .stopped:
                if op.id != acknowledgedOperationID { state = op.status == .completed ? .completed : .stopped }
                else if ![.editor, .review].contains(state) { state = .overview }
            }
        } else if ![.editor, .review, .submitting].contains(state) { state = .overview }
    }
    public mutating func connectionLost() { state = .reconnecting }
    public mutating func edit() throws {
        guard state == .overview else { throw ResizeError("Storage must be inspected before editing.") }
        state = .editor
    }
    public mutating func review() throws {
        guard state == .editor else { throw ResizeError("Review starts from the size editor.") }
        state = .review
    }
    public mutating func submit() throws {
        guard state == .review else { throw ResizeError("Review and authorize a plan before applying it.") }
        state = .submitting
    }
    public mutating func back() {
        if state == .review { state = .editor }
        else if state == .editor { state = .overview }
    }
    public mutating func acknowledge(_ operation: Operation) throws {
        guard operation.status == .completed || operation.status == .stopped else {
            throw ResizeError("The previous operation's outcome is still unknown. Check status before making changes.")
        }
        acknowledgedOperationID = operation.id
        state = .overview
    }
    public mutating func resetMock() { self = WorkflowMachine() }
}
