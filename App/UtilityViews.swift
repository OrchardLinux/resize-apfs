import UIKit
import ResizeCore

/// The sheets' grouped tables in the app's look: boxes at 4 % with 7 % lines,
/// uppercase captions above them, notes in the faint text colour.
class ThemedTableController: UITableViewController {
    override func viewDidLoad() {
        super.viewDidLoad()
        tableView.backgroundColor = Theme.background
        tableView.separatorColor = Theme.separator
        tableView.indicatorStyle = .white
    }
    override func tableView(_ tableView: UITableView, willDisplay cell: UITableViewCell, forRowAt indexPath: IndexPath) {
        cell.backgroundColor = Theme.card
        let selected = UIView(); selected.backgroundColor = Theme.foreground.withAlphaComponent(0.08)
        cell.selectedBackgroundView = selected
        cell.tintColor = Theme.blue
    }
    override func tableView(_ tableView: UITableView, willDisplayHeaderView view: UIView, forSection section: Int) {
        guard let header = view as? UITableViewHeaderFooterView, let text = header.textLabel?.text else { return }
        header.textLabel?.attributedText = Theme.caption(text, size: 11)
    }
    override func tableView(_ tableView: UITableView, willDisplayFooterView view: UIView, forSection section: Int) {
        guard let footer = view as? UITableViewHeaderFooterView else { return }
        footer.textLabel?.font = Theme.font(11)
        footer.textLabel?.textColor = Theme.faint
    }
}

/// Read-only metadata, as the SwiftUI TechnicalView listed it.
final class TechnicalViewController: ThemedTableController {
    private let sections: [(String, [(String, String)])]
    private let note: String

    init(layout: StorageLayout, isMock: Bool) {
        var sections: [(String, [(String, String)])] = [
            ("Disk", [("Name", layout.diskName), ("Disk GUID", layout.diskID.uuidString), ("Sector size", "\(layout.sectorSize) bytes"),
                      ("Total size", "\(layout.totalBytes) bytes"), ("Usable LBAs", "\(layout.firstUsableLBA)…\(layout.lastUsableLBA) (inclusive)")]),
            ("APFS container", [("Container UUID", layout.containerID.uuidString), ("Capacity", "\(layout.containerBytes) bytes"),
                                ("Backing capacity", "\(layout.backingBytes) bytes"),
                                ("Minimum APFS size", layout.minimumContainerBytes.map { "\($0) bytes" + (isMock ? " (mock fixture)" : " (APFS API)") } ?? "Unavailable")]),
        ]
        // iOS 12-14: every volume's snapshots, so a tester's screenshot shows which one
        // keeps APFS from shrinking. The full name is the value (long press copies it).
        if let volumes = layout.snapshotVolumes {
            sections.append(("Snapshots", volumes.flatMap { volume -> [(String, String)] in
                guard !volume.snapshots.isEmpty else { return [(volume.volume, "No snapshots")] }
                return volume.snapshots.map { entry in
                    let held = entry.heldBytes.map { "holds \(Capacity.gb($0))" } ?? "holds unknown"
                    let marks = SnapshotVolume.markers(entry)
                    return ([volume.volume, marks.isEmpty ? nil : marks, held].compactMap { $0 }.joined(separator: " · "), entry.name)
                }
            }))
        }
        for partition in layout.partitions {
            sections.append((partition.name, [("Device", partition.bsdName), ("Unique GUID", partition.id.uuidString), ("Type GUID", partition.typeGUID),
                                              ("First LBA", "\(partition.firstLBA)"), ("Last LBA", "\(partition.lastLBA) (inclusive)"),
                                              ("Capacity", "\(partition.blocks * layout.sectorSize) bytes"), ("Contents", partition.contents)]))
        }
        self.sections = sections
        note = isMock ? "Simulated metadata. This is not a partition-table or data backup."
                      : "Read-only metadata inspection. The helper retains an original GPT copy before authorized mutations; that is not a backup of your files."
        super.init(style: .grouped)
    }
    required init?(coder: NSCoder) { fatalError() }

    override func viewDidLoad() {
        super.viewDidLoad()
        title = "Technical details"
        navigationItem.rightBarButtonItem = UIBarButtonItem(barButtonSystemItem: .done, target: self, action: #selector(close))
        tableView.allowsSelection = false
        tableView.rowHeight = UITableView.automaticDimension
        tableView.estimatedRowHeight = 56
    }
    @objc private func close() { dismiss(animated: true) }

    override func numberOfSections(in tableView: UITableView) -> Int { sections.count + 1 }
    override func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int { section < sections.count ? sections[section].1.count : 0 }
    override func tableView(_ tableView: UITableView, titleForHeaderInSection section: Int) -> String? { section < sections.count ? sections[section].0 : nil }
    override func tableView(_ tableView: UITableView, titleForFooterInSection section: Int) -> String? { section == sections.count ? note : nil }
    override func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let cell = UITableViewCell(style: .subtitle, reuseIdentifier: nil)
        let (name, value) = sections[indexPath.section].1[indexPath.row]
        cell.textLabel?.text = name
        cell.textLabel?.font = Theme.font(11)
        cell.textLabel?.textColor = Theme.muted
        cell.detailTextLabel?.text = value
        cell.detailTextLabel?.font = Theme.mono(13)
        cell.detailTextLabel?.textColor = Theme.ink
        cell.detailTextLabel?.numberOfLines = 0
        return cell
    }
    // Copy a value with a long press, as the selectable text allowed before.
    override func tableView(_ tableView: UITableView, shouldShowMenuForRowAt indexPath: IndexPath) -> Bool { true }
    override func tableView(_ tableView: UITableView, canPerformAction action: Selector, forRowAt indexPath: IndexPath, withSender sender: Any?) -> Bool {
        action == #selector(UIResponderStandardEditActions.copy(_:))
    }
    override func tableView(_ tableView: UITableView, performAction action: Selector, forRowAt indexPath: IndexPath, withSender sender: Any?) {
        UIPasteboard.general.string = sections[indexPath.section].1[indexPath.row].1
    }
}

/// Simulator only: choose the mock service's scenario and timing.
final class MockLabViewController: ThemedTableController {
    private let model: AppModel
    private var selected: MockScenario
    private var scale = 1.0
    private let speeds: [(String, Double)] = [("Fast · a few seconds", 0.15), ("Normal · about 20 seconds", 1.0), ("Slow · minutes", 10.0)]

    init(model: AppModel) {
        self.model = model
        selected = model.snapshot?.scenario ?? .normal
        super.init(style: .grouped)
    }
    required init?(coder: NSCoder) { fatalError() }

    override func viewDidLoad() {
        super.viewDidLoad()
        title = "Mock service"
        navigationItem.rightBarButtonItem = UIBarButtonItem(title: "Close", style: .done, target: self, action: #selector(close))
        tableView.accessibilityIdentifier = "scenarioPicker"
    }
    @objc private func close() { dismiss(animated: true) }

    override func numberOfSections(in tableView: UITableView) -> Int { 4 }
    override func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        [1, MockScenario.allCases.count, speeds.count, 1][section]
    }
    override func tableView(_ tableView: UITableView, titleForHeaderInSection section: Int) -> String? { [nil, "Scenario", "Timing", nil][section] }
    override func tableView(_ tableView: UITableView, titleForFooterInSection section: Int) -> String? {
        switch section {
        case 0: return "This service is a separate Mac process. Closing the app does not stop its operation. No disks, APFS APIs or partition tools are accessed."
        case 2: return "Timing is deliberately synthetic. Capacity does not animate toward the target."
        case 3: return [model.error, "Resets the mock layout and discards any simulated operation. It never affects real storage."].compactMap { $0 }.joined(separator: "\n")
        default: return nil
        }
    }
    override func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let cell = UITableViewCell(style: .default, reuseIdentifier: nil)
        cell.textLabel?.font = Theme.font(13)
        cell.textLabel?.textColor = Theme.ink
        switch indexPath.section {
        case 0:
            cell.textLabel?.text = "Synthetic storage only"; cell.textLabel?.font = Theme.font(14, .semibold); cell.selectionStyle = .none
        case 1:
            let scenario = MockScenario.allCases[indexPath.row]
            cell.textLabel?.text = scenario.title
            cell.accessoryType = scenario == selected ? .checkmark : .none
        case 2:
            cell.textLabel?.text = speeds[indexPath.row].0
            cell.accessoryType = speeds[indexPath.row].1 == scale ? .checkmark : .none
        default:
            cell.textLabel?.text = "Load scenario"
            cell.textLabel?.textColor = model.busy ? Theme.faint : Theme.destructive
            cell.accessibilityIdentifier = "loadScenario"
        }
        return cell
    }
    override func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at: indexPath, animated: true)
        switch indexPath.section {
        case 1: selected = MockScenario.allCases[indexPath.row]; tableView.reloadSections([1], with: .none)
        case 2: scale = speeds[indexPath.row].1; tableView.reloadSections([2], with: .none)
        case 3:
            guard !model.busy else { return }
            let sheet = UIAlertController(title: "Discard the current simulation?", message: nil, preferredStyle: .actionSheet)
            sheet.addAction(UIAlertAction(title: "Load mock scenario", style: .destructive) { [weak self] _ in
                guard let self else { return }
                self.model.configure(self.selected, scale: self.scale) { [weak self] loaded in
                    if loaded { self?.dismiss(animated: true) } else { self?.tableView.reloadData() }
                }
            })
            sheet.addAction(UIAlertAction(title: "Cancel", style: .cancel))
            sheet.popoverPresentationController?.sourceView = tableView.cellForRow(at: indexPath)
            sheet.popoverPresentationController?.sourceRect = tableView.cellForRow(at: indexPath)?.bounds ?? .zero
            present(sheet, animated: true)
        default: break
        }
    }
}
