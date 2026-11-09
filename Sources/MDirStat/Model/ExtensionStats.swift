import AppKit
import UniformTypeIdentifiers

struct ExtensionEntry {
    /// Extension en minuscules, sans le point ; vide pour « sans extension ».
    let ext: String
    var bytes: Int64
    var files: Int
    /// Indice dans la palette, -1 pour le gris des extensions mineures.
    var colorIndex: Int
}

/// Repartition par extension, et couleur de chaque fichier dans le treemap.
final class ExtensionStats {
    /// Douze teintes vives pour les extensions qui pesent le plus, le reste en gris.
    static let palette: [SIMD3<Float>] = [
        SIMD3(0.22, 0.42, 1.00), // bleu
        SIMD3(1.00, 0.26, 0.26), // rouge
        SIMD3(0.22, 0.84, 0.32), // vert
        SIMD3(1.00, 0.84, 0.12), // jaune
        SIMD3(0.12, 0.84, 0.94), // cyan
        SIMD3(0.94, 0.32, 0.94), // magenta
        SIMD3(1.00, 0.56, 0.12), // orange
        SIMD3(0.62, 0.46, 1.00), // violet
        SIMD3(0.58, 1.00, 0.56), // vert clair
        SIMD3(1.00, 0.62, 0.72), // rose
        SIMD3(0.52, 0.80, 1.00), // ciel
        SIMD3(0.86, 0.74, 0.46), // sable
    ]
    static let otherColor = SIMD3<Float>(0.62, 0.62, 0.62)
    static let directoryColor = SIMD3<Float>(0.50, 0.50, 0.52)
    static let freeSpaceColor = SIMD3<Float>(0.80, 0.80, 0.80)
    static let unknownColor = SIMD3<Float>(0.95, 0.80, 0.42)

    private(set) var entries: [ExtensionEntry] = []

    var totalBytes: Int64 { entries.reduce(0) { $0 + $1.bytes } }

    /// Parcourt l'arbre et inscrit l'indice d'extension dans chaque fichier.
    init(root: FileNode) {
        var indexByExt: [String: Int] = [:]
        var stack = [root]
        while let node = stack.popLast() {
            if node.kind == .directory {
                stack.append(contentsOf: node.children)
                continue
            }
            guard node.kind == .file else { continue }
            let ext = ExtensionStats.extensionOf(node.name)
            let index: Int
            if let known = indexByExt[ext] {
                index = known
            } else {
                index = entries.count
                indexByExt[ext] = index
                entries.append(ExtensionEntry(ext: ext, bytes: 0, files: 0, colorIndex: -1))
            }
            entries[index].bytes += node.size
            entries[index].files += 1
            node.extID = Int32(index)
        }

        // Les couleurs vont aux extensions les plus lourdes.
        let ranking = entries.indices.sorted { entries[$0].bytes > entries[$1].bytes }
        for (rank, index) in ranking.prefix(ExtensionStats.palette.count).enumerated() {
            entries[index].colorIndex = rank
        }
    }

    /// Retire un sous-arbre supprime (les indices des autres fichiers ne bougent pas).
    func remove(subtree: FileNode) {
        var stack = [subtree]
        while let node = stack.popLast() {
            if node.kind == .directory {
                stack.append(contentsOf: node.children)
            } else if node.kind == .file, node.extID >= 0, Int(node.extID) < entries.count {
                entries[Int(node.extID)].bytes -= node.size
                entries[Int(node.extID)].files -= 1
            }
        }
    }

    /// Couleur de base de chaque extension, indexee par extID, pour le rendu.
    var colorsByID: [SIMD3<Float>] {
        entries.map { $0.colorIndex >= 0 ? ExtensionStats.palette[$0.colorIndex] : ExtensionStats.otherColor }
    }

    static func color(of node: FileNode, colors: [SIMD3<Float>]) -> SIMD3<Float> {
        switch node.kind {
        case .file:
            let id = Int(node.extID)
            return id >= 0 && id < colors.count ? colors[id] : otherColor
        case .directory: return directoryColor
        case .freeSpace: return freeSpaceColor
        case .unknown: return unknownColor
        }
    }

    static func nsColor(_ color: SIMD3<Float>) -> NSColor {
        NSColor(srgbRed: CGFloat(color.x), green: CGFloat(color.y), blue: CGFloat(color.z), alpha: 1)
    }

    static func extensionOf(_ name: String) -> String {
        let utf8 = name.utf8
        guard let dot = utf8.lastIndex(of: UInt8(ascii: ".")), dot != utf8.startIndex else { return "" }
        let start = utf8.index(after: dot)
        guard start != utf8.endIndex else { return "" }
        return String(name[start...]).lowercased()
    }

    private static var descriptions: [String: String] = [:]

    /// Description du type (« JPEG image »), via UTType ; mise en cache.
    static func description(of ext: String) -> String {
        if ext.isEmpty { return "No extension" }
        if let cached = descriptions[ext] { return cached }
        let text = UTType(filenameExtension: ext)?.localizedDescription ?? ""
        descriptions[ext] = text
        return text
    }
}
