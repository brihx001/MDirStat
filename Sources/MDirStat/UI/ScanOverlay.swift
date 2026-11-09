import AppKit

/// Panneau affiche par-dessus les vues pendant une analyse.
final class ScanOverlay: NSVisualEffectView {
    let titleLabel = NSTextField(labelWithString: "")
    let detailLabel = NSTextField(labelWithString: "")
    let cancelButton = NSButton(title: "Cancel", target: nil, action: nil)
    private let spinner = NSProgressIndicator()

    override init(frame: NSRect) {
        super.init(frame: frame)
        material = .underWindowBackground
        blendingMode = .withinWindow
        state = .active

        spinner.style = .spinning
        spinner.controlSize = .regular
        titleLabel.font = .boldSystemFont(ofSize: 14)
        titleLabel.lineBreakMode = .byTruncatingMiddle
        titleLabel.alignment = .center
        detailLabel.font = .monospacedDigitSystemFont(ofSize: 12, weight: .regular)
        detailLabel.textColor = .secondaryLabelColor
        detailLabel.alignment = .center
        cancelButton.keyEquivalent = "\u{1b}"

        let stack = NSStackView(views: [spinner, titleLabel, detailLabel, cancelButton])
        stack.orientation = .vertical
        stack.spacing = 10
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.centerXAnchor.constraint(equalTo: centerXAnchor),
            stack.centerYAnchor.constraint(equalTo: centerYAnchor),
            stack.widthAnchor.constraint(lessThanOrEqualTo: widthAnchor, constant: -40),
            titleLabel.widthAnchor.constraint(lessThanOrEqualToConstant: 600),
        ])
    }

    required init?(coder: NSCoder) { fatalError() }

    func show(title: String) {
        titleLabel.stringValue = title
        detailLabel.stringValue = "Starting…"
        isHidden = false
        spinner.startAnimation(nil)
    }

    func hide() {
        spinner.stopAnimation(nil)
        isHidden = true
    }
}
