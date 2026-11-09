import CoreGraphics
import Foundation
import simd

/// Treemap image and the position of each item, in pixels, origin at top left.
final class TreemapResult {
    let image: CGImage
    let pixelWidth: Int
    let pixelHeight: Int
    let root: FileNode
    let rects: [ObjectIdentifier: CGRect]
    /// Items drawn as a single tile (files, or folders too small to subdivide).
    let leaves: [(node: FileNode, rect: CGRect)]

    init(image: CGImage, root: FileNode, rects: [ObjectIdentifier: CGRect], leaves: [(node: FileNode, rect: CGRect)]) {
        self.image = image
        pixelWidth = image.width
        pixelHeight = image.height
        self.root = root
        self.rects = rects
        self.leaves = leaves
    }
}

/// Squarified treemap (Bruls, Huizing, van Wijk) with cushion shading
/// (van Wijk and van de Wetering): each level adds a parabolic ridge, and the
/// shading reveals the hierarchy without drawing borders.
final class TreemapRenderer {
    private struct Box {
        var x0, y0, x1, y1: Double
    }

    // Cushion parameters.
    private static let initialHeight = 0.38
    private static let heightScale = 0.91
    private static let ambient = 0.15
    private static let brightness = 1.12
    private static let light: SIMD3<Double> = {
        let raw = SIMD3<Double>(-1, -1, 10)
        return raw / (raw * raw).sum().squareRoot()
    }()

    private let width: Int
    private let height: Int
    private let pixels: UnsafeMutablePointer<UInt32>
    private let colors: [SIMD3<Float>]
    private let isCancelled: () -> Bool
    private var rects: [ObjectIdentifier: CGRect] = [:]
    private var leaves: [(node: FileNode, rect: CGRect)] = []
    private var drawn = 0
    private var cancelled = false

    private init(width: Int, height: Int, pixels: UnsafeMutablePointer<UInt32>,
                 colors: [SIMD3<Float>], isCancelled: @escaping () -> Bool) {
        self.width = width
        self.height = height
        self.pixels = pixels
        self.colors = colors
        self.isCancelled = isCancelled
    }

    /// Recursive: call on a thread with a large stack, holding treeLock.
    static func render(root: FileNode, width: Int, height: Int, colors: [SIMD3<Float>],
                       isCancelled: @escaping () -> Bool) -> TreemapResult? {
        guard width > 0, height > 0,
              let space = CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8,
                                      bytesPerRow: width * 4, space: space,
                                      bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
                                          | CGBitmapInfo.byteOrder32Big.rawValue),
              let data = context.data
        else { return nil }

        let pixels = data.bindMemory(to: UInt32.self, capacity: width * height)
        pixels.initialize(repeating: 0xFF26_2626, count: width * height)

        let renderer = TreemapRenderer(width: width, height: height, pixels: pixels,
                                       colors: colors, isCancelled: isCancelled)
        if root.size > 0 {
            renderer.place(root, Box(x0: 0, y0: 0, x1: Double(width), y1: Double(height)),
                           surface: .zero, ridge: initialHeight)
        }
        guard !renderer.cancelled, let image = context.makeImage() else { return nil }
        return TreemapResult(image: image, root: root, rects: renderer.rects, leaves: renderer.leaves)
    }

    private func place(_ node: FileNode, _ box: Box, surface: SIMD4<Double>, ridge: Double) {
        if cancelled { return }
        let ix0 = Int(box.x0.rounded()), ix1 = Int(box.x1.rounded())
        let iy0 = Int(box.y0.rounded()), iy1 = Int(box.y1.rounded())
        guard ix1 > ix0, iy1 > iy0 else { return }
        rects[ObjectIdentifier(node)] = CGRect(x: ix0, y: iy0, width: ix1 - ix0, height: iy1 - iy0)

        // surface: linear x, linear y, squared x, squared y.
        var surface = surface
        let rx = TreemapRenderer.ridge(box.x0, box.x1, ridge)
        let ry = TreemapRenderer.ridge(box.y0, box.y1, ridge)
        surface += SIMD4(rx.linear, ry.linear, rx.square, ry.square)

        if node.kind == .directory, (ix1 - ix0 > 2 || iy1 - iy0 > 2),
           let first = node.children.first, first.size > 0 {
            layoutChildren(of: node, in: box, surface: surface, ridge: ridge * TreemapRenderer.heightScale)
        } else {
            shade(ix0, ix1, iy0, iy1, surface: surface, color: ExtensionStats.color(of: node, colors: colors))
            leaves.append((node, CGRect(x: ix0, y: iy0, width: ix1 - ix0, height: iy1 - iy0)))
            drawn += 1
            if drawn & 2047 == 0 && isCancelled() { cancelled = true }
        }
    }

    /// Parabolic ridge of height h over [a, b]: linear and squared coefficients.
    private static func ridge(_ a: Double, _ b: Double, _ h: Double) -> (linear: Double, square: Double) {
        let span = b - a
        guard span > 0 else { return (0, 0) }
        return (4 * h * (b + a) / span, -4 * h / span)
    }

    /// Lays out the children (sorted by decreasing size) in rows along the short
    /// side, adding items while the worst aspect ratio keeps improving.
    private func layoutChildren(of node: FileNode, in box: Box, surface: SIMD4<Double>, ridge: Double) {
        let children = node.children
        var count = 0
        var total = 0.0
        for child in children {
            if child.size <= 0 { break }
            total += Double(child.size)
            count += 1
        }
        guard total > 0 else { return }

        var rest = box
        var remaining = total
        var i = 0
        while i < count && !cancelled {
            let w = rest.x1 - rest.x0, h = rest.y1 - rest.y0
            // Nothing visible left: the remaining items are too small.
            if Int(rest.x1.rounded()) <= Int(rest.x0.rounded()) || Int(rest.y1.rounded()) <= Int(rest.y0.rounded()) { break }

            let vertical = w >= h          // row = column against the left edge
            let side = vertical ? h : w     // length of the row
            let span = vertical ? w : h     // dimension along which rows advance

            var rowSum = 0.0
            var j = i
            var worst = Double.infinity
            let largest = Double(children[i].size)
            while j < count {
                let size = Double(children[j].size)
                let sum = rowSum + size
                let thickness = sum / remaining * span
                let big = largest / sum * side
                let small = size / sum * side
                let ratio = max(max(thickness / big, big / thickness), max(thickness / small, small / thickness))
                if j > i && ratio > worst { break }
                worst = ratio
                rowSum = sum
                j += 1
            }

            let thickness = j == count ? span : rowSum / remaining * span
            var offset = vertical ? rest.y0 : rest.x0
            let end = vertical ? rest.y1 : rest.x1
            for k in i..<j {
                let next = k == j - 1 ? end : offset + Double(children[k].size) / rowSum * side
                let childBox = vertical
                    ? Box(x0: rest.x0, y0: offset, x1: rest.x0 + thickness, y1: next)
                    : Box(x0: offset, y0: rest.y0, x1: next, y1: rest.y0 + thickness)
                place(children[k], childBox, surface: surface, ridge: ridge)
                offset = next
            }
            if vertical { rest.x0 += thickness } else { rest.y0 += thickness }
            remaining -= rowSum
            i = j
        }
    }

    private func shade(_ x0: Int, _ x1: Int, _ y0: Int, _ y1: Int, surface s: SIMD4<Double>, color: SIMD3<Float>) {
        let light = TreemapRenderer.light
        let ambient = TreemapRenderer.ambient
        let diffuse = 1 - ambient
        let gain = TreemapRenderer.brightness
        for y in y0..<y1 {
            let ny = -(2 * s.w * (Double(y) + 0.5) + s.y)
            let row = pixels + y * width
            for x in x0..<x1 {
                let nx = -(2 * s.z * (Double(x) + 0.5) + s.x)
                var cosa = (nx * light.x + ny * light.y + light.z) / (nx * nx + ny * ny + 1).squareRoot()
                if cosa < 0 { cosa = 0 }
                let intensity = Float((ambient + diffuse * cosa) * gain)
                let c = simd_clamp(color * intensity, SIMD3<Float>(repeating: 0), SIMD3<Float>(repeating: 1)) * 255
                row[x] = UInt32(c.x) | UInt32(c.y) << 8 | UInt32(c.z) << 16 | 0xFF00_0000
            }
        }
    }
}
