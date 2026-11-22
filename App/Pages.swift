import UIKit
import ResizeCore

var osName: String { UIDevice.current.systemName }
var osLine: String { "\(UIDevice.current.systemName) \(UIDevice.current.systemVersion)" }

/// Builds the page and footer for the model's current state.
struct Pages {
    let root: RootViewController
    let m: Metrics
    var model: AppModel { root.model }
    init(_ root: RootViewController, _ metrics: Metrics) { self.root = root; m = metrics }

    func build() -> [UIView] {
        var views = [header()]
        if let error = model.error {
            let text = label(error, Theme.font(m.row), Theme.destructive)
            text.accessibilityIdentifier = "serviceError"
            views.append(stack(.horizontal, 8, [Icon.alertCircle.view(16, color: Theme.destructive), text], align: .top))
        }
        switch model.state {
        case .loading: views += connection()
        case .overview: views += overview()
        case .editor: views.append(root.makeEditor(m))
        case .review: views += review()
        case .submitting, .running, .verifying: views += progress()
        case .completed, .stopped: views += result()
        case .reconnecting: views += model.operation != nil ? progress() : connection()
        }
        return views
    }

    // MARK: Header

    private func header() -> UIView {
        if [.editor, .review].contains(model.state) {
            let back = UIButton(type: .system)
            back.setImage(Icon.chevronLeft.image(18, lineWidth: 2.4), for: .normal)
            back.setTitle(model.state == .review ? " Adjust size" : " Storage", for: .normal)
            back.titleLabel?.font = Theme.font(16)
            back.tintColor = Theme.blue
            back.accessibilityIdentifier = "back"
            back.addAction { [model] in model.back() }
            let cancel = UIButton(type: .system)
            cancel.setTitle("Cancel", for: .normal)
            cancel.titleLabel?.font = Theme.font(16)
            cancel.tintColor = Theme.blue
            cancel.addAction { [model] in model.cancelEditing() }
            return stack(.horizontal, 8, [back, spacer(), cancel], align: .center)
        }
        let name = label("Resize APFS", Theme.font(m.appName, .bold, .title1), Theme.ink, lines: 1)
        let device = model.isSimulator ? ["Simulator · Mock storage"] : [UIDevice.current.model, osLine]
        var trailing: [UIView] = []
        if model.isSimulator {
            let lab = UIButton(type: .system)
            lab.setImage(Icon.flask.image(22), for: .normal)
            lab.tintColor = Theme.blue
            lab.accessibilityLabel = "Mock scenarios"
            lab.accessibilityIdentifier = "mockScenarios"
            lab.addAction { [weak root] in root?.showMockLab() }
            trailing.append(lab)
        }
        if m.regular {
            let tile = UIView()
            tile.backgroundColor = Theme.blue; tile.layer.cornerRadius = 11
            let icon = Icon.drive.view(22, color: .white)
            tile.addSubview(icon)
            tile.translatesAutoresizingMaskIntoConstraints = false
            NSLayoutConstraint.activate([tile.widthAnchor.constraint(equalToConstant: 44), tile.heightAnchor.constraint(equalToConstant: 44),
                                         icon.centerXAnchor.constraint(equalTo: tile.centerXAnchor), icon.centerYAnchor.constraint(equalTo: tile.centerYAnchor)])
            let lines = stack(.vertical, 3, device.enumerated().map { label($1, Theme.font(m.caption, $0 == 0 ? .medium : .regular), $0 == 0 ? Theme.ink : Theme.muted, lines: 1, align: .right) }, align: .trailing)
            return stack(.horizontal, 10, [tile, name, spacer(), lines] + trailing, align: .center)
        }
        let titles = stack(.vertical, 4, [name, label(device.joined(separator: " · "), Theme.font(m.caption + 1), Theme.muted, lines: 1)])
        return stack(.horizontal, 8, [titles, spacer()] + trailing, align: .top)
    }

    private func title(_ text: String, _ subtitle: String?, identifier: String? = nil) -> UIView {
        let heading = label(text, Theme.font(m.title, .semibold, .largeTitle))
        heading.accessibilityIdentifier = identifier
        heading.accessibilityTraits = .header
        var views: [UIView] = [heading]
        if let subtitle { views.append(label(subtitle, Theme.font(m.description), Theme.muted)) }
        return stack(.vertical, 5, views)
    }

    private func heading(_ text: String) -> UILabel { label(text, Theme.font(m.heading, .semibold, .headline)) }
    private func caption(_ text: String, identifier: String? = nil) -> UILabel {
        let view = label(text, Theme.font(m.caption), Theme.muted)
        view.accessibilityIdentifier = identifier
        return view
    }

    // MARK: Connection

    private func connection() -> [UIView] {
        var body: [UIView] = [stack(.horizontal, 8, [Icon.info.view(18, color: Theme.blue), heading("Checking service status")], align: .center),
                              label(model.isSimulator ? "Start the independent Mac service, then return here. The app reconnects automatically."
                                                      : (model.connectionMessage ?? "Waiting for the storage helper. The app reconnects automatically."),
                                    Theme.font(m.row), Theme.muted)]
        if model.isSimulator {
            body.append(label("./scripts/mock-server.sh", Theme.mono(m.row)))
            body.append(caption("http://127.0.0.1:8472"))
        }
        return [title(model.isSimulator ? "Connect to the mock service" : "Connecting to storage helper", nil), Card(m, spacing: 10, body)]
    }

    // MARK: Storage overview

    private func overview() -> [UIView] {
        guard let layout = model.layout else { return [] }
        var views: [UIView] = []
        if m.regular { views.append(title("Storage overview", "Inspect your disk and prepare space for what’s next.", identifier: "storageOverview")) }
        views.append(diskCard(layout))
        views.append(containerCard(layout))
        return views
    }

    private func diskCard(_ layout: StorageLayout) -> UIView {
        let kicker = label("DISK LAYOUT", Theme.font(11, .semibold, .caption1), Theme.muted, lines: 1)
        kicker.attributedText = NSAttributedString(string: "DISK LAYOUT", attributes: [.kern: 1, .font: Theme.font(11, .semibold, .caption1), .foregroundColor: Theme.muted])
        let disk = stack(.horizontal, 8, [Icon.drive.view(16, color: Theme.blue),
                                          label(m.regular ? "Internal storage" : layout.diskName, Theme.font(m.row, .medium), Theme.ink, lines: 1),
                                          label(Capacity.gb(layout.totalBytes), Theme.digits(m.caption), Theme.muted, lines: 1)], align: .center)
        let top = stack(.horizontal, 8, [kicker, spacer(), disk], align: .center)
        let bar = PartitionBar(m, layout: layout, labels: true, apfsTitle: "APFS partition · \(osName)")
        return Card(m, spacing: 14, [top, bar, diskLegend(layout), caption("Unallocated outside partitions: \(Capacity.gb(layout.allUnallocatedBytes))")])
    }

    private func diskLegend(_ layout: StorageLayout) -> UIView {
        func sum(_ kind: Partition.Kind) -> Int64 { layout.partitions.filter { $0.kind == kind }.reduce(0) { $0 + $1.blocks * layout.sectorSize } }
        var items: [(UIColor, String)] = [(Theme.blue, "APFS  \(Capacity.gb(layout.backingBytes))")]
        if sum(.linux) > 0 { items.append((Theme.linux, "Linux  \(Capacity.gb(sum(.linux)))")) }
        if sum(.other) > 0 { items.append((Theme.other, "Other partitions  \(Capacity.gb(sum(.other)))")) }
        if layout.allUnallocatedBytes > 0 { items.append((Theme.unallocated, "Unallocated")) }
        let perRow = m.regular ? 4 : 2
        let rows = stride(from: 0, to: items.count, by: perRow).map { start -> UIView in
            let row = stack(.horizontal, 16, items[start..<min(start + perRow, items.count)].map { item in
                stack(.horizontal, 7, [swatch(item.0, size: 8), label(item.1, Theme.font(m.caption), Theme.muted, lines: 1)], align: .center)
            }, align: .center)
            row.addArrangedSubview(spacer())
            return row
        }
        return stack(.vertical, 8, rows)
    }

    private func containerCard(_ layout: StorageLayout) -> UIView {
        let tile = UIView()
        tile.backgroundColor = Theme.blueTint; tile.layer.cornerRadius = 10
        let icon = Icon.layers.view(20, color: Theme.blue)
        tile.addSubview(icon)
        tile.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([tile.widthAnchor.constraint(equalToConstant: 40), tile.heightAnchor.constraint(equalToConstant: 40),
                                     icon.centerXAnchor.constraint(equalTo: tile.centerXAnchor), icon.centerYAnchor.constraint(equalTo: tile.centerYAnchor)])
        let names = stack(.vertical, 3, [heading("APFS container"), caption("\(layout.apfs.bsdName) · \(osName)")])
        let top = stack(.horizontal, 12, [tile, names], align: .center)
        func capacity(_ title: String, _ bytes: Int64) -> UIView {
            stack(.vertical, 6, [caption(title), label(Capacity.gb(bytes), Theme.digits(m.big, .medium))])
        }
        let capacities: UIView = layout.containerBytes != layout.backingBytes
            ? stack(.horizontal, 32, [capacity("APFS container", layout.containerBytes), capacity("Backing partition", layout.backingBytes), spacer()], align: .top)
            : capacity("Capacity", layout.containerBytes)
        let held: Int64 = 0  // The removable snapshot's share; see the snapshot feature.
        let used = max(0, layout.allocatedBytes - held)
        let usage = UsageBar(total: layout.containerBytes, parts: [(used, Theme.blue), (held, Theme.snapshot)])
        var legend: [UIView] = [LegendRow(m, swatch: Theme.blue, title: "Used by \(osName)", value: Capacity.gb(used))]
        if held > 0 { legend.append(LegendRow(m, swatch: Theme.snapshot, title: "Held by snapshot orig-fs", value: Capacity.gb(held))) }
        legend.append(LegendRow(m, swatch: Theme.track, title: "Free", value: Capacity.gb(layout.freeInsideBytes)))
        legend.append(LegendRow(m, swatch: nil, title: "Adjacent unallocated space", value: Capacity.gb(layout.adjacentFreeBytes), indent: true,
                                valueIdentifier: "Adjacent unallocated spaceValue"))
        let rule = UIView(); rule.backgroundColor = Theme.line
        rule.heightAnchor.constraint(equalToConstant: 1).isActive = true
        let details = UIButton(type: .system)
        details.contentHorizontalAlignment = .fill
        details.accessibilityIdentifier = "technicalDetails"
        details.accessibilityLabel = "Technical details"
        let row = stack(.horizontal, 8, [label("Technical details", Theme.font(m.row + 1)), spacer(), Icon.chevronRight.view(17, color: Theme.faint)], align: .center)
        row.isUserInteractionEnabled = false
        row.translatesAutoresizingMaskIntoConstraints = false
        details.addSubview(row)
        NSLayoutConstraint.activate([row.leadingAnchor.constraint(equalTo: details.leadingAnchor), row.trailingAnchor.constraint(equalTo: details.trailingAnchor),
                                     row.topAnchor.constraint(equalTo: details.topAnchor, constant: 4), row.bottomAnchor.constraint(equalTo: details.bottomAnchor, constant: -4)])
        details.addAction { [weak root] in root?.showTechnical() }
        return Card(m, spacing: 16, [top, capacities, usage, stack(.vertical, 10, legend), rule, details])
    }

    // MARK: Review

    private func review() -> [UIView] {
        guard let plan = model.reviewedPlan else { return [] }
        var views = [title("Review changes", "Internal storage · \(plan.before.diskName)", identifier: "reviewHeading")]
        var layoutRows: [UIView] = [heading("Your new layout"), PartitionBar(m, layout: plan.after, labels: false)]
        let before = plan.before, after = plan.after
        if before.containerBytes == before.backingBytes && plan.targetBytes == after.backingBytes {
            layoutRows.append(ChangeRow(m, swatch: Theme.blue, title: "APFS", before: Capacity.gb(before.containerBytes), after: Capacity.gb(plan.targetBytes)))
        } else {
            layoutRows.append(ChangeRow(m, swatch: Theme.blue, title: "APFS container", before: Capacity.gb(before.containerBytes), after: Capacity.gb(plan.targetBytes)))
            layoutRows.append(ChangeRow(m, swatch: nil, title: "Backing partition", before: Capacity.gb(before.backingBytes), after: Capacity.gb(after.backingBytes)))
        }
        for removed in before.partitions where plan.request.replacing.contains(removed.id) {
            layoutRows.append(ChangeRow(m, swatch: removed.kind == .linux ? Theme.linux : Theme.other,
                                        title: "\(removed.kind == .linux ? "Linux" : removed.name) · \(removed.bsdName)",
                                        before: Capacity.gb(removed.blocks * before.sectorSize), after: "erased"))
        }
        let created = after.partitions.filter { candidate in !before.partitions.contains { $0.id == candidate.id } }
        for linux in created {
            layoutRows.append(ChangeRow(m, swatch: Theme.linux, title: "Linux · unformatted", before: "0 GB", after: Capacity.gb(linux.blocks * after.sectorSize)))
        }
        layoutRows.append(ChangeRow(m, swatch: Theme.unallocated, title: "Unallocated", before: Capacity.gb(before.allUnallocatedBytes), after: Capacity.gb(after.allUnallocatedBytes)))
        let others = before.partitions.filter { $0.kind == .other }.reduce(0) { $0 + $1.blocks * before.sectorSize }
        if others > 0 { layoutRows.append(LegendRow(m, swatch: Theme.other, title: "Other partitions", value: "\(Capacity.gb(others)) · unchanged", valueColor: Theme.muted)) }
        let note: String
        if plan.request.createLinux { note = "The space after APFS becomes an unformatted Linux partition." }
        else if !plan.request.replacing.isEmpty { note = "The approved partitions after APFS and everything on them are erased." }
        else if plan.targetBytes > before.containerBytes { note = "APFS grows into the unallocated space after it." }
        else { note = "Released space stays unallocated. No Linux partition." }
        layoutRows.append(caption(note))
        if plan.alignmentChanged {
            layoutRows.append(caption("Adjusted to \(NumberFormatter.localizedString(from: NSNumber(value: plan.targetBytes), number: .decimal)) bytes for \(NumberFormatter.localizedString(from: NSNumber(value: max(4096, before.sectorSize)), number: .decimal))-byte alignment."))
        }
        views.append(Card(m, spacing: 10, layoutRows))
        let steps = plan.steps.filter { ![.checking, .preparing].contains($0) }
        let stepViews: [UIView] = steps.enumerated().map { index, step in
            let number = label("\(index + 1)", Theme.font(m.caption, .semibold), Theme.ink, lines: 1, align: .center)
            number.backgroundColor = Theme.background
            number.layer.cornerRadius = 13; number.clipsToBounds = true
            number.translatesAutoresizingMaskIntoConstraints = false
            NSLayoutConstraint.activate([number.widthAnchor.constraint(equalToConstant: 26), number.heightAnchor.constraint(equalToConstant: 26)])
            let detail = step == plan.removalStep ? "Remove the approved partitions after APFS; keep its start and identity." : step.detail
            let text = stack(.vertical, 3, [label(step.title, Theme.font(m.optionTitle, .medium)), label(detail, Theme.font(m.optionDetail), Theme.muted)])
            return stack(.horizontal, 12, [number, text], align: .top)
        }
        views.append(Card(m, spacing: 14, [heading("What will happen")] + stepViews))
        views.append(WarningBox(m, icon: .warning, title: "Before you apply", paragraphs: [
            "Resizing can cause data loss. Back up your data before continuing.",
            "The process may take many minutes. The device may behave normally, freeze, or become responsive again while work continues. It may appear that nothing is happening. None of these changes means resizing has finished or failed.",
            "Keep power connected. Do not restart the device or start another resize. Wait until Resize APFS verifies completion.",
        ]))
        return views
    }

    // MARK: Progress

    private func progress() -> [UIView] {
        let spinner = UIActivityIndicatorView(style: .whiteLarge)
        spinner.color = Theme.blue; spinner.startAnimating()
        let circle = UIView()
        circle.backgroundColor = Theme.blue.withAlphaComponent(0.07); circle.layer.cornerRadius = 36
        spinner.translatesAutoresizingMaskIntoConstraints = false
        circle.addSubview(spinner)
        circle.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([circle.widthAnchor.constraint(equalToConstant: 72), circle.heightAnchor.constraint(equalToConstant: 72),
                                     spinner.centerXAnchor.constraint(equalTo: circle.centerXAnchor), spinner.centerYAnchor.constraint(equalTo: circle.centerYAnchor)])
        let op = model.operation
        let reconnecting = model.state == .reconnecting
        let heading = label(reconnecting ? "Checking operation status" : (op?.currentStep?.title ?? "Starting operation"),
                            Theme.font(m.title, .semibold, .largeTitle), Theme.ink, align: .center)
        heading.accessibilityIdentifier = "operationHeading"
        let top = stack(.vertical, 12, [circle, heading,
                                        label(model.layout?.apfs.bsdName ?? "Internal storage", Theme.font(m.row), Theme.muted, align: .center),
                                        label(op?.currentStep?.isResize == true ? "This may take many minutes." : "Checking the requested storage changes.",
                                              Theme.font(m.row), Theme.muted, align: .center)], align: .center)
        var views: [UIView] = [top]
        if let op {
            views.append(Card(m, spacing: 14, op.plan.steps.enumerated().map { index, step in stepRow(op, index, step, reconnecting) }))
        } else {
            views.append(label("Confirming whether the service accepted the operation. No start request will be repeated.", Theme.font(m.row), Theme.muted))
        }
        views.append(WarningBox(m, icon: .plug, title: "Keep power connected", paragraphs: [
            "The device may freeze, respond again, or appear idle while work continues. This does not mean resizing has finished or failed.",
            "Do not restart the device or start another resize. Wait until Resize APFS verifies completion.",
        ]))
        return views
    }

    private func stepRow(_ op: ResizeCore.Operation, _ index: Int, _ step: OperationStep, _ reconnecting: Bool) -> UIView {
        let current = index == op.stepIndex
        let status: UIView
        if op.completedSteps.contains(step) { status = Icon.checkCircle.view(20, color: Theme.green) }
        else if current {
            let spinner = UIActivityIndicatorView(style: .gray)
            spinner.color = Theme.blue; spinner.startAnimating()
            spinner.widthAnchor.constraint(equalToConstant: 20).isActive = true
            status = spinner
        } else { status = Icon.circle.view(20, color: Theme.faint.withAlphaComponent(0.6)) }
        let name = label(step.title, Theme.font(m.row + 1, current ? .semibold : .regular), current ? Theme.blue : Theme.muted, lines: 1)
        let row = stack(.horizontal, 12, [status, name, spacer()], align: .center)
        if current {
            let chip = label(reconnecting ? "  Waiting  " : "  In progress  ", Theme.font(m.caption - 1, .semibold), Theme.blue, lines: 1)
            chip.backgroundColor = Theme.blueTint; chip.layer.cornerRadius = 9; chip.clipsToBounds = true
            chip.heightAnchor.constraint(equalToConstant: 20).isActive = true
            row.addArrangedSubview(chip)
        }
        guard current && step.isResize else { return row }
        let now = Date()
        let age = op.lastConfirmedAt.map { max(0, now.timeIntervalSince($0)) }
        let fresh = WorkerConfirmation.isFresh(pid: op.workerPID, confirmedAt: op.lastConfirmedAt, connectionAvailable: model.connectionOK, now: now)
        var rows: [UIView] = [
            LegendRow(m, swatch: nil, title: "Resize process", value: fresh ? "Active · PID \(op.workerPID.map(String.init) ?? "—")" : "Status unavailable", valueIdentifier: "workerStatus"),
            LegendRow(m, swatch: nil, title: "Last confirmed", value: age.map { "\(Int($0)) seconds ago" } ?? "Not confirmed", valueIdentifier: "workerLastConfirmed"),
            LegendRow(m, swatch: nil, title: "Elapsed", value: elapsed(now.timeIntervalSince(op.startedAt)), valueIdentifier: "workerElapsed"),
            caption("APFS capacity"),
            LegendRow(m, swatch: nil, title: "Before", value: Capacity.gb(op.plan.before.containerBytes), indent: true),
            LegendRow(m, swatch: nil, title: "Current", value: op.observedCapacityBytes.map(Capacity.gb) ?? "Unavailable", indent: true),
            LegendRow(m, swatch: nil, title: "Target", value: Capacity.gb(op.plan.targetBytes), indent: true),
        ]
        if let observedAt = op.observedAt {
            rows.append(caption("Capacity observation \(Int(max(0, now.timeIntervalSince(observedAt)))) seconds ago."))
        }
        let details = stack(.vertical, 8, rows)
        details.layoutMargins = UIEdgeInsets(top: 0, left: 32, bottom: 0, right: 0)
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
        let tile = UIView()
        tile.backgroundColor = success ? Theme.greenTint : Theme.destructiveTint; tile.layer.cornerRadius = 14
        let icon = (success ? Icon.check : Icon.warning).view(24, color: success ? Theme.green : Theme.destructive, lineWidth: 2.4)
        tile.addSubview(icon)
        tile.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([tile.widthAnchor.constraint(equalToConstant: 48), tile.heightAnchor.constraint(equalToConstant: 48),
                                     icon.centerXAnchor.constraint(equalTo: tile.centerXAnchor), icon.centerYAnchor.constraint(equalTo: tile.centerYAnchor)])
        let heading = label(success ? "Completed" : unknown ? "Couldn’t verify the result" : "Changes could not be completed",
                            Theme.font(m.title, .semibold, .largeTitle))
        heading.accessibilityIdentifier = success ? "operationCompleted" : "operationStopped"
        let top = stack(.vertical, 12, [tile, heading, label(op.message ?? "Inspect the operation status before continuing.", Theme.font(m.description), Theme.muted)], align: .leading)
        var rows: [UIView] = [self.heading(success ? "Verified final layout" : unknown ? "Latest observed layout" : "Verified current layout"),
                              PartitionBar(m, layout: layout, labels: false)]
        if layout.containerBytes == layout.backingBytes {
            rows.append(LegendRow(m, swatch: Theme.blue, title: "APFS", value: Capacity.gb(layout.containerBytes)))
        } else {
            rows.append(LegendRow(m, swatch: Theme.blue, title: "APFS partition", value: Capacity.gb(layout.backingBytes)))
            rows.append(LegendRow(m, swatch: nil, title: "APFS container", value: Capacity.gb(layout.containerBytes), indent: true))
        }
        for linux in layout.partitions where linux.kind == .linux {
            rows.append(LegendRow(m, swatch: Theme.linux, title: "Linux · \(linux.bsdName)", value: Capacity.gb(linux.blocks * layout.sectorSize)))
        }
        rows.append(LegendRow(m, swatch: Theme.unallocated, title: "Unallocated", value: Capacity.gb(layout.allUnallocatedBytes)))
        let others = layout.partitions.filter { $0.kind == .other }.reduce(0) { $0 + $1.blocks * layout.sectorSize }
        if others > 0 { rows.append(LegendRow(m, swatch: Theme.other, title: "Other partitions", value: "\(Capacity.gb(others)) · unchanged", valueColor: Theme.muted)) }
        var views: [UIView] = [top, Card(m, spacing: 10, rows)]
        var notes: [UIView] = op.completedSteps.compactMap { step -> UIView? in
            let text: String
            switch step {
            case .verifyAPFS: text = "APFS capacity verified"
            case .verifyPartition: text = "Both partition-table copies verified"
            case .createLinux: text = "Linux partition created, unformatted"
            case .verifyLayout: text = "Storage layout matches the plan"
            default: return nil
            }
            return stack(.horizontal, 9, [Icon.checkCircle.view(17, color: Theme.green), label(text, Theme.font(m.row), Theme.ink)], align: .center)
        }
        if unknown { notes.append(caption("No automatic retry was sent. Checking status does not repeat the resize.")) }
        if op.plan.request.createLinux { notes.append(caption("Format the Linux partition later in Linux.")) }
        notes.append(caption(model.isSimulator ? "Mock result only. No physical storage was changed."
                                               : "Metadata readback does not replace a data backup or full filesystem-integrity check."))
        views.append(stack(.vertical, 12, notes))
        return views
    }

    // MARK: Footer

    func footer() -> [UIView] {
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
            var views: [UIView] = []
            if model.unchanged { views.append(label("Choose a different size to review changes.", Theme.font(m.caption), Theme.muted, align: .center)) }
            views.append(ActionButton(title: "Review changes", identifier: "reviewChanges", arrow: .trailing,
                                      disabled: model.localPlan == nil, busy: model.busy) { [model] in model.review() })
            return views
        case .review:
            return [ActionButton(title: "Apply changes", identifier: "applyChanges", style: .destructive, busy: model.busy) { [weak root] in root?.confirmApply() }]
        case .completed:
            return [ActionButton(title: "Done", identifier: "done") { [model] in model.done() }]
        case .stopped:
            if model.operation?.status == .unknown {
                return [ActionButton(title: "Check status", identifier: "checkStatus") { [model] in model.refresh() }]
            }
            return [ActionButton(title: "Back to storage", identifier: "backToStorage") { [model] in model.done() }]
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
