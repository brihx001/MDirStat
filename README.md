# MDirStat

A native macOS disk usage analyzer in the spirit of WinDirStat, written in Swift
with AppKit.

- **Directory tree** sorted by size, with subtree percentage bars, item and file
  counts, and the most recent change in each subtree. Every column is sortable.
- **Extension list**: bytes, share and file count per extension. The twelve
  heaviest extensions get their own color in the treemap; select one to outline
  all of its files.
- **Cushion treemap** (squarified layout, van Wijk shading), rendered in the
  background at Retina resolution. Click a tile to select the file in the tree,
  hover to read its path in the status bar, zoom into any folder.
- **Actions**: open, reveal in Finder, copy path, refresh a single folder, move
  to Trash (with confirmation). The tree, extension list and treemap update in
  place.
- **Volumes**: the start sheet lists mounted volumes with their usage. When a
  volume root is analyzed, `<Unknown>` (used space the scan did not find:
  snapshots, unreadable folders, other APFS volumes) and optionally
  `<Free Space>` appear in the tree and the treemap.

## Scanning

- Sizes are **allocated** sizes (blocks on disk), like `du`; hard links are
  counted once.
- Directories are read in parallel with `getattrlistbulk` (one system call per
  batch of entries instead of one `stat` per file), with a `readdir` fallback.
  On the test Mac, `/Applications` (946,000 items) is scanned in about 4 seconds,
  and a whole 1 TB startup disk (3.6 million items) in about 20 seconds.
- The scan never crosses mount points. Scanning `/` covers the system and data
  volumes through their firmlinks, and skips `/System/Volumes`, `/.nofollow`,
  `/.resolve` and `/.vol` so nothing is counted twice.
- iCloud files that are not downloaded are not materialized by the scan.
- Folders protected by macOS privacy settings are reported as unreadable. Grant
  MDirStat Full Disk Access (the status bar button opens the right pane) to
  include them.

## Building

Requires macOS 14 or later and Swift 6.

```bash
./build.sh release
```

The script builds with Swift Package Manager, assembles `MDirStat.app` and
signs it ad hoc. The app is not sandboxed: a disk analyzer has to read the whole
disk.

To regenerate the icon:

```bash
swiftc -O Packaging/Icon/make-icon.swift -o /tmp/make-icon
/tmp/make-icon Packaging/Icon
iconutil -c icns Packaging/Icon/AppIcon.iconset -o Packaging/AppIcon.icns
```

## Command line

`MDirStat.app/Contents/MacOS/MDirStat <folder>` starts scanning that folder
right away. With `MDIRSTAT_SNAPSHOT=/path/image.png` set, the app writes an image
of its window once the treemap is displayed, then quits (used for automated
checks).

## License

MIT
