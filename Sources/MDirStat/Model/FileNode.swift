import Foundation

/// Tree lock: the treemap renderer reads the tree on a separate thread while the
/// main thread modifies it (Trash, refresh). Both take it.
let treeLock = NSLock()

/// An item of the scanned tree. A class, so that NSOutlineView can use it as an
/// item and the tree is shared without copies.
final class FileNode {
    enum Kind: UInt8 {
        case file, directory
        /// Pseudo items of a volume: free space and space the scan did not find.
        case freeSpace, unknown
    }

    let name: String
    let kind: Kind
    weak var parent: FileNode?
    var children: [FileNode] = []
    /// Bytes allocated on disk (st_blocks * 512); cumulative for a folder.
    var size: Int64 = 0
    /// Files and subfolders in the subtree (0 for a file).
    var files = 0
    var subdirs = 0
    /// time_t; for a folder, the most recent in the subtree.
    var modified = 0
    /// Index into ExtensionStats.entries (-1 for a folder).
    var extID: Int32 = -1
    /// Unreadable folder (permissions, TCC privacy protection).
    var unreadable = false
    /// Unreadable folders in the subtree.
    var errors = 0

    init(name: String, kind: Kind, parent: FileNode? = nil) {
        self.name = name
        self.kind = kind
        self.parent = parent
    }

    var isDirectory: Bool { kind == .directory }
    var isPseudo: Bool { kind == .freeSpace || kind == .unknown }
    var items: Int { files + subdirs }

    /// Full path; the root's name is already an absolute path.
    var path: String {
        guard let parent else { return name }
        let base = parent.path
        return base.hasSuffix("/") ? base + name : base + "/" + name
    }

    var url: URL { URL(fileURLWithPath: path, isDirectory: isDirectory) }

    func isDescendant(of ancestor: FileNode) -> Bool {
        var node: FileNode? = self
        while let current = node {
            if current === ancestor { return true }
            node = current.parent
        }
        return false
    }

    /// Ancestors, from the parent up to the root.
    var ancestors: [FileNode] {
        var result: [FileNode] = []
        var node = parent
        while let current = node {
            result.append(current)
            node = current.parent
        }
        return result
    }

    /// Children stay sorted by decreasing size: the treemap relies on it.
    func sortChildren() {
        children.sort { $0.size > $1.size }
    }
}

extension FileNode {
    /// Removes a child and propagates sizes and counts up to the root.
    /// Call while holding treeLock.
    func removeChild(_ child: FileNode) {
        guard let index = children.firstIndex(where: { $0 === child }) else { return }
        children.remove(at: index)
        let fileDelta = child.kind == .file ? 1 : child.files
        let dirDelta = child.kind == .directory ? child.subdirs + 1 : 0
        propagate(size: -child.size, files: -fileDelta, subdirs: -dirDelta, errors: -child.errors)
    }

    /// Replaces a child with a new scan of the same folder.
    func replaceChild(_ old: FileNode, with new: FileNode) {
        guard let index = children.firstIndex(where: { $0 === old }) else { return }
        children[index] = new
        new.parent = self
        propagate(size: new.size - old.size,
                  files: new.files - old.files,
                  subdirs: new.subdirs - old.subdirs,
                  errors: new.errors - old.errors)
    }

    private func propagate(size: Int64, files: Int, subdirs: Int, errors: Int) {
        var node: FileNode? = self
        while let current = node {
            current.size += size
            current.files += files
            current.subdirs += subdirs
            current.errors += errors
            current.sortChildren()
            node = current.parent
        }
    }
}
