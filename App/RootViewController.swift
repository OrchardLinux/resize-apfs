import UIKit
import ResizeCore

/// One scrolling page per workflow state, the header and error above it, and
/// the state's action pinned at the bottom (the SwiftUI RootView's structure).
final class RootViewController: UIViewController, UIScrollViewDelegate {
    let model: AppModel
    private let scroll = UIScrollView()
    private let page = UIStackView()
    private let footer = UIStackView()
    private let footerBar = UIView()
    /// The app name or back/cancel row stays put above the scrolling page.
    private let headerBar = UIView()
    private let headerSlot = UIStackView()
    private let headerRule = UIView()
    private var headerKey = ""
    private var pageIdentity = ""
    /// What the page and footer showed last; they are rebuilt only when it changes,
    /// so a poll that brings nothing new never replaces a view under the user's finger.
    private var pageKey = ""
    private var footerKey = ""
    private var editor: EditorPage?
    private var ticker: Timer?

    init(model: AppModel) {
        self.model = model
        super.init(nibName: nil, bundle: nil)
    }
    required init?(coder: NSCoder) { fatalError() }

    var metrics: Metrics { Metrics(traits: traitCollection, width: view.bounds.width) }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = Theme.background
        scroll.keyboardDismissMode = .interactive
        scroll.alwaysBounceVertical = true
        scroll.translatesAutoresizingMaskIntoConstraints = false
        scroll.delegate = self
        view.addSubview(scroll)
        headerBar.backgroundColor = Theme.background
        headerBar.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(headerBar)
        headerSlot.axis = .vertical
        headerSlot.translatesAutoresizingMaskIntoConstraints = false
        headerBar.addSubview(headerSlot)
        headerRule.backgroundColor = Theme.line
        headerRule.alpha = 0
        headerRule.translatesAutoresizingMaskIntoConstraints = false
        headerBar.addSubview(headerRule)
        page.axis = .vertical
        page.translatesAutoresizingMaskIntoConstraints = false
        scroll.addSubview(page)
        footerBar.backgroundColor = Theme.background
        footerBar.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(footerBar)
        footer.axis = .vertical; footer.spacing = 12
        footer.translatesAutoresizingMaskIntoConstraints = false
        footerBar.addSubview(footer)
        let guide = view.safeAreaLayoutGuide
        // The page fills the width minus the margins, up to the content width. The
        // fill wins over labels' resistance to wrapping (999 > 750), the caps always hold.
        let width = page.widthAnchor.constraint(equalTo: scroll.widthAnchor, constant: -2 * metrics.side)
        width.priority = UILayoutPriority(999)
        let widthCap = page.widthAnchor.constraint(lessThanOrEqualTo: scroll.widthAnchor, constant: -2 * metrics.side)
        let footerWidth = footer.widthAnchor.constraint(equalTo: footerBar.widthAnchor, constant: -2 * metrics.side)
        footerWidth.priority = UILayoutPriority(999)
        let footerCap = footer.widthAnchor.constraint(lessThanOrEqualTo: footerBar.widthAnchor, constant: -2 * metrics.side)
        let headerWidth = headerSlot.widthAnchor.constraint(equalTo: headerBar.widthAnchor, constant: -2 * metrics.side)
        headerWidth.priority = UILayoutPriority(999)
        let headerCap = headerSlot.widthAnchor.constraint(lessThanOrEqualTo: headerBar.widthAnchor, constant: -2 * metrics.side)
        headerTop = headerSlot.topAnchor.constraint(equalTo: guide.topAnchor, constant: metrics.headerTop)
        sideConstraints = [width, widthCap, footerWidth, footerCap, headerWidth, headerCap]
        NSLayoutConstraint.activate([
            headerBar.topAnchor.constraint(equalTo: view.topAnchor),
            headerBar.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            headerBar.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            headerTop!,
            headerSlot.bottomAnchor.constraint(equalTo: headerBar.bottomAnchor, constant: -10),
            headerSlot.centerXAnchor.constraint(equalTo: headerBar.centerXAnchor),
            headerSlot.widthAnchor.constraint(lessThanOrEqualToConstant: metrics.contentWidth), headerWidth, headerCap,
            headerRule.leadingAnchor.constraint(equalTo: headerBar.leadingAnchor),
            headerRule.trailingAnchor.constraint(equalTo: headerBar.trailingAnchor),
            headerRule.bottomAnchor.constraint(equalTo: headerBar.bottomAnchor),
            headerRule.heightAnchor.constraint(equalToConstant: 1 / UIScreen.main.scale),
            scroll.topAnchor.constraint(equalTo: headerBar.bottomAnchor),
            scroll.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            scroll.bottomAnchor.constraint(equalTo: footerBar.topAnchor),
            page.topAnchor.constraint(equalTo: scroll.contentLayoutGuide.topAnchor, constant: 8),
            page.bottomAnchor.constraint(equalTo: scroll.contentLayoutGuide.bottomAnchor, constant: -16),
            page.centerXAnchor.constraint(equalTo: scroll.centerXAnchor),
            page.widthAnchor.constraint(lessThanOrEqualToConstant: metrics.contentWidth), width, widthCap,
            footerBar.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            footerBar.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            footerBar.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            footer.topAnchor.constraint(equalTo: footerBar.topAnchor, constant: 12),
            footer.bottomAnchor.constraint(equalTo: guide.bottomAnchor, constant: -16),
            footer.centerXAnchor.constraint(equalTo: footerBar.centerXAnchor),
            footer.widthAnchor.constraint(lessThanOrEqualToConstant: metrics.contentWidth), footerWidth, footerCap,
        ])
        model.onChange = { [weak self] in self?.render() }
        NotificationCenter.default.addObserver(self, selector: #selector(keyboard(_:)), name: UIResponder.keyboardWillChangeFrameNotification, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(keyboard(_:)), name: UIResponder.keyboardWillHideNotification, object: nil)
        render()
    }
    private var sideConstraints: [NSLayoutConstraint] = []
    private var headerTop: NSLayoutConstraint?

    /// A hairline under the header once the page scrolls beneath it.
    func scrollViewDidScroll(_ scrollView: UIScrollView) {
        headerRule.alpha = scrollView.contentOffset.y > -scrollView.adjustedContentInset.top + 1 ? 1 : 0
    }

    override func traitCollectionDidChange(_ previous: UITraitCollection?) {
        super.traitCollectionDidChange(previous)
        pageIdentity = ""; editor = nil; headerKey = ""
        render()
    }
    override func viewWillTransition(to size: CGSize, with coordinator: UIViewControllerTransitionCoordinator) {
        super.viewWillTransition(to: size, with: coordinator)
        coordinator.animate(alongsideTransition: nil) { [weak self] _ in self?.pageIdentity = ""; self?.editor = nil; self?.headerKey = ""; self?.render() }
    }

    @objc private func keyboard(_ note: Notification) {
        let end = (note.userInfo?[UIResponder.keyboardFrameEndUserInfoKey] as? CGRect) ?? .zero
        let overlap = note.name == UIResponder.keyboardWillHideNotification ? 0 : max(0, view.bounds.maxY - view.convert(end, from: nil).minY - footerBar.bounds.height)
        scroll.contentInset.bottom = overlap
        scroll.scrollIndicatorInsets.bottom = overlap
    }

    /// Operation pages share one identity so progress and reconnecting keep their scroll position.
    private var identity: String {
        if [.submitting, .running, .verifying].contains(model.state) || (model.state == .reconnecting && model.operation != nil) { return "operation" }
        return model.state.rawValue
    }

    func render() {
        guard isViewLoaded else { return }
        let m = metrics
        sideConstraints.forEach { $0.constant = -2 * m.side }
        headerTop?.constant = m.headerTop
        let header = "\(model.state == .editor || model.state == .review ? model.state.rawValue : "app")|\(m.regular)|\(m.narrow)"
        if header != headerKey {
            headerSlot.arrangedSubviews.forEach { $0.removeFromSuperview() }
            headerSlot.addArrangedSubview(Pages(self, m).header())
            headerKey = header
        }
        let changedPage = identity != pageIdentity
        if changedPage { pageIdentity = identity; editor = nil }
        let keys = renderKeys()
        if model.state == .editor, let editor, !changedPage {
            if keys.page != pageKey { editor.update() }
        } else if changedPage || keys.page != pageKey || identity == "operation" {
            page.arrangedSubviews.forEach { $0.removeFromSuperview() }
            page.spacing = m.sectionGap
            for view in Pages(self, m).build() { page.addArrangedSubview(view) }
        }
        pageKey = keys.page
        if changedPage || keys.footer != footerKey {
            footer.arrangedSubviews.forEach { $0.removeFromSuperview() }
            for view in Pages(self, m).footer() { footer.addArrangedSubview(view) }
            footerBar.isHidden = footer.arrangedSubviews.isEmpty
            footerKey = keys.footer
        }
        if changedPage { scroll.layoutIfNeeded(); scroll.setContentOffset(CGPoint(x: 0, y: -scroll.adjustedContentInset.top), animated: false) }
        let ticking = identity == "operation"
        if ticking && ticker == nil {
            ticker = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in self?.render() }
        } else if !ticking { ticker?.invalidate(); ticker = nil }
    }

    /// Everything the page and footer are built from, except the snapshot's
    /// capture time, which changes on every poll.
    private func renderKeys() -> (page: String, footer: String) {
        var snapshot = model.snapshot
        snapshot?.capturedAt = Date(timeIntervalSince1970: 0)
        let encoded = snapshot.flatMap { try? JSONEncoder().encode($0) }.map { $0.base64EncodedString() } ?? "-"
        let editing = [model.targetText, model.freeText, model.targetBytes.map(String.init) ?? "-", "\(model.createLinux)", "\(model.eraseFollowing)", model.reviewedPlan?.id.uuidString ?? "-"]
        let page = ([model.state.rawValue, model.error ?? "-", "\(model.busy)", "\(model.connectionOK)", model.connectionMessage ?? "-", encoded] + editing).joined(separator: "|")
        let footer = [model.state.rawValue, "\(model.busy)", model.layout?.issue ?? "-", "\(model.unchanged)", "\(model.localPlan != nil)",
                      model.operation?.status.rawValue ?? "-"].joined(separator: "|")
        return (page, footer)
    }

    func makeEditor(_ m: Metrics) -> EditorPage {
        let page = EditorPage(model: model, metrics: m, toolbar: keyboardToolbar())
        page.snapshotOffer = { [weak self] layout in self.map { Pages($0, m).snapshotOffer(layout, editor: true) } ?? nil }
        page.update()
        editor = page
        return page
    }

    private func keyboardToolbar() -> UIToolbar {
        let bar = UIToolbar(frame: CGRect(x: 0, y: 0, width: 320, height: 44))
        bar.items = [UIBarButtonItem(barButtonSystemItem: .flexibleSpace, target: nil, action: nil),
                     UIBarButtonItem(barButtonSystemItem: .done, target: self, action: #selector(dismissKeyboard))]
        return bar
    }
    @objc private func dismissKeyboard() { view.endEditing(true) }

    // MARK: Actions that present

    func confirmApply() {
        let message = model.isSimulator
            ? "Apply the changes you reviewed? This simulator build changes mock storage only."
            : "Apply these changes to internal storage? Keep power connected and do not restart until the result is verified."
        let alert = UIAlertController(title: "Start resizing?", message: message, preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "Cancel", style: .cancel))
        alert.addAction(UIAlertAction(title: "Start resize", style: .destructive) { [weak self] _ in self?.model.apply() })
        present(alert, animated: true)
    }
    func confirmRemoveSnapshot() {
        guard let name = model.layout?.systemSnapshot?.name else { return }
        let alert = UIAlertController(title: "Remove snapshot \(name)?",
                                      message: "checkra1n’s Restore System will no longer work until a new snapshot is taken. iOS can then shrink further.",
                                      preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "Cancel", style: .cancel))
        alert.addAction(UIAlertAction(title: "Remove", style: .destructive) { [weak self] _ in self?.model.removeSnapshot() })
        present(alert, animated: true)
    }
    func showTechnical() {
        guard let layout = model.layout else { return }
        presentSheet(TechnicalViewController(layout: layout, isMock: model.isSimulator))
    }
    func showMockLab() { presentSheet(MockLabViewController(model: model)) }
    private func presentSheet(_ controller: UIViewController) {
        let navigation = UINavigationController(rootViewController: controller)
        navigation.modalPresentationStyle = .formSheet
        present(navigation, animated: true)
    }
}
