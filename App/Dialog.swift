import UIKit

/// A confirmation in the app's look. UIAlertController is always light on iOS 12,
/// so the confirmations (start or stop resizing, remove the snapshot) use this
/// instead: the installer's dialog over a Tokyo Night scrim, Cancel and the
/// action side by side.
final class DialogController: UIViewController {
    private let titleText: String
    private let message: String
    private let actionTitle: String
    private let cancelTitle: String
    private let destructive: Bool
    private let onConfirm: () -> Void

    init(title: String, message: String, action: String, cancel: String = "Cancel", destructive: Bool = true, onConfirm: @escaping () -> Void) {
        titleText = title; self.message = message; actionTitle = action; cancelTitle = cancel; self.destructive = destructive; self.onConfirm = onConfirm
        super.init(nibName: nil, bundle: nil)
        modalPresentationStyle = .overFullScreen
        modalTransitionStyle = .crossDissolve
    }
    required init?(coder: NSCoder) { fatalError() }

    override var preferredStatusBarStyle: UIStatusBarStyle { .lightContent }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = Theme.scrim
        let box = UIView()
        box.backgroundColor = Theme.dialog
        box.layer.borderWidth = 1; box.layer.borderColor = Theme.dialogBorder.cgColor
        box.layer.shadowColor = UIColor.black.cgColor; box.layer.shadowOpacity = 0.5
        box.layer.shadowRadius = 25; box.layer.shadowOffset = CGSize(width: 0, height: 20)
        box.accessibilityViewIsModal = true
        let heading = label(titleText, Theme.font(15, .semibold, .headline), Theme.ink, align: .center)
        heading.accessibilityTraits = .header
        let text = label(message, Theme.font(12), Theme.muted, align: .center)
        let body = stack(.vertical, 8, [heading, text])
        body.isLayoutMarginsRelativeArrangement = true
        body.layoutMargins = UIEdgeInsets(top: 20, left: 18, bottom: 18, right: 18)
        let cancel = button(cancelTitle, color: Theme.blue, weight: .regular) { [weak self] in self?.dismiss(animated: true) }
        let confirm = button(actionTitle, color: destructive ? Theme.destructive : Theme.blue, weight: .semibold) { [weak self] in
            guard let self else { return }
            self.dismiss(animated: true) { self.onConfirm() }
        }
        let buttons = stack(.horizontal, 0, [cancel, rule(vertical: true), confirm])
        buttons.distribution = .fill
        cancel.widthAnchor.constraint(equalTo: confirm.widthAnchor).isActive = true
        let column = stack(.vertical, 0, [body, rule(vertical: false), buttons])
        column.translatesAutoresizingMaskIntoConstraints = false
        box.addSubview(column)
        box.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(box)
        let width = box.widthAnchor.constraint(equalToConstant: 300)
        width.priority = .defaultHigh
        NSLayoutConstraint.activate([
            column.topAnchor.constraint(equalTo: box.topAnchor), column.bottomAnchor.constraint(equalTo: box.bottomAnchor),
            column.leadingAnchor.constraint(equalTo: box.leadingAnchor), column.trailingAnchor.constraint(equalTo: box.trailingAnchor),
            box.centerXAnchor.constraint(equalTo: view.centerXAnchor), box.centerYAnchor.constraint(equalTo: view.centerYAnchor),
            width, box.widthAnchor.constraint(lessThanOrEqualTo: view.widthAnchor, constant: -40),
        ])
    }

    private func rule(vertical: Bool) -> UIView {
        let line = UIView(); line.backgroundColor = Theme.dialogBorder
        (vertical ? line.widthAnchor : line.heightAnchor).constraint(equalToConstant: 1).isActive = true
        return line
    }

    private func button(_ title: String, color: UIColor, weight: UIFont.Weight, action: @escaping () -> Void) -> UIButton {
        let button = TouchButton(type: .system)
        button.setTitle(title, for: .normal)
        button.titleLabel?.font = Theme.font(14, weight)
        button.setTitleColor(color, for: .normal)
        button.heightAnchor.constraint(greaterThanOrEqualToConstant: 48).isActive = true
        button.addAction(action)
        return button
    }

    // Escape (VoiceOver's two-finger scrub) cancels, as an alert's Cancel would.
    override func accessibilityPerformEscape() -> Bool { dismiss(animated: true); return true }
}
