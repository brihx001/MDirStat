import AppKit
import UniformTypeIdentifiers

/// Text cell with an optional image, built without a nib.
final class TextCell: NSTableCellView {
    init(identifier: NSUserInterfaceItemIdentifier, alignment: NSTextAlignment, withImage: Bool) {
        super.init(frame: .zero)
        self.identifier = identifier

        let field = NSTextField(labelWithString: "")
        field.alignment = alignment
        field.lineBreakMode = alignment == .left ? (withImage ? .byTruncatingMiddle : .byTruncatingTail) : .byClipping
        field.font = alignment == .right
            ? .monospacedDigitSystemFont(ofSize: NSFont.systemFontSize, weight: .regular)
            : .systemFont(ofSize: NSFont.systemFontSize)
        field.translatesAutoresizingMaskIntoConstraints = false
        field.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        addSubview(field)
        textField = field

        var constraints = [
            field.centerYAnchor.constraint(equalTo: centerYAnchor),
            field.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -2),
        ]
        if withImage {
            let image = NSImageView()
            image.translatesAutoresizingMaskIntoConstraints = false
            image.imageScaling = .scaleProportionallyUpOrDown
            addSubview(image)
            imageView = image
            constraints += [
                image.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 2),
                image.centerYAnchor.constraint(equalTo: centerYAnchor),
                image.widthAnchor.constraint(equalToConstant: 16),
                image.heightAnchor.constraint(equalToConstant: 16),
                field.leadingAnchor.constraint(equalTo: image.trailingAnchor, constant: 5),
            ]
        } else {
            constraints.append(field.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 2))
        }
        NSLayoutConstraint.activate(constraints)
    }

    required init?(coder: NSCoder) { fatalError() }
}

/// Proportion bar followed by the percentage.
final class PercentCell: NSTableCellView {
    var fraction: Double = 0 { didSet { needsDisplay = true } }
    var barColor: NSColor = .controlAccentColor { didSet { needsDisplay = true } }

    init(identifier: NSUserInterfaceItemIdentifier) {
        super.init(frame: .zero)
        self.identifier = identifier
    }

    required init?(coder: NSCoder) { fatalError() }

    private static let attributes: [NSAttributedString.Key: Any] = [
        .font: NSFont.monospacedDigitSystemFont(ofSize: NSFont.smallSystemFontSize, weight: .regular),
        .foregroundColor: NSColor.secondaryLabelColor,
    ]

    override func draw(_ dirtyRect: NSRect) {
        let text = Format.percent(fraction) as NSString
        let textWidth: CGFloat = 46
        let barRect = NSRect(x: 3, y: bounds.midY - 5, width: max(bounds.width - textWidth - 6, 0), height: 10)
        if barRect.width > 4 {
            NSColor.quaternaryLabelColor.setFill()
            NSBezierPath(roundedRect: barRect, xRadius: 2, yRadius: 2).fill()
            var filled = barRect
            filled.size.width = max(barRect.width * CGFloat(min(max(fraction, 0), 1)), fraction > 0 ? 1 : 0)
            barColor.setFill()
            NSBezierPath(roundedRect: filled, xRadius: 2, yRadius: 2).fill()
        }
        let size = text.size(withAttributes: PercentCell.attributes)
        text.draw(at: NSPoint(x: bounds.maxX - size.width - 3, y: bounds.midY - size.height / 2),
                  withAttributes: PercentCell.attributes)
    }
}

/// Icons per extension, cached (NSWorkspace is slow per file).
enum Icons {
    private static var cache: [String: NSImage] = [:]
    private static var appIcons: [String: NSImage] = [:]
    static let folder = NSWorkspace.shared.icon(for: .folder)
    static let freeSpace = NSImage(systemSymbolName: "circle.dashed", accessibilityDescription: "Free space")!
    static let unknown = NSImage(systemSymbolName: "questionmark.circle", accessibilityDescription: "Unknown")!
    static let warning = NSImage(systemSymbolName: "exclamationmark.triangle.fill", accessibilityDescription: "Unreadable")!

    static func icon(for node: FileNode) -> NSImage {
        switch node.kind {
        case .freeSpace: return freeSpace
        case .unknown: return unknown
        case .directory:
            if node.unreadable { return warning }
            guard node.name.hasSuffix(".app") else { return folder }
            // Each application's own icon, read once per path.
            let path = node.path
            if let cached = appIcons[path] { return cached }
            let image = NSWorkspace.shared.icon(forFile: path)
            appIcons[path] = image
            return image
        case .file:
            let ext = ExtensionStats.extensionOf(node.name)
            if let cached = cache[ext] { return cached }
            let type = ext.isEmpty ? UTType.data : (UTType(filenameExtension: ext) ?? .data)
            let image = NSWorkspace.shared.icon(for: type)
            cache[ext] = image
            return image
        }
    }

    /// Color swatch of an extension, with the same shading as the treemap.
    static func swatch(_ color: SIMD3<Float>) -> NSImage {
        NSImage(size: NSSize(width: 14, height: 14), flipped: false) { rect in
            let base = ExtensionStats.nsColor(color)
            let path = NSBezierPath(roundedRect: rect.insetBy(dx: 1, dy: 1), xRadius: 3, yRadius: 3)
            NSGradient(colors: [base.blended(withFraction: 0.35, of: .white) ?? base,
                                base.blended(withFraction: 0.35, of: .black) ?? base])?
                .draw(in: path, relativeCenterPosition: NSPoint(x: -0.4, y: 0.4))
            NSColor.black.withAlphaComponent(0.25).setStroke()
            path.lineWidth = 0.5
            path.stroke()
            return true
        }
    }
}
