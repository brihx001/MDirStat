import Foundation

/// Verrou de l'arbre : le rendu du treemap lit l'arbre sur un fil a part,
/// le fil principal le modifie (corbeille, rafraichissement). Les deux le prennent.
let treeLock = NSLock()

/// Un element de l'arbre analyse. Une classe, pour que NSOutlineView puisse
/// s'en servir comme item et que l'arbre se partage sans copie.
final class FileNode {
    enum Kind: UInt8 {
        case file, directory
        /// Pseudo-elements d'un volume : espace libre et espace non retrouve.
        case freeSpace, unknown
    }

    let name: String
    let kind: Kind
    weak var parent: FileNode?
    var children: [FileNode] = []
    /// Octets alloues sur le disque (st_blocks * 512) ; cumules pour un dossier.
    var size: Int64 = 0
    /// Fichiers et sous-dossiers du sous-arbre (0 pour un fichier).
    var files = 0
    var subdirs = 0
    /// time_t ; pour un dossier, le plus recent du sous-arbre.
    var modified = 0
    /// Indice dans ExtensionStats.entries (-1 pour un dossier).
    var extID: Int32 = -1
    /// Dossier illisible (droits, protection TCC).
    var unreadable = false
    /// Dossiers illisibles dans le sous-arbre.
    var errors = 0

    init(name: String, kind: Kind, parent: FileNode? = nil) {
        self.name = name
        self.kind = kind
        self.parent = parent
    }

    var isDirectory: Bool { kind == .directory }
    var isPseudo: Bool { kind == .freeSpace || kind == .unknown }
    var items: Int { files + subdirs }

    /// Chemin complet ; le nom de la racine est deja un chemin absolu.
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

    /// Ancetres, du parent jusqu'a la racine.
    var ancestors: [FileNode] {
        var result: [FileNode] = []
        var node = parent
        while let current = node {
            result.append(current)
            node = current.parent
        }
        return result
    }

    /// Les enfants restent tries par taille decroissante : le treemap en a besoin.
    func sortChildren() {
        children.sort { $0.size > $1.size }
    }
}

extension FileNode {
    /// Retire un enfant et repercute tailles et compteurs jusqu'a la racine.
    /// A appeler sous treeLock.
    func removeChild(_ child: FileNode) {
        guard let index = children.firstIndex(where: { $0 === child }) else { return }
        children.remove(at: index)
        let fileDelta = child.kind == .file ? 1 : child.files
        let dirDelta = child.kind == .directory ? child.subdirs + 1 : 0
        propagate(size: -child.size, files: -fileDelta, subdirs: -dirDelta, errors: -child.errors)
    }

    /// Remplace un enfant par une nouvelle analyse du meme dossier.
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
