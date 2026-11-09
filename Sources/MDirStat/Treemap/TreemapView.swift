import AppKit

/// Counter shared between the main thread and the render thread.
private final class Generation {
    private let lock = NSLock()
    private var value = 0

    func next() -> Int {
        lock.lock()
        defer { lock.unlock() }
        value += 1
        return value
    }

    var current: Int {
        lock.lock()
        defer { lock.unlock() }
        return value
    }
}

/// Shows the treemap, rendered in the background at screen resolution.
final class TreemapView: NSView {
    var root: FileNode? {
        didSet {
            result = nil
            invalidate()
        }
    }
    var colors: [SIMD3<Float>] = []
    var selection: FileNode? { didSet { needsDisplay = true } }
    var highlightedExtension: Int32? { didSet { needsDisplay = true } }

    var onSelect: ((FileNode) -> Void)?
    var onHover: ((FileNode?) -> Void)?
    var onRendered: (() -> Void)?
    var menuProvider: ((FileNode) -> NSMenu?)?

    private var result: TreemapResult?
    private let generation = Generation()
    private var pendingRender: DispatchWorkItem?
    private var isRendering = false

    override var isFlipped: Bool { true }
    override var isOpaque: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    /// Call after any change to the tree.
    func invalidate() {
        pendingRender?.cancel()
        pendingRender = nil
        // The running render reads the tree: it stops at its next check.
        _ = generation.next()
        render()
    }

    /// Cancels a running render before the tree is modified.
    func cancelRendering() {
        _ = generation.next()
    }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        scheduleRender()
    }

    override func viewDidEndLiveResize() {
        super.viewDidEndLiveResize()
        invalidate()
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        invalidate()
    }

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        invalidate()
    }

    private func scheduleRender() {
        pendingRender?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.invalidate() }
        pendingRender = work
        DispatchQueue.main.asyncAfter(deadline: .now() + (inLiveResize ? 0.25 : 0.05), execute: work)
    }

    private func render() {
        guard let root, bounds.width >= 1, bounds.height >= 1, window != nil else {
            needsDisplay = true
            return
        }
        let scale = window?.backingScaleFactor ?? 2
        let width = Int(bounds.width * scale), height = Int(bounds.height * scale)
        let token = generation.next()
        let generation = self.generation
        let colors = self.colors
        isRendering = true
        let thread = Thread { [weak self] in
            treeLock.lock()
            let output = TreemapRenderer.render(root: root, width: width, height: height, colors: colors) {
                generation.current != token
            }
            treeLock.unlock()
            DispatchQueue.main.async {
                guard let self, generation.current == token else { return }
                self.isRendering = false
                if let output {
                    self.result = output
                    self.needsDisplay = true
                    self.onRendered?()
                }
            }
        }
        thread.stackSize = 64 << 20
        thread.qualityOfService = .userInitiated
        thread.start()
    }

    // MARK: - Drawing

    override func draw(_ dirtyRect: NSRect) {
        NSColor(white: 0.15, alpha: 1).setFill()
        bounds.fill()
        guard let result, let context = NSGraphicsContext.current?.cgContext else {
            if root == nil { drawPlaceholder() }
            return
        }

        context.saveGState()
        context.interpolationQuality = inLiveResize ? .low : .none
        context.translateBy(x: 0, y: bounds.height)
        context.scaleBy(x: 1, y: -1)
        context.draw(result.image, in: CGRect(origin: .zero, size: bounds.size))
        context.restoreGState()

        let sx = bounds.width / CGFloat(result.pixelWidth)
        let sy = bounds.height / CGFloat(result.pixelHeight)
        func toView(_ rect: CGRect) -> CGRect {
            CGRect(x: rect.minX * sx, y: rect.minY * sy, width: rect.width * sx, height: rect.height * sy)
        }

        if let ext = highlightedExtension {
            let path = CGMutablePath()
            for leaf in result.leaves where leaf.node.kind == .file && leaf.node.extID == ext {
                path.addRect(toView(leaf.rect).insetBy(dx: 0.5, dy: 0.5))
            }
            context.addPath(path)
            context.setStrokeColor(NSColor.white.cgColor)
            context.setLineWidth(1)
            context.strokePath()
        }

        if let selection, let rect = displayedRect(of: selection, in: result) {
            let frame = toView(rect).insetBy(dx: 1, dy: 1)
            context.setLineWidth(3)
            context.setStrokeColor(NSColor.black.withAlphaComponent(0.6).cgColor)
            context.stroke(frame)
            context.setLineWidth(1.5)
            context.setStrokeColor(NSColor.white.cgColor)
            context.stroke(frame)
        }
    }

    private func drawPlaceholder() {
        let text = "Open a volume or folder to see its treemap" as NSString
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 13),
            .foregroundColor: NSColor(white: 0.6, alpha: 1),
        ]
        let size = text.size(withAttributes: attributes)
        text.draw(at: NSPoint(x: bounds.midX - size.width / 2, y: bounds.midY - size.height / 2),
                  withAttributes: attributes)
    }

    /// Rectangle of the item, or of its closest drawn ancestor.
    private func displayedRect(of node: FileNode, in result: TreemapResult) -> CGRect? {
        guard node.isDescendant(of: result.root) else { return nil }
        var current: FileNode? = node
        while let candidate = current {
            if let rect = result.rects[ObjectIdentifier(candidate)] { return rect }
            current = candidate.parent
        }
        return nil
    }

    // MARK: - Mouse

    func node(at point: NSPoint) -> FileNode? {
        guard let result else { return nil }
        let pixel = CGPoint(x: point.x * CGFloat(result.pixelWidth) / bounds.width,
                            y: point.y * CGFloat(result.pixelHeight) / bounds.height)
        var current = result.root
        guard result.rects[ObjectIdentifier(current)]?.contains(pixel) == true else { return nil }
        descend: while current.kind == .directory {
            for child in current.children {
                if let rect = result.rects[ObjectIdentifier(child)], rect.contains(pixel) {
                    current = child
                    continue descend
                }
            }
            break
        }
        return current
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: .zero,
                                       options: [.mouseMoved, .mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect],
                                       owner: self))
    }

    override func mouseMoved(with event: NSEvent) {
        onHover?(node(at: convert(event.locationInWindow, from: nil)))
    }

    override func mouseExited(with event: NSEvent) {
        onHover?(nil)
    }

    override func mouseDown(with event: NSEvent) {
        if let node = node(at: convert(event.locationInWindow, from: nil)) {
            onSelect?(node)
        }
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        guard let node = node(at: convert(event.locationInWindow, from: nil)) else { return nil }
        onSelect?(node)
        return menuProvider?(node)
    }
}
