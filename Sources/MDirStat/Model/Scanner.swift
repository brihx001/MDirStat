import Darwin
import Foundation

/// Counters read by the interface during a scan.
final class ScanProgress {
    struct Snapshot {
        var files = 0
        var dirs = 0
        var bytes: Int64 = 0
        var errors = 0
    }

    private let lock = NSLock()
    private var value = Snapshot()

    func add(files: Int, dirs: Int, bytes: Int64, errors: Int) {
        lock.lock()
        value.files += files
        value.dirs += dirs
        value.bytes += bytes
        value.errors += errors
        lock.unlock()
    }

    var snapshot: Snapshot {
        lock.lock()
        defer { lock.unlock() }
        return value
    }
}

/// Parallel folder scan: a pool of threads shares a stack of folders to read
/// (getattrlistbulk, or readdir + fstatat as a fallback). Each folder is read by
/// a single thread, the only one filling its children: the tree is built without locks.
final class Scanner {
    let rootPath: String
    let progress = ScanProgress()

    private let condition = NSCondition()
    private var stack: [(FileNode, String)] = []
    /// Folders waiting plus folders being read.
    private var pending = 0
    private var isCancelled = false

    /// Allowed volumes: mount points are never crossed.
    private var devices: Set<dev_t> = []
    private var excluded: Set<String> = []

    private struct LinkKey: Hashable {
        let device: dev_t
        let inode: ino_t
    }
    private let linkLock = NSLock()
    private var seenLinks = Set<LinkKey>()

    init(path: String) {
        var normalized = (path as NSString).standardizingPath
        if normalized.isEmpty { normalized = "/" }
        rootPath = normalized
    }

    var cancelled: Bool {
        condition.lock()
        defer { condition.unlock() }
        return isCancelled
    }

    func cancel() {
        condition.lock()
        isCancelled = true
        condition.broadcast()
        condition.unlock()
    }

    /// Blocking, and recursive for aggregation: run on a thread with a large stack.
    /// Returns nil if the root is not a readable folder or the scan was cancelled.
    func run(rootName: String? = nil) -> FileNode? {
        var info = stat()
        guard lstat(rootPath, &info) == 0, info.st_mode & S_IFMT == S_IFDIR else { return nil }

        devices = [info.st_dev]
        if rootPath == "/" {
            // Startup disk: the sealed system volume plus the data volume, reached
            // through firmlinks (/Users, /Applications, /private...). /System/Volumes
            // is skipped, as it would count the data twice.
            var data = stat()
            if lstat("/System/Volumes/Data", &data) == 0 { devices.insert(data.st_dev) }
            // .nofollow, .resolve and .vol are pseudo folders that expose the
            // whole file system again.
            excluded = ["/System/Volumes", "/.nofollow", "/.resolve", "/.vol"]
        }

        let root = FileNode(name: rootName ?? rootPath, kind: .directory)
        root.size = Int64(info.st_blocks) * 512
        root.modified = Int(info.st_mtimespec.tv_sec)
        stack = [(root, rootPath)]
        pending = 1

        let workers = Int(ProcessInfo.processInfo.environment["MDIRSTAT_WORKERS"] ?? "")
            ?? min(16, max(4, ProcessInfo.processInfo.activeProcessorCount * 2))
        let group = DispatchGroup()
        for _ in 0..<workers {
            group.enter()
            let thread = Thread { [self] in
                work()
                group.leave()
            }
            thread.qualityOfService = .userInitiated
            thread.start()
        }
        group.wait()

        if cancelled { return nil }
        Scanner.aggregate(root)
        return root
    }

    private func work() {
        // getattrlistbulk buffer, one per thread.
        let buffer = UnsafeMutableRawPointer.allocate(byteCount: Scanner.bulkSize, alignment: 8)
        defer { buffer.deallocate() }
        while true {
            condition.lock()
            while stack.isEmpty && pending > 0 && !isCancelled {
                condition.wait()
            }
            if isCancelled || stack.isEmpty {
                condition.unlock()
                return
            }
            let (node, path) = stack.removeLast()
            condition.unlock()

            let subdirectories = read(node, path: path, buffer: buffer)

            condition.lock()
            stack.append(contentsOf: subdirectories)
            pending += subdirectories.count - 1
            if pending == 0 || !subdirectories.isEmpty { condition.broadcast() }
            condition.unlock()
        }
    }

    private static let nameOffset = MemoryLayout<dirent>.offset(of: \dirent.d_name)!

    /// Reads a folder, fills its children and returns the subfolders to visit.
    private func read(_ node: FileNode, path: String, buffer: UnsafeMutableRawPointer) -> [(FileNode, String)] {
        let fd = open(path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard fd >= 0 else {
            node.unreadable = true
            progress.add(files: 0, dirs: 1, bytes: 0, errors: 1)
            return []
        }
        if let result = readBulk(node, path: path, fd: fd, buffer: buffer) {
            close(fd)
            return result
        }
        return readEntries(node, path: path, fd: fd)
    }

    static let bulkSize = 128 * 1024

    private static let commonAttributes = attrgroup_t(ATTR_CMN_RETURNED_ATTRS) | attrgroup_t(ATTR_CMN_NAME)
        | attrgroup_t(ATTR_CMN_ERROR) | attrgroup_t(ATTR_CMN_DEVID) | attrgroup_t(ATTR_CMN_OBJTYPE)
        | attrgroup_t(ATTR_CMN_MODTIME) | attrgroup_t(ATTR_CMN_FILEID)
    private static let directoryAttributes = attrgroup_t(ATTR_DIR_MOUNTSTATUS) | attrgroup_t(ATTR_DIR_ALLOCSIZE)
    private static let fileAttributes = attrgroup_t(ATTR_FILE_LINKCOUNT) | attrgroup_t(ATTR_FILE_ALLOCSIZE)
    private static let directoryType = UInt32(VDIR.rawValue)
    private static let regularType = UInt32(VREG.rawValue)

    /// Bulk reading: one system call returns the names and attributes of many
    /// entries, instead of one fstatat per file. Returns nil if the file system
    /// does not support getattrlistbulk (readdir is used instead).
    /// Record format: getattrlist(2) and getattrlistbulk(2).
    private func readBulk(_ node: FileNode, path: String, fd: Int32,
                          buffer: UnsafeMutableRawPointer) -> [(FileNode, String)]? {
        var request = attrlist()
        request.bitmapcount = u_short(ATTR_BIT_MAP_COUNT)
        request.commonattr = Scanner.commonAttributes
        request.dirattr = Scanner.directoryAttributes
        request.fileattr = Scanner.fileAttributes

        let prefix = path == "/" ? "/" : path + "/"
        var subdirectories: [(FileNode, String)] = []
        var files = 0
        var bytes: Int64 = 0
        var errors = 0
        var first = true

        while true {
            let count = getattrlistbulk(fd, &request, buffer, Scanner.bulkSize, 0)
            if count < 0 {
                if first && (errno == ENOTSUP || errno == EINVAL) { return nil }
                if first { node.unreadable = true }
                errors += 1
                break
            }
            first = false
            if count == 0 { break }

            var entry = buffer
            for _ in 0..<count {
                let length = Int(entry.load(as: UInt32.self))
                defer { entry += length }
                var field = entry + 4
                let returned = field.loadUnaligned(as: attribute_set_t.self)
                field += MemoryLayout<attribute_set_t>.size

                var failure: UInt32 = 0
                if returned.commonattr & attrgroup_t(ATTR_CMN_ERROR) != 0 {
                    failure = field.loadUnaligned(as: UInt32.self)
                    field += 4
                }
                let nameField = field
                let nameOffset = Int(field.loadUnaligned(as: Int32.self))
                field += MemoryLayout<attrreference_t>.size
                var device: Int32 = 0
                if returned.commonattr & attrgroup_t(ATTR_CMN_DEVID) != 0 {
                    device = field.loadUnaligned(as: Int32.self)
                    field += 4
                }
                var type: UInt32 = 0
                if returned.commonattr & attrgroup_t(ATTR_CMN_OBJTYPE) != 0 {
                    type = field.loadUnaligned(as: UInt32.self)
                    field += 4
                }
                var modified = 0
                if returned.commonattr & attrgroup_t(ATTR_CMN_MODTIME) != 0 {
                    modified = field.loadUnaligned(as: Int.self)   // tv_sec of the timespec
                    field += MemoryLayout<timespec>.size
                }
                var inode: UInt64 = 0
                if returned.commonattr & attrgroup_t(ATTR_CMN_FILEID) != 0 {
                    inode = field.loadUnaligned(as: UInt64.self)
                    field += 8
                }
                if failure != 0 {
                    errors += 1
                    continue
                }
                let name = String(cString: (nameField + nameOffset).assumingMemoryBound(to: CChar.self))

                if type == Scanner.directoryType {
                    var mountStatus: UInt32 = 0
                    if returned.dirattr & attrgroup_t(ATTR_DIR_MOUNTSTATUS) != 0 {
                        mountStatus = field.loadUnaligned(as: UInt32.self)
                        field += 4
                    }
                    var allocated: Int64 = 0
                    if returned.dirattr & attrgroup_t(ATTR_DIR_ALLOCSIZE) != 0 {
                        allocated = field.loadUnaligned(as: Int64.self)
                        field += 8
                    }
                    // Mount points and autofs triggers: another volume, stop here.
                    if mountStatus & UInt32(DIR_MNTSTATUS_MNTPOINT | DIR_MNTSTATUS_TRIGGER) != 0 { continue }
                    let childPath = prefix + name
                    if !excluded.isEmpty && excluded.contains(childPath) { continue }
                    let child = FileNode(name: name, kind: .directory, parent: node)
                    child.size = allocated
                    child.modified = modified
                    node.children.append(child)
                    subdirectories.append((child, childPath))
                    bytes += allocated
                } else {
                    var links: UInt32 = 1
                    if returned.fileattr & attrgroup_t(ATTR_FILE_LINKCOUNT) != 0 {
                        links = field.loadUnaligned(as: UInt32.self)
                        field += 4
                    }
                    var size: Int64 = 0
                    if returned.fileattr & attrgroup_t(ATTR_FILE_ALLOCSIZE) != 0 {
                        size = field.loadUnaligned(as: Int64.self)
                        field += 8
                    }
                    if links > 1 && type == Scanner.regularType {
                        linkLock.lock()
                        let firstLink = seenLinks.insert(LinkKey(device: device, inode: inode)).inserted
                        linkLock.unlock()
                        if !firstLink { size = 0 }
                    }
                    let child = FileNode(name: name, kind: .file, parent: node)
                    child.size = size
                    child.modified = modified
                    node.children.append(child)
                    files += 1
                    bytes += size
                }
            }
        }

        progress.add(files: files, dirs: 1, bytes: bytes, errors: errors)
        return subdirectories
    }

    /// Entry-by-entry reading, for file systems without getattrlistbulk.
    private func readEntries(_ node: FileNode, path: String, fd: Int32) -> [(FileNode, String)] {
        guard let directory = fdopendir(fd) else {
            close(fd)
            node.unreadable = true
            progress.add(files: 0, dirs: 1, bytes: 0, errors: 1)
            return []
        }
        defer { closedir(directory) }

        let directoryFD = dirfd(directory)
        let prefix = path == "/" ? "/" : path + "/"
        var subdirectories: [(FileNode, String)] = []
        var files = 0
        var bytes: Int64 = 0
        var errors = 0
        var info = stat()

        while let entry = readdir(directory) {
            let length = Int(entry.pointee.d_namlen)
            let name = UnsafeRawPointer(entry).advanced(by: Scanner.nameOffset)
                .assumingMemoryBound(to: CChar.self)
            if name[0] == 46 && (length == 1 || (length == 2 && name[1] == 46)) { continue }

            guard fstatat(directoryFD, name, &info, AT_SYMLINK_NOFOLLOW) == 0 else {
                errors += 1
                continue
            }
            let childName = String(cString: name)
            let type = info.st_mode & S_IFMT

            if type == S_IFDIR {
                guard devices.contains(info.st_dev) else { continue }
                let childPath = prefix + childName
                if !excluded.isEmpty && excluded.contains(childPath) { continue }
                let child = FileNode(name: childName, kind: .directory, parent: node)
                child.size = Int64(info.st_blocks) * 512
                child.modified = Int(info.st_mtimespec.tv_sec)
                node.children.append(child)
                subdirectories.append((child, childPath))
                bytes += child.size
            } else {
                var size = Int64(info.st_blocks) * 512
                // Hard links: the space is counted only once.
                if info.st_nlink > 1 && type == S_IFREG {
                    linkLock.lock()
                    let first = seenLinks.insert(LinkKey(device: info.st_dev, inode: info.st_ino)).inserted
                    linkLock.unlock()
                    if !first { size = 0 }
                }
                let child = FileNode(name: childName, kind: .file, parent: node)
                child.size = size
                child.modified = Int(info.st_mtimespec.tv_sec)
                node.children.append(child)
                files += 1
                bytes += size
            }
        }

        progress.add(files: files, dirs: 1, bytes: bytes, errors: errors)
        return subdirectories
    }

    /// Sums sizes, counts and dates bottom-up, then sorts by size.
    static func aggregate(_ node: FileNode) {
        var size = node.size
        var files = 0
        var subdirs = 0
        var errors = node.unreadable ? 1 : 0
        var modified = node.modified
        for child in node.children {
            if child.kind == .directory {
                aggregate(child)
                files += child.files
                subdirs += child.subdirs + 1
                errors += child.errors
            } else {
                files += 1
            }
            size += child.size
            modified = max(modified, child.modified)
        }
        node.size = size
        node.files = files
        node.subdirs = subdirs
        node.errors = errors
        node.modified = modified
        node.sortChildren()
    }

    /// Runs the scan on a thread with a large stack (aggregation is recursive).
    static func runDetached(_ body: @escaping () -> Void) {
        let thread = Thread(block: body)
        thread.stackSize = 64 << 20
        thread.qualityOfService = .userInitiated
        thread.start()
    }
}
