import SwiftUI
import ResizeCore

struct RootView: View {
    @ObservedObject var model: AppModel
    @Environment(\.horizontalSizeClass) private var sizeClass
    @State private var confirmApply = false
    private var roomy: Bool { sizeClass == .regular }
    private var contentWidth: CGFloat { 920 }
    private var pageIdentity: String {
        if [.submitting, .running, .verifying].contains(model.state) || (model.state == .reconnecting && model.operation != nil) { return "operation" }
        return model.state.rawValue
    }

    var body: some View {
        NavigationView {
            ScrollView {
                VStack(alignment: .leading, spacing: roomy ? 30 : 22) {
                    header
                    if let error = model.error {
                        Label(error, systemImage: "exclamationmark.circle")
                            .font(.subheadline).foregroundStyle(Palette.destructive)
                            .accessibilityIdentifier("serviceError")
                    }
                    switch model.state {
                    case .loading: connectionView
                    case .overview: overview
                    case .editor: editor
                    case .review: review
                    case .submitting, .running, .verifying: progress
                    case .completed, .stopped: result
                    case .reconnecting:
                        if model.operation != nil { progress }
                        else { connectionView }
                    }
                }
                .frame(maxWidth: contentWidth).padding(.horizontal, roomy ? 36 : 20)
                .padding(.top, 24).padding(.bottom, 24).frame(maxWidth: .infinity)
            }
            .id(pageIdentity)
            .dismissKeyboardOnScrollWhenAvailable()
            .background(Palette.background)
            .safeAreaInset(edge: .bottom, spacing: 0) {
                footer.frame(maxWidth: contentWidth).padding(.horizontal, roomy ? 36 : 20)
                    .padding(.top, 12).padding(.bottom, 16).frame(maxWidth: .infinity)
                    .background(Palette.background)
            }
            .navigationBarHidden(true)
            .toolbar {
                ToolbarItem(placement: .keyboard) {
                    Button("Done") { UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil) }
                }
            }
            .tint(Palette.blue)
            .sheet(isPresented: $model.showLab) { MockLabView(model: model) }
            .sheet(isPresented: $model.showTechnical) {
                if let layout = model.layout { TechnicalView(layout: layout, isMock: model.isSimulator) }
            }
            .alert("Start resizing?", isPresented: $confirmApply) {
                Button("Cancel", role: .cancel) {}
                Button("Start resize", role: .destructive) { Task { await model.apply() } }
                    .accessibilityIdentifier("confirmStart")
            } message: {
                Text(model.isSimulator ? "Apply the changes you reviewed? This simulator build changes mock storage only." : "Apply these changes to internal storage? Keep power connected and do not restart until the result is verified.")
            }
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 22) {
            if [.editor, .review].contains(model.state) {
                HStack {
                    Button { model.back() } label: {
                        Label(model.state == .review ? "Adjust size" : "Storage", systemImage: "chevron.left")
                    }.accessibilityIdentifier("back")
                    Spacer()
                    Button("Cancel") { model.back(); if model.state == .editor { model.back() } }
                }.buttonStyle(.plain)
            } else {
                HStack(alignment: .top) {
                    HStack(spacing: 12) {
                        if roomy {
                            Image(systemName: "internaldrive").font(.title2).foregroundStyle(.white)
                                .frame(width: 48, height: 48).background(Palette.blue, in: RoundedRectangle(cornerRadius: 13))
                        }
                        VStack(alignment: .leading, spacing: 8) {
                            Text("Resize APFS").font(roomy ? .title2.weight(.bold) : .largeTitle.weight(.bold))
                            if !roomy { environmentLabel }
                        }
                    }
                    Spacer(minLength: 8)
                    VStack(alignment: .trailing, spacing: 8) {
                        if roomy { environmentLabel }
                        if model.isSimulator {
                            Button { model.showLab = true } label: { Image(systemName: "flask").font(.title3) }
                                .accessibilityLabel("Mock scenarios").accessibilityIdentifier("mockScenarios")
                        }
                    }
                }
            }
        }
    }
    private var environmentLabel: some View {
        Text(model.isSimulator ? "Simulator · Mock storage" : "Experimental")
            .font(.subheadline).foregroundStyle(.secondary)
    }

    private var overview: some View {
        VStack(alignment: .leading, spacing: 24) {
            Text("Storage overview").font(.largeTitle.weight(.bold)).accessibilityIdentifier("storageOverview")
            if let layout = model.layout {
                layoutCard(layout, title: "Disk layout")
                Surface {
                    Label("APFS container", systemImage: "square.3.layers.3d").font(.title3.weight(.semibold))
                    Text(layout.apfs.bsdName).font(.subheadline).foregroundStyle(.secondary)
                    if layout.containerBytes != layout.backingBytes {
                        Text("APFS uses \(Capacity.gb(layout.containerBytes)) of its \(Capacity.gb(layout.backingBytes)) partition.")
                            .font(.subheadline).foregroundStyle(.secondary)
                    }
                    Text(Capacity.gb(layout.containerBytes)).font(.largeTitle.weight(.medium)).monospacedDigit()
                    HStack {
                        Text("\(Capacity.gb(layout.allocatedBytes)) allocated")
                        Spacer()
                        Text("\(Capacity.gb(layout.freeInsideBytes)) free").foregroundStyle(.secondary)
                    }.font(.subheadline)
                    ProgressView(value: Double(layout.allocatedBytes), total: Double(layout.containerBytes)).tint(Palette.blue)
                    ValueRow(title: "Adjacent unallocated space", value: Capacity.gb(layout.adjacentFreeBytes))
                    if let issue = layout.issue {
                        Label(issue, systemImage: "exclamationmark.triangle").foregroundStyle(Palette.destructive).font(.subheadline)
                    }
                    Divider()
                    Button { model.showTechnical = true } label: {
                        HStack { Text("Technical details"); Spacer(); Image(systemName: "chevron.right") }
                    }.buttonStyle(.plain).accessibilityIdentifier("technicalDetails")
                }
            }
        }
    }

    private var editor: some View {
        VStack(alignment: .leading, spacing: 24) {
            Text("Adjust size").font(.largeTitle.weight(.bold))
            if let layout = model.layout {
                Surface {
                    HStack(alignment: .top, spacing: 16) {
                        SizeField(title: "New APFS size", identifier: "targetSize", text: Binding(get: { model.targetText }, set: model.setTarget))
                        SizeField(title: "Free space after", identifier: "freeAfter", text: Binding(get: { model.freeText }, set: model.setFree))
                    }
                    StorageMap(layout: model.localPlan?.after ?? layout)
                    Slider(value: Binding(get: {
                        let current = Double(Capacity.parseGB(model.targetText) ?? layout.containerBytes) / 1e9
                        return min(max(current, Double(layout.minimumContainerBytes ?? layout.containerBytes) / 1e9), Double(layout.maximumBytes) / 1e9)
                    }, set: { value in
                        if value >= Double(layout.maximumBytes) / 1e9 - 0.05 { model.useAvailable() }
                        else { model.setTarget(String(format: "%.1f", value)) }
                    }), in: Double(layout.minimumContainerBytes ?? layout.containerBytes) / 1e9...Double(layout.maximumBytes) / 1e9)
                        .accessibilityLabel("APFS size in gigabytes").accessibilityIdentifier("sizeSlider")
                    HStack {
                        Text("\(Capacity.gb(layout.freeInsideBytes)) free within APFS.").font(.caption).foregroundStyle(.secondary)
                        Spacer()
                        Button("Use available space") { model.useAvailable() }.font(.caption.weight(.semibold))
                            .accessibilityIdentifier("useAvailable")
                    }
                    if let message = model.editorMessage {
                        Text(message).font(.caption).foregroundStyle(.secondary).accessibilityIdentifier("sizeValidation")
                    }
                }
                Surface {
                    Text("Resulting layout").font(.headline)
                    ValueRow(title: "APFS container", value: Capacity.gb(model.localPlan?.targetBytes ?? layout.containerBytes))
                    ValueRow(title: "Backing partition", value: Capacity.gb(model.localPlan?.after.backingBytes ?? layout.backingBytes))
                    ValueRow(title: "Unallocated space", value: Capacity.gb(model.localPlan?.after.allUnallocatedBytes ?? layout.allUnallocatedBytes))
                    if model.createLinux, let linux = model.localPlan?.after.partitions.last(where: { $0.kind == .linux }) {
                        ValueRow(title: "Linux · unformatted", value: Capacity.gb(linux.blocks * layout.sectorSize))
                    }
                }
                if model.canCreateLinuxPartition {
                    Surface {
                        Text("Space after APFS").font(.headline)
                        choice("Leave unallocated", selected: !model.createLinux) { model.createLinux = false }
                        choice("Create Linux partition", subtitle: "Unformatted; format later in Linux.", selected: model.createLinux) { model.createLinux = true }
                            .accessibilityIdentifier("createLinux")
                    }
                }
            }
        }
    }

    private func choice(_ title: String, subtitle: String? = nil, selected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(alignment: .top, spacing: 14) {
                Image(systemName: selected ? "largecircle.fill.circle" : "circle").font(.title3)
                    .foregroundStyle(selected ? Palette.blue : .secondary)
                VStack(alignment: .leading, spacing: 4) {
                    Text(title).foregroundStyle(.primary)
                    if let subtitle { Text(subtitle).font(.caption).foregroundStyle(.secondary) }
                }
                Spacer()
            }.padding(.vertical, 8).contentShape(Rectangle())
        }.buttonStyle(.plain).accessibilityAddTraits(selected ? .isSelected : [])
    }

    private var review: some View {
        VStack(alignment: .leading, spacing: 24) {
            Text("Review changes").font(.largeTitle.weight(.bold)).accessibilityIdentifier("reviewHeading")
            if let plan = model.reviewedPlan {
                Surface {
                    Text("Your new layout").font(.title3.weight(.semibold))
                    ValueRow(title: "APFS container", value: "\(Capacity.gb(plan.before.containerBytes)) → \(Capacity.gb(plan.targetBytes))", emphasized: true)
                    if plan.before.backingBytes != plan.before.containerBytes {
                        ValueRow(title: "Backing partition", value: "\(Capacity.gb(plan.before.backingBytes)) → \(Capacity.gb(plan.after.backingBytes))")
                    }
                    StorageMap(layout: plan.after)
                    Text(plan.request.createLinux ? "The space after APFS becomes an unformatted Linux partition." : "No Linux partition will be created. Any remaining space stays unallocated.")
                        .font(.subheadline).foregroundStyle(.secondary)
                    if plan.alignmentChanged {
                        Text("Adjusted to \(plan.targetBytes.formatted()) bytes for \(max(4096, plan.before.sectorSize).formatted())-byte alignment.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
                Surface {
                    Text("What will happen").font(.title3.weight(.semibold))
                    ForEach(Array(plan.steps.filter { ![.checking, .preparing].contains($0) }.enumerated()), id: \.offset) { index, step in
                        HStack(alignment: .top, spacing: 14) {
                            Text("\(index + 1)").font(.subheadline.weight(.semibold))
                                .frame(width: 28, height: 28).background(Palette.background, in: Circle())
                            VStack(alignment: .leading, spacing: 4) {
                                Text(step.title).fontWeight(.medium)
                                Text(step.detail).font(.caption).foregroundStyle(.secondary)
                            }
                        }
                    }
                }
                ResizeWarning(beforeApplying: true)
            }
        }
    }

    private var progress: some View {
        VStack(spacing: 26) {
            VStack(spacing: 16) {
                ProgressView().tint(Palette.blue)
                    .frame(width: 72, height: 72).background(Palette.blue.opacity(0.07), in: Circle())
                Text(model.state == .reconnecting ? "Checking operation status" : (model.operation?.currentStep?.title ?? "Starting operation"))
                    .font(.largeTitle.weight(.bold)).multilineTextAlignment(.center).accessibilityIdentifier("operationHeading")
                Text(model.layout?.apfs.bsdName ?? "Internal storage").font(.subheadline).foregroundStyle(.secondary)
                Text(model.operation?.currentStep?.isResize == true ? "This may take many minutes." : "Checking the requested storage changes.")
                    .foregroundStyle(.secondary)
            }.frame(maxWidth: .infinity).padding(.vertical, 24)
            if let op = model.operation {
                Surface {
                    ForEach(Array(op.plan.steps.enumerated()), id: \.offset) { index, step in
                        VStack(alignment: .leading, spacing: 12) {
                            HStack(spacing: 14) {
                                if op.completedSteps.contains(step) {
                                    Image(systemName: "checkmark.circle").foregroundStyle(Palette.green).font(.title3)
                                } else if index == op.stepIndex {
                                    ProgressView().tint(Palette.blue)
                                } else {
                                    Image(systemName: "circle").foregroundStyle(Color.secondary.opacity(0.5)).font(.title3)
                                }
                                Text(step.title).fontWeight(index == op.stepIndex ? .semibold : .regular)
                                    .foregroundStyle(index == op.stepIndex ? Palette.blue : .secondary)
                                Spacer()
                            }
                            if index == op.stepIndex && step.isResize {
                                TimelineView(.periodic(from: .now, by: 1)) { timeline in
                                    activity(op, now: timeline.date)
                                }.padding(.leading, 34)
                            }
                        }
                    }
                }
            } else { Text("Confirming whether the service accepted the operation. No start request will be repeated.").font(.subheadline).foregroundStyle(.secondary) }
            ResizeWarning()
        }
    }

    private func activity(_ op: ResizeCore.Operation, now: Date) -> some View {
        let age = op.lastConfirmedAt.map { max(0, now.timeIntervalSince($0)) }
        let fresh = WorkerConfirmation.isFresh(pid: op.workerPID, confirmedAt: op.lastConfirmedAt,
                                               connectionAvailable: model.connectionOK, now: now)
        return VStack(spacing: 9) {
            ValueRow(title: "Resize process", value: fresh ? "Active · PID \(op.workerPID.map(String.init) ?? "—")" : "Status unavailable", valueIdentifier: "workerStatus")
            ValueRow(title: "Last confirmed", value: age.map { "\(Int($0)) seconds ago" } ?? "Not confirmed", valueIdentifier: "workerLastConfirmed")
            ValueRow(title: "Elapsed", value: elapsed(now.timeIntervalSince(op.startedAt)), valueIdentifier: "workerElapsed")
            VStack(alignment: .leading, spacing: 9) {
                Text("APFS capacity").font(.subheadline).foregroundStyle(.secondary)
                VStack(spacing: 9) {
                    ValueRow(title: "Before", value: Capacity.gb(op.plan.before.containerBytes))
                    ValueRow(title: "Current", value: op.observedCapacityBytes.map(Capacity.gb) ?? "Unavailable")
                    ValueRow(title: "Target", value: Capacity.gb(op.plan.targetBytes))
                }.padding(.leading, 12)
            }.frame(maxWidth: .infinity, alignment: .leading)
            if let observedAt = op.observedAt {
                Text("Capacity observation \(Int(max(0, now.timeIntervalSince(observedAt)))) seconds ago.")
                    .font(.caption2).foregroundStyle(.secondary).frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }
    private func elapsed(_ interval: TimeInterval) -> String {
        let seconds = max(0, Int(interval))
        return seconds < 60 ? "\(seconds) seconds" : "\(seconds / 60) min \(seconds % 60) sec"
    }

    private var result: some View {
        VStack(spacing: 24) {
            if let op = model.operation, let layout = model.layout {
                let success = op.status == .completed
                let unknown = op.status == .unknown
                VStack(spacing: 16) {
                    Image(systemName: success ? "checkmark.circle" : "exclamationmark.triangle")
                        .font(.system(size: 46)).foregroundStyle(success ? Palette.green : Palette.destructive)
                    Text(success ? "Completed and verified" : unknown ? "Couldn’t verify the result" : "Changes could not be completed")
                        .font(.largeTitle.weight(.bold)).multilineTextAlignment(.center)
                        .accessibilityIdentifier(success ? "operationCompleted" : "operationStopped")
                    Text(op.message ?? "Inspect the operation status before continuing.")
                        .font(.subheadline).foregroundStyle(.secondary).multilineTextAlignment(.center)
                }.frame(maxWidth: .infinity).padding(.vertical, 20)
                layoutCard(layout, title: success ? "Verified final layout" : "Latest observed layout")
                Surface {
                    ValueRow(title: "APFS container", value: Capacity.gb(layout.containerBytes))
                    ValueRow(title: "Backing partition", value: Capacity.gb(layout.backingBytes))
                    ValueRow(title: "Unallocated space", value: Capacity.gb(layout.allUnallocatedBytes))
                    ForEach(op.completedSteps.filter { [.verifyAPFS, .verifyPartition, .verifyLayout, .createLinux].contains($0) }, id: \.self) { step in
                        Label(step.title, systemImage: "checkmark.circle").foregroundStyle(Palette.green).font(.subheadline)
                    }
                    if unknown {
                        Text("No automatic retry was sent. Checking status does not repeat the resize.")
                            .font(.subheadline).foregroundStyle(.secondary)
                    } else if !success {
                        Text("The worker has stopped. You can inspect storage and review a new plan.")
                            .font(.subheadline).foregroundStyle(.secondary)
                    }
                    if op.plan.request.createLinux {
                        Text("Linux partition created without formatting. Format it later in Linux.")
                            .font(.subheadline).foregroundStyle(.secondary)
                    }
                    if model.isSimulator {
                        Text("Mock result only. No physical storage was changed.").font(.caption).foregroundStyle(.secondary)
                    } else {
                        Text("Metadata readback does not replace a data backup or full filesystem-integrity check.").font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
        }
    }

    private func layoutCard(_ layout: StorageLayout, title: String) -> some View {
        Surface {
            HStack {
                Text(title.uppercased()).font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                Spacer()
                Label(roomy ? "Internal storage" : layout.diskName, systemImage: "internaldrive").font(.subheadline.weight(.medium))
                Text(Capacity.gb(layout.totalBytes)).font(.caption.monospacedDigit()).foregroundStyle(.secondary)
            }
            StorageMap(layout: layout)
            Text("Unallocated outside partitions: \(Capacity.gb(layout.allUnallocatedBytes))")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    private var connectionView: some View {
        VStack(alignment: .leading, spacing: 24) {
            Text(model.isSimulator ? "Connect to the mock service" : "Connecting to storage helper")
                .font(.largeTitle.weight(.bold))
            Surface {
                Label("Checking service status", systemImage: "network").font(.headline)
                Text(model.isSimulator ? "Start the independent Mac service, then return here. The app reconnects automatically." : (model.connectionMessage ?? "Waiting for the privileged helper supplied by the custom palera1n overlay. The app reconnects automatically."))
                    .foregroundStyle(.secondary)
                if model.isSimulator {
                    Text("./scripts/mock-server.sh").font(.system(.subheadline, design: .monospaced)).textSelection(.enabled)
                    Text("http://127.0.0.1:8472").font(.caption).foregroundStyle(.secondary)
                }
            }
        }
    }

    @ViewBuilder private var footer: some View {
        switch model.state {
        case .overview:
            ActionButton(title: "Adjust size", identifier: "adjustSize", disabled: model.layout?.issue != nil) { model.edit() }
        case .editor:
            ActionButton(title: "Review changes", identifier: "reviewChanges", disabled: model.localPlan == nil, busy: model.busy) {
                Task { await model.review() }
            }
        case .review:
            ActionButton(title: "Apply changes", identifier: "applyChanges", destructive: true, busy: model.busy) { confirmApply = true }
        case .completed:
            ActionButton(title: "Done", identifier: "done") { model.done() }
        case .stopped:
            if model.operation?.status == .unknown {
                ActionButton(title: "Check status", identifier: "checkStatus") { Task { await model.refresh() } }
            } else {
                ActionButton(title: "Back to storage", identifier: "backToStorage") { model.done() }
            }
        case .reconnecting:
            Text("Reconnecting. No resize request will be repeated.").font(.caption).foregroundStyle(.secondary)
        default: EmptyView()
        }
    }
}
