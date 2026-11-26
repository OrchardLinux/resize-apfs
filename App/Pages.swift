import UIKit
import ResizeCore

var osName: String { UIDevice.current.systemName }
var osLine: String { "\(UIDevice.current.systemName) \(UIDevice.current.systemVersion)" }

/// The device's name as Apple sells it ("iPad (6th generation)"); iOS itself
/// only says "iPad". The hardware identifier comes from hw.machine; anything not
/// listed (newer than this table) falls back to the generic model and identifier.
var deviceName: String {
    var size = 0
    sysctlbyname("hw.machine", nil, &size, nil, 0)
    var buffer = [CChar](repeating: 0, count: max(1, size))
    sysctlbyname("hw.machine", &buffer, &size, nil, 0)
    let identifier = String(cString: buffer)
    return deviceNames[identifier] ?? (identifier.isEmpty ? UIDevice.current.model : "\(UIDevice.current.model) (\(identifier))")
}
private let deviceNames: [String: String] = [
    "iPad4,1": "iPad Air",
    "iPad4,2": "iPad Air",
    "iPad4,3": "iPad Air",
    "iPad5,3": "iPad Air 2",
    "iPad5,4": "iPad Air 2",
    "iPad11,3": "iPad Air (3rd generation)",
    "iPad11,4": "iPad Air (3rd generation)",
    "iPad13,1": "iPad Air (4th generation)",
    "iPad13,2": "iPad Air (4th generation)",
    "iPad13,16": "iPad Air (5th generation)",
    "iPad13,17": "iPad Air (5th generation)",
    "iPad6,11": "iPad (5th generation)",
    "iPad6,12": "iPad (5th generation)",
    "iPad7,5": "iPad (6th generation)",
    "iPad7,6": "iPad (6th generation)",
    "iPad7,11": "iPad (7th generation)",
    "iPad7,12": "iPad (7th generation)",
    "iPad11,6": "iPad (8th generation)",
    "iPad11,7": "iPad (8th generation)",
    "iPad12,1": "iPad (9th generation)",
    "iPad12,2": "iPad (9th generation)",
    "iPad13,18": "iPad (10th generation)",
    "iPad13,19": "iPad (10th generation)",
    "iPad4,4": "iPad mini 2",
    "iPad4,5": "iPad mini 2",
    "iPad4,6": "iPad mini 2",
    "iPad4,7": "iPad mini 3",
    "iPad4,8": "iPad mini 3",
    "iPad4,9": "iPad mini 3",
    "iPad5,1": "iPad mini 4",
    "iPad5,2": "iPad mini 4",
    "iPad11,1": "iPad mini (5th generation)",
    "iPad11,2": "iPad mini (5th generation)",
    "iPad14,1": "iPad mini (6th generation)",
    "iPad14,2": "iPad mini (6th generation)",
    "iPad6,3": "iPad Pro (9.7-inch)",
    "iPad6,4": "iPad Pro (9.7-inch)",
    "iPad6,7": "iPad Pro (12.9-inch)",
    "iPad6,8": "iPad Pro (12.9-inch)",
    "iPad7,1": "iPad Pro (12.9-inch) (2nd generation)",
    "iPad7,2": "iPad Pro (12.9-inch) (2nd generation)",
    "iPad7,3": "iPad Pro (10.5-inch)",
    "iPad7,4": "iPad Pro (10.5-inch)",
    "iPad8,1": "iPad Pro (11-inch)",
    "iPad8,2": "iPad Pro (11-inch)",
    "iPad8,3": "iPad Pro (11-inch)",
    "iPad8,4": "iPad Pro (11-inch)",
    "iPad8,5": "iPad Pro (12.9-inch) (3rd generation)",
    "iPad8,6": "iPad Pro (12.9-inch) (3rd generation)",
    "iPad8,7": "iPad Pro (12.9-inch) (3rd generation)",
    "iPad8,8": "iPad Pro (12.9-inch) (3rd generation)",
    "iPad8,9": "iPad Pro (11-inch) (2nd generation)",
    "iPad8,10": "iPad Pro (11-inch) (2nd generation)",
    "iPad8,11": "iPad Pro (12.9-inch) (4th generation)",
    "iPad8,12": "iPad Pro (12.9-inch) (4th generation)",
    "iPhone6,1": "iPhone 5s",
    "iPhone6,2": "iPhone 5s",
    "iPhone7,2": "iPhone 6",
    "iPhone7,1": "iPhone 6 Plus",
    "iPhone8,1": "iPhone 6s",
    "iPhone8,2": "iPhone 6s Plus",
    "iPhone8,4": "iPhone SE",
    "iPhone9,1": "iPhone 7",
    "iPhone9,3": "iPhone 7",
    "iPhone9,2": "iPhone 7 Plus",
    "iPhone9,4": "iPhone 7 Plus",
    "iPhone10,1": "iPhone 8",
    "iPhone10,4": "iPhone 8",
    "iPhone10,2": "iPhone 8 Plus",
    "iPhone10,5": "iPhone 8 Plus",
    "iPhone10,3": "iPhone X",
    "iPhone10,6": "iPhone X",
    "iPhone11,2": "iPhone XS",
    "iPhone11,4": "iPhone XS Max",
    "iPhone11,6": "iPhone XS Max",
    "iPhone11,8": "iPhone XR",
    "iPhone12,1": "iPhone 11",
    "iPhone12,3": "iPhone 11 Pro",
    "iPhone12,5": "iPhone 11 Pro Max",
    "iPhone12,8": "iPhone SE (2nd generation)",
    "iPod7,1": "iPod touch (6th generation)",
    "iPod9,1": "iPod touch (7th generation)",
]

/// Builds the page and footer for the model's current state.
struct Pages {
    let root: RootViewController
    let m: Metrics
    var model: AppModel { root.model }
    init(_ root: RootViewController, _ metrics: Metrics) { self.root = root; m = metrics }

    func build() -> [UIView] {
        var views: [UIView] = []
        switch model.accessPhase {
        case .start: return storageAccess(working: false)
        case .getting: return storageAccess(working: true)
        case .failed: return accessFailed()
        case .checking: return connection()
        case .ready: break
        }
        switch model.state {
        case .loading: views += connection()
        case .overview: views += overview()
        case .editor: views.append(root.makeEditor(m))
        case .review: views += review()
        case .submitting, .running, .verifying: views += progress()
        case .completed, .stopped: views += result()
        case .reconnecting: views += model.showsProgress ? progress() : connection()
        }
        return views
    }

    // MARK: Header

    func header() -> UIView {
        if [.editor, .review].contains(model.state) {
            let back = TouchButton(type: .system)
            back.setImage(Icon.chevronLeft.image(16, lineWidth: 2.4), for: .normal)
            back.setTitle(model.state == .review ? " Adjust size" : " Storage", for: .normal)
            back.titleLabel?.font = Theme.font(14)
            back.tintColor = Theme.blue
            back.accessibilityIdentifier = "back"
            back.addAction { [model] in model.back() }
            let cancel = TouchButton(type: .system)
            cancel.setTitle("Cancel", for: .normal)
            cancel.titleLabel?.font = Theme.font(14)
            cancel.tintColor = Theme.blue
            cancel.addAction { [model] in model.cancelEditing() }
            return stack(.horizontal, 8, [back, spacer(), cancel], align: .center)
        }
        let name = label("Resize APFS", Theme.font(m.appName, .semibold, .title1), Theme.ink, lines: 1)
        let device = model.isSimulator ? ["Simulator · Mock storage"] : [deviceName, osLine]
        var trailing: [UIView] = []
        if model.isSimulator {
            let lab = TouchButton(type: .system)
            lab.setImage(Icon.flask.image(20), for: .normal)
            lab.tintColor = Theme.blue
            lab.accessibilityLabel = "Mock scenarios"
            lab.accessibilityIdentifier = "mockScenarios"
            lab.addAction { [weak root] in root?.showMockLab() }
            trailing.append(lab)
        }
        let size: CGFloat = m.regular ? 38 : (m.narrow ? 36 : 40)
        let tile = UIView()
        tile.backgroundColor = Theme.blue
        // The app icon: its drive on the accent colour, the icon's own proportions.
        let icon = Icon.appDrive.view(size, color: Theme.onAccent)
        tile.addSubview(icon)
        tile.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([tile.widthAnchor.constraint(equalToConstant: size), tile.heightAnchor.constraint(equalToConstant: size),
                                     icon.centerXAnchor.constraint(equalTo: tile.centerXAnchor), icon.centerYAnchor.constraint(equalTo: tile.centerYAnchor)])
        if m.regular {
            let lines = stack(.vertical, 3, device.enumerated().map { label($1, Theme.font(m.caption, $0 == 0 ? .medium : .regular), $0 == 0 ? Theme.ink : Theme.muted, lines: 1, align: .right) }, align: .trailing)
            return stack(.horizontal, 10, [tile, name, spacer(), lines] + trailing, align: .center)
        }
        let titles = stack(.vertical, 4, [name, label(device.joined(separator: " · "), Theme.font(m.caption), Theme.muted, lines: 2)])
        return stack(.horizontal, 12, [tile, titles, spacer()] + trailing, align: .center)
    }

    private func title(_ text: String, _ subtitle: String?, identifier: String? = nil, centered: Bool = false) -> UIView {
        let heading = label(text, Theme.font(m.title, .semibold, .largeTitle), Theme.ink, align: centered ? .center : .natural)
        heading.accessibilityIdentifier = identifier
        heading.accessibilityTraits = .header
        var views: [UIView] = [heading]
        if let subtitle { views.append(label(subtitle, Theme.font(m.description), Theme.muted, align: centered ? .center : .natural)) }
        return stack(.vertical, 6, views)
    }

    /// A centred status heading: badge, title and lines, as on the progress, result and connecting pages.
    private func statusHeading(_ badge: StatusBadge, _ heading: UILabel, _ lines: [String]) -> UIView {
        heading.textAlignment = .center
        let views: [UIView] = [badge, heading] + lines.map { label($0, Theme.font(m.description), Theme.muted, align: .center) }
        let column = stack(.vertical, 10, views, align: .center)
        column.setCustomSpacing(16, after: badge)
        column.isLayoutMarginsRelativeArrangement = true
        column.layoutMargins = UIEdgeInsets(top: m.regular ? 24 : 12, left: 0, bottom: 0, right: 0)
        return column
    }

    private func heading(_ text: String) -> UILabel { label(text, Theme.font(m.heading, .semibold, .headline)) }
    private func caption(_ text: String, identifier: String? = nil) -> UILabel {
        let view = label(text, Theme.font(m.caption), Theme.muted)
        view.accessibilityIdentifier = identifier
        return view
    }

    // MARK: Connection

    private func connection() -> [UIView] {
        let heading = label(model.isSimulator ? "Connect to the mock service" : "Connecting to storage helper",
                            Theme.font(m.title, .semibold, .largeTitle), Theme.ink)
        heading.accessibilityTraits = .header
        let message = model.isSimulator ? "Start the independent Mac service, then return here. The app reconnects automatically."
                                        // The helper's own messages name the DFU boot; without DFU the app starts it.
                                        : (model.access == nil ? model.connectionMessage : nil) ?? "Waiting for the storage helper. The app reconnects automatically."
        var views: [UIView] = [statusHeading(StatusBadge(.working, size: m.badge), heading, [message])]
        if model.isSimulator {
            views.append(section(m, "Mock service", Card(m, spacing: 8, [label("./scripts/mock-server.sh", Theme.mono(m.row)), caption("http://127.0.0.1:8472")])))
        }
        return views
    }

    // MARK: Storage access (the app installed without DFU)

    /// One page from the start to the storage: first with Continue, then, while access is
    /// being obtained and whenever the app is opened again in between, with the spinner.
    private func storageAccess(working: Bool) -> [UIView] {
        let heading = label("Storage access", Theme.font(m.title, .semibold, .largeTitle), Theme.ink)
        heading.accessibilityIdentifier = working ? "gettingStorageAccess" : "storageAccessStart"
        heading.accessibilityTraits = .header
        let top = statusHeading(StatusBadge(working ? .working : .access, size: m.badge), heading,
                                ["Resize APFS needs access to your device’s storage. This takes about a minute."])
        let rows: [UIView] = ["The screen restarts and open apps close", "Unlock the device when it is back",
                              "Resize APFS opens again by itself"].map {
            stack(.horizontal, 9, [Icon.arrowRight.view(16, color: Theme.blue), label($0, Theme.font(m.row), Theme.ink)], align: .center)
        }
        return [top, stack(.vertical, 12, rows + [caption("Your storage is not changed. Needs an internet connection.")]), reopenNotice()]
    }

    /// Some devices restart their screen once before access; nothing can open the app again
    /// then, and Dopamine holds what that restart was for only about 20 seconds.
    private func reopenNotice() -> UIView {
        WarningBox(m, icon: .timer, title: "If Resize APFS doesn’t open again by itself, reopen it within 20 seconds.", paragraphs: [])
    }

    private func accessFailed() -> [UIView] {
        let heading = label("Couldn’t get storage access", Theme.font(m.title, .semibold, .largeTitle), Theme.ink)
        heading.accessibilityIdentifier = "storageAccessFailed"
        heading.accessibilityTraits = .header
        return [statusHeading(StatusBadge(.failure, size: m.badge), heading, ["Your storage was not changed."]), reopenNotice()]
    }

    // MARK: Storage overview

    private func overview() -> [UIView] {
        guard let layout = model.layout else { return [] }
        var views: [UIView] = []
        if m.regular { views.append(title("Storage overview", nil, identifier: "storageOverview")) }
        views.append(diskSection(layout))
        views.append(containerSection(layout))
        return views
    }

    private func diskSection(_ layout: StorageLayout) -> UIView {
        let bar = PartitionBar(m, layout: layout, labels: true, apfsTitle: "APFS partition · \(osName)")
        let card = Card(m, spacing: 12, [bar, diskLegend(m, layout), caption("Unallocated outside partitions: \(Capacity.gb(layout.allUnallocatedBytes))")])
        return section(m, "Disk layout", detail: "\(m.regular ? "Internal storage" : layout.diskName) · \(Capacity.gb(layout.totalBytes))", card)
    }

    private func containerSection(_ layout: StorageLayout) -> UIView {
        func capacity(_ title: String, _ bytes: Int64) -> UIView {
            stack(.vertical, 6, [caption(title), label(Capacity.gb(bytes), Theme.digits(m.big, .medium))])
        }
        let capacities: UIView = layout.containerBytes != layout.backingBytes
            ? stack(.horizontal, 32, [capacity("APFS container", layout.containerBytes), capacity("Backing partition", layout.backingBytes), spacer()], align: .top)
            : capacity("Capacity", layout.containerBytes)
        let system = layout.systemSnapshot
        let held = system.flatMap { $0.present ? $0.heldBytes : nil }.map { min(max(0, $0), layout.allocatedBytes) } ?? 0
        let used = max(0, layout.allocatedBytes - held)
        let usage = UsageBar(total: layout.containerBytes, parts: [(used, Theme.blue), (held, Theme.snapshot)])
        var legend: [UIView] = [LegendRow(m, swatch: Theme.blue, title: "Used by \(osName)", value: Capacity.gb(used))]
        if let system, system.present, system.removable {
            legend.append(LegendRow(m, swatch: held > 0 ? Theme.snapshot : nil, title: "Held by snapshot \(system.name)",
                                    value: system.heldBytes == nil ? "Present" : Capacity.gb(held), indent: held == 0))
        }
        legend.append(LegendRow(m, swatch: Theme.track, title: "Free", value: Capacity.gb(layout.freeInsideBytes)))
        legend.append(LegendRow(m, swatch: nil, title: "Adjacent unallocated space", value: Capacity.gb(layout.adjacentFreeBytes), indent: true,
                                valueIdentifier: "Adjacent unallocated spaceValue"))
        let rule = UIView(); rule.backgroundColor = Theme.separator
        rule.heightAnchor.constraint(equalToConstant: 1).isActive = true
        let details = RowButton(content: stack(.horizontal, 8, [label("Technical details", Theme.font(m.row + 1)), spacer(),
                                                                Icon.chevronRight.view(15, color: Theme.faint)], align: .center)) { [weak root] in root?.showTechnical() }
        details.accessibilityIdentifier = "technicalDetails"
        details.accessibilityLabel = "Technical details"
        var figures: [UIView] = [capacities, usage, stack(.vertical, 10, legend)]
        if let offer = snapshotOffer(layout, editor: false) { figures.append(offer) }
        figures.append(rule)
        if let system, !system.present {
            figures.append(cardAction("Take a new \(system.name) snapshot…", color: Theme.blue, identifier: "takeSnapshot") { [model] in model.takeSnapshot() })
        }
        let card = Card(m, spacing: 16, figures + [details])
        card.content.setCustomSpacing(4, after: rule)
        return section(m, "APFS container", detail: "\(layout.apfs.bsdName) · \(osName)", card)
    }

    /// The yellow offer to remove the system snapshot, in the overview and the editor.
    func snapshotOffer(_ layout: StorageLayout, editor: Bool) -> UIView? {
        // A snapshot known to hold nothing (just taken) is not worth an offer.
        guard let system = layout.systemSnapshot, system.present, system.removable, system.heldBytes != 0 else { return nil }
        let held = system.heldBytes.flatMap { $0 > 0 ? Capacity.gb($0) : nil }
        let breaks = "breaks checkra1n’s Restore System until a new snapshot is taken."
        let title: String, detail: String
        if editor {
            title = held.map { "Claim \($0) more" } ?? "Claim more space"
            detail = (layout.minimumContainerBytes.map { "Snapshot \(system.name) keeps \(osName) above \(Capacity.gb($0)). " }
                      ?? "Snapshot \(system.name) keeps \(osName) from shrinking further. ") + "Removing it " + breaks
        } else {
            title = held.map { "Snapshot \(system.name) holds \($0)" } ?? "Snapshot \(system.name) holds space"
            detail = "Removing it lets \(osName) shrink that much further, but " + breaks
        }
        return WarningBox(m, icon: .history, title: title, paragraphs: [detail],
                          action: (title: "Remove snapshot…", identifier: "removeSnapshot", run: { [weak root] in root?.confirmRemoveSnapshot() }, enabled: !model.busy))
    }

    /// A full-width row in a card that runs an action, like "Technical details".
    private func cardAction(_ title: String, color: UIColor, identifier: String, action: @escaping () -> Void) -> UIView {
        let row = stack(.horizontal, 8, [label(title, Theme.font(m.row + 1), model.busy ? Theme.faint : color), spacer(),
                                         Icon.chevronRight.view(15, color: model.busy ? Theme.faint : color)], align: .center)
        let button = RowButton(content: row, action: action)
        button.accessibilityIdentifier = identifier
        button.accessibilityLabel = title
        button.isEnabled = !model.busy
        return button
    }

    // MARK: Review

    private func review() -> [UIView] {
        guard let plan = model.reviewedPlan else { return [] }
        var views = [title("Review changes", "Internal storage · \(plan.before.diskName)", identifier: "reviewHeading")]
        var layoutRows: [UIView] = [PartitionBar(m, layout: plan.after, labels: false)]
        let before = plan.before, after = plan.after
        if before.containerBytes == before.backingBytes && plan.targetBytes == after.backingBytes {
            layoutRows.append(ChangeRow(m, swatch: Theme.blue, title: "APFS", before: Capacity.gb(before.containerBytes), after: Capacity.gb(plan.targetBytes)))
        } else {
            layoutRows.append(ChangeRow(m, swatch: Theme.blue, title: "APFS container", before: Capacity.gb(before.containerBytes), after: Capacity.gb(plan.targetBytes)))
            layoutRows.append(ChangeRow(m, swatch: nil, title: "Backing partition", before: Capacity.gb(before.backingBytes), after: Capacity.gb(after.backingBytes)))
        }
        let removed = before.partitions.filter { plan.request.replacing.contains($0.id) }.sorted { $0.firstLBA < $1.firstLBA }
        for partition in removed {
            layoutRows.append(ChangeRow(m, swatch: partition.isLinux ? Theme.linux : Theme.other,
                                        title: "\(partition.label) · \(partition.bsdName)",
                                        before: Capacity.gb(partition.blocks * before.sectorSize), after: "erased"))
        }
        let created = after.partitions.filter { candidate in !before.partitions.contains { $0.id == candidate.id } }
        for linux in created {
            layoutRows.append(ChangeRow(m, swatch: Theme.linux, title: "Linux · unformatted", before: "0 GB", after: Capacity.gb(linux.blocks * after.sectorSize)))
        }
        layoutRows.append(ChangeRow(m, swatch: Theme.unallocated, title: "Unallocated", before: Capacity.gb(before.allUnallocatedBytes), after: Capacity.gb(after.allUnallocatedBytes)))
        for kept in before.partitions where kept.kind != .apfs && !plan.request.replacing.contains(kept.id) {
            layoutRows.append(LegendRow(m, swatch: kept.isLinux ? Theme.linux : Theme.other, title: "\(kept.label) · \(kept.bsdName)",
                                        value: "\(Capacity.gb(kept.blocks * before.sectorSize)) · unchanged", valueColor: Theme.muted))
        }
        let note: String
        if plan.request.createLinux && !plan.request.replacing.isEmpty { note = "The approved partitions after APFS and everything on them are erased. Their space becomes one new, unformatted Linux partition." }
        else if plan.request.createLinux { note = "The space after APFS becomes an unformatted Linux partition." }
        else if !plan.request.replacing.isEmpty { note = "The approved partitions after APFS and everything on them are erased." }
        else if plan.targetBytes > before.containerBytes { note = "APFS grows into the unallocated space after it." }
        else { note = "Released space stays unallocated. No Linux partition." }
        layoutRows.append(caption(note))
        if plan.alignmentChanged {
            layoutRows.append(caption("Adjusted to \(NumberFormatter.localizedString(from: NSNumber(value: plan.targetBytes), number: .decimal)) bytes for \(NumberFormatter.localizedString(from: NSNumber(value: max(4096, before.sectorSize)), number: .decimal))-byte alignment."))
        }
        views.append(section(m, "Your new layout", Card(m, spacing: 10, layoutRows)))
        if !removed.isEmpty {
            let total = removed.reduce(0) { $0 + $1.blocks * before.sectorSize }
            let rows: [UIView] = removed.map { partition in
                let name = label("\(partition.label) · \(partition.bsdName)", Theme.font(m.row), Theme.ink)
                let size = label(Capacity.gb(partition.blocks * before.sectorSize), Theme.digits(m.row), Theme.ink, lines: 1)
                size.setContentCompressionResistancePriority(.required, for: .horizontal)
                return stack(.horizontal, 12, [name, spacer(), size], align: .firstBaseline)
            }
            let count = removed.count == 1 ? "1 partition" : "\(removed.count) partitions"
            views.append(WarningBox(m, tone: .danger, icon: .warning, title: "\(count) (\(Capacity.gb(total))) will be erased", paragraphs: [], rows: rows))
        }
        let steps = plan.steps.filter { ![.checking, .preparing].contains($0) }
        let stepViews: [UIView] = steps.enumerated().map { index, step in
            let number = label("\(index + 1)", Theme.digits(m.optionTitle, .medium), Theme.faint, lines: 1)
            number.setContentHuggingPriority(.required, for: .horizontal)
            number.widthAnchor.constraint(equalToConstant: 18).isActive = true
            let detail = step == plan.removalStep ? "Remove the approved partitions after APFS; keep its start and identity." : step.detail
            let text = stack(.vertical, 3, [label(step.title, Theme.font(m.optionTitle, .medium)), label(detail, Theme.font(m.optionDetail), Theme.muted)])
            return stack(.horizontal, 10, [number, text], align: .firstBaseline)
        }
        views.append(section(m, "What will happen", ListCard(m, stepViews)))
        views.append(WarningBox(m, icon: .warning, title: "Before you apply", paragraphs: [
            "Resizing can cause data loss. Back up your data before continuing.",
            "The process may take many minutes. The device may behave normally, freeze, or become responsive again while work continues. It may appear that nothing is happening. None of these changes means resizing has finished or failed.",
            "Keep power connected. Do not restart the device or start another resize. Wait until Resize APFS verifies completion.",
        ]))
        return views
    }

    // MARK: Progress

    private func progress() -> [UIView] {
        let op = model.operation
        let reconnecting = model.state == .reconnecting
        let shrink = op?.shrinkProgress
        let stopping = op?.stopRequested == true && op?.currentStep == .shrinkAPFS
        let heading = label(reconnecting ? "Checking operation status" : stopping ? "Stopping after this step"
                                : (op?.currentStep?.title ?? "Starting operation"),
                            Theme.font(m.title, .semibold, .largeTitle), Theme.ink)
        heading.accessibilityIdentifier = "operationHeading"
        var lines = ["Internal storage · \(model.layout?.apfs.bsdName ?? "disk0")"]
        // A shrink shows its progress instead.
        if shrink == nil {
            lines.append(op?.currentStep?.isResize == true ? "This may take many minutes." : "Checking the requested storage changes.")
        }
        var views: [UIView] = [statusHeading(StatusBadge(.working, size: m.badge), heading, lines)]
        if let op, let shrink {
            views.append(ShrinkProgressView(m, shrink, step: op.apfsStep, last: op.onLastShrinkStep))
        }
        if let op {
            views.append(ListCard(m, op.plan.steps.enumerated().map { index, step in stepRow(op, index, step, reconnecting) }))
        } else {
            views.append(label("Confirming whether the service accepted the operation. No start request will be repeated.", Theme.font(m.row), Theme.muted))
        }
        views.append(WarningBox(m, icon: .plug, title: "Keep power connected", paragraphs: [
            "The device may freeze, respond again, or appear idle while work continues. This does not mean resizing has finished or failed.",
            "Do not restart the device or start another resize. Wait until Resize APFS confirms that it has finished or stopped.",
        ]))
        return views
    }

    private func stepRow(_ op: ResizeCore.Operation, _ index: Int, _ step: OperationStep, _ reconnecting: Bool) -> UIView {
        let current = index == op.stepIndex
        let status: UIView
        if op.completedSteps.contains(step) { status = Icon.checkCircle.view(18, color: Theme.green) }
        else if current {
            let spinner = ClockedSpinner(style: .white, color: Theme.blue)
            spinner.widthAnchor.constraint(equalToConstant: 18).isActive = true
            status = spinner
        } else { status = Icon.circle.view(18, color: Theme.faint) }
        let name = label(step.title, Theme.font(m.row + 1, current ? .semibold : .regular), current ? Theme.blue : (op.completedSteps.contains(step) ? Theme.ink : Theme.muted), lines: 1)
        let row = stack(.horizontal, 12, [status, name, spacer()], align: .center)
        if current {
            let chip = label(reconnecting ? "Waiting" : step == .shrinkAPFS && op.stopRequested == true ? "Stopping" : "In progress", Theme.font(m.caption - 1, .semibold), Theme.blue, lines: 1)
            row.addArrangedSubview(chip)
        }
        guard current && step.isResize else { return row }
        let now = Date()
        let age = op.lastConfirmedAt.map { max(0, now.timeIntervalSince($0)) }
        let fresh = WorkerConfirmation.isFresh(pid: op.workerPID, confirmedAt: op.lastConfirmedAt, connectionAvailable: model.connectionOK, now: now)
        var rows: [UIView] = [
            LegendRow(m, swatch: nil, title: "Resize process", value: fresh ? "Active · PID \(op.workerPID.map(String.init) ?? "—")" : "Status unavailable", valueIdentifier: "workerStatus"),
            LegendRow(m, swatch: nil, title: "Last confirmed", value: age.map { $0 < 10 ? "now" : "\(Int($0)) seconds ago" } ?? "Not confirmed", valueIdentifier: "workerLastConfirmed"),
            LegendRow(m, swatch: nil, title: "Elapsed", value: elapsed(now.timeIntervalSince(op.startedAt)), valueIdentifier: "workerElapsed"),
            caption("APFS capacity"),
            LegendRow(m, swatch: nil, title: "Before", value: Capacity.gb(op.plan.before.containerBytes), indent: true),
            LegendRow(m, swatch: nil, title: "Current", value: op.observedCapacityBytes.map(Capacity.gb) ?? "Unavailable", indent: true),
            LegendRow(m, swatch: nil, title: "Target", value: Capacity.gb(op.plan.targetBytes), indent: true),
        ]
        if step == .shrinkAPFS, let apfsStep = op.apfsStep {
            // A large shrink runs as several APFS calls, so iOS stays responsive between them.
            rows.insert(LegendRow(m, swatch: nil, title: "This step", value: Capacity.gb(apfsStep.targetBytes), indent: true), at: rows.count - 1)
        }
        if let observedAt = op.observedAt {
            rows.append(caption("Capacity observation \(Int(max(0, now.timeIntervalSince(observedAt)))) seconds ago."))
        }
        let details = stack(.vertical, 8, rows)
        details.layoutMargins = UIEdgeInsets(top: 0, left: 30, bottom: 0, right: 0)
        details.isLayoutMarginsRelativeArrangement = true
        return stack(.vertical, 12, [row, details])
    }

    private func elapsed(_ interval: TimeInterval) -> String {
        let seconds = max(0, Int(interval))
        if seconds < 60 { return "\(seconds) seconds" }
        let minutes = seconds / 60
        return minutes == 1 ? "1 minute" : "\(minutes) minutes"
    }

    // MARK: Result

    private func result() -> [UIView] {
        guard let op = model.operation, let layout = model.layout else { return [] }
        let success = op.status == .completed
        let unknown = op.status == .unknown
        let byUser = op.status == .stopped && op.stoppedByUser == true
        let heading = label(success ? "Completed" : byUser ? "Resizing stopped" : unknown ? "Couldn’t verify the result" : "Changes could not be completed",
                            Theme.font(m.title, .semibold, .largeTitle), Theme.ink)
        heading.accessibilityIdentifier = success ? "operationCompleted" : "operationStopped"
        let top = statusHeading(StatusBadge(success ? .success : byUser ? .stopped : .failure, size: m.badge), heading,
                                [op.message ?? "Inspect the operation status before continuing."])
        var rows: [UIView] = [PartitionBar(m, layout: layout, labels: false)]
        if layout.containerBytes == layout.backingBytes {
            rows.append(LegendRow(m, swatch: Theme.blue, title: "APFS", value: Capacity.gb(layout.containerBytes)))
        } else {
            rows.append(LegendRow(m, swatch: Theme.blue, title: "APFS partition", value: Capacity.gb(layout.backingBytes)))
            rows.append(LegendRow(m, swatch: nil, title: "APFS container", value: Capacity.gb(layout.containerBytes), indent: true))
        }
        for linux in layout.partitions where linux.isLinux {
            rows.append(LegendRow(m, swatch: Theme.linux, title: "\(linux.label) · \(linux.bsdName)", value: Capacity.gb(linux.blocks * layout.sectorSize)))
        }
        rows.append(LegendRow(m, swatch: Theme.unallocated, title: "Unallocated", value: Capacity.gb(layout.allUnallocatedBytes)))
        let others = layout.partitions.filter { $0.kind == .other && !$0.isLinux }.reduce(0) { $0 + $1.blocks * layout.sectorSize }
        if others > 0 { rows.append(LegendRow(m, swatch: Theme.other, title: "Other partitions", value: "\(Capacity.gb(others)) · unchanged", valueColor: Theme.muted)) }
        let layoutTitle = success ? "Verified final layout" : unknown ? "Latest observed layout" : "Verified current layout"
        var views: [UIView] = [top, section(m, layoutTitle, Card(m, spacing: 10, rows))]
        // Each verified step, and, when the operation stopped, the step that failed
        // in its place, so a failure never reads as a list of successes.
        var notes: [UIView] = []
        func note(_ icon: Icon, _ color: UIColor, _ text: String, _ ink: UIColor = Theme.ink) -> UIView {
            stack(.horizontal, 9, [icon.view(16, color: color), label(text, Theme.font(m.row), ink)], align: .center)
        }
        if byUser {
            if layout.containerBytes < op.plan.before.containerBytes {
                notes.append(note(.checkCircle, Theme.green, "APFS resized to \(Capacity.gb(layout.containerBytes)) and verified"))
            }
            notes += [note(.circleStop, Theme.blue, "Shrinking to \(Capacity.gb(op.plan.targetBytes)) stopped", Theme.blue),
                      note(.checkCircle, Theme.green, "Partition table unchanged"),
                      note(.checkCircle, Theme.green, "Current storage state verified")]
        }
        for (index, step) in op.plan.steps.enumerated() where !byUser {
            if op.completedSteps.contains(step) {
                let text: String
                switch step {
                case .verifyAPFS: text = "APFS capacity verified"
                case .verifyPartition: text = "Both partition-table copies verified"
                case .createLinux: text = "Linux partition created, unformatted"
                case .verifyLayout: text = "Storage layout matches the plan"
                default: continue
                }
                notes.append(stack(.horizontal, 9, [Icon.checkCircle.view(16, color: Theme.green), label(text, Theme.font(m.row), Theme.ink)], align: .center))
            } else if op.status == .stopped && index == op.stepIndex {
                let failed = label("\(step.title) failed", Theme.font(m.row), Theme.destructive)
                failed.accessibilityIdentifier = "failedStep"
                notes.append(stack(.horizontal, 9, [Icon.xCircle.view(16, color: Theme.destructive), failed], align: .center))
            }
        }
        if op.plan.request.createLinux && success { notes.append(caption("Format the Linux partition later in Linux.")) }
        if !notes.isEmpty { views.append(stack(.vertical, 12, notes)) }
        return views
    }

    // MARK: Footer

    /// A failed request, shown right above the action that caused it, where the
    /// user is looking, not at the top of a page that may be scrolled away.
    private func errorRow() -> UIView? {
        guard let error = model.error else { return nil }
        let text = label(error, Theme.font(m.row), Theme.destructive)
        text.accessibilityIdentifier = "serviceError"
        return stack(.horizontal, 8, [Icon.alertCircle.view(15, color: Theme.destructive), text], align: .top)
    }

    func footer() -> [UIView] {
        return (errorRow().map { [$0] } ?? []) + actions()
    }

    private func actions() -> [UIView] {
        switch model.accessPhase {
        case .getting, .checking: return []
        case .start: return [ActionButton(title: "Continue", identifier: "continueAccess") { [model] in model.continueAccess() }]
        case .failed: return [ActionButton(title: "Try again", identifier: "tryAgain") { [model] in model.retryAccess() }]
        case .ready: break
        }
        switch model.state {
        case .overview:
            var views: [UIView] = []
            if let issue = model.layout?.issue {
                let prefix = "Inspection only. "
                let inspection = issue.hasPrefix(prefix)
                let text = stack(.vertical, 2, [label(inspection ? "Inspection only" : "Can’t resize", Theme.font(m.row, .semibold)),
                                                caption(inspection ? String(issue.dropFirst(prefix.count)) : issue)])
                views.append(stack(.horizontal, 10, [Icon.lock.view(16, color: Theme.muted), text], align: .top))
            }
            views.append(ActionButton(title: "Adjust size", identifier: "adjustSize", arrow: .leading, disabled: model.layout?.issue != nil) { [model] in model.edit() })
            return views
        case .editor:
            return [ActionButton(title: "Review changes", identifier: "reviewChanges", arrow: .trailing,
                                 disabled: model.localPlan == nil, busy: model.busy) { [model] in model.review() }]
        case .review:
            return [ActionButton(title: "Apply changes", identifier: "applyChanges", busy: model.busy) { [weak root] in root?.confirmApply() }]
        case .completed:
            return [ActionButton(title: "Done", identifier: "done") { [model] in model.done() }]
        case .stopped:
            if model.operation?.status == .unknown {
                return [ActionButton(title: "Check status", identifier: "checkStatus") { [model] in model.refresh() }]
            }
            let back = ActionButton(title: "Back to storage", identifier: "backToStorage") { [model] in model.done() }
            if model.operation?.stoppedByUser == true, let layout = model.layout, layout.containerBytes < layout.backingBytes {
                return [label("Adjust the size to continue, keep \(Capacity.gb(layout.containerBytes)) or grow APFS back.",
                              Theme.font(m.caption), Theme.muted, align: .center), back]
            }
            return [back]
        case .running:
            guard let op = model.operation, op.currentStep == .shrinkAPFS else { return [] }
            if op.stopRequested == true {
                return [ActionButton(title: "Stopping…", identifier: "stopping", disabled: true) {}]
            }
            if op.onLastShrinkStep {
                return [ActionButton(title: "The last step can’t be stopped", identifier: "lastStep", disabled: true) {}]
            }
            return [ActionButton(title: "Stop after this step", identifier: "stopAfterStep", style: .quiet,
                                 busy: model.busy) { [weak root] in root?.confirmStop() }]
        case .reconnecting:
            return [label("Reconnecting. No resize request will be repeated.", Theme.font(m.caption), Theme.muted, align: .center)]
        default: return []
        }
    }
}

extension UIControl {
    /// Block-based target for iOS 12 (UIAction is iOS 14).
    func addAction(_ action: @escaping () -> Void) {
        let target = ClosureTarget(action)
        objc_setAssociatedObject(self, &ClosureTarget.key, target, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
        addTarget(target, action: #selector(ClosureTarget.run), for: .touchUpInside)
    }
}
private final class ClosureTarget: NSObject {
    static var key = 0
    let action: () -> Void
    init(_ action: @escaping () -> Void) { self.action = action }
    @objc func run() { action() }
}
