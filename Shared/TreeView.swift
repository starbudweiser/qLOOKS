// qLOOKS — liste en arbre d'un dossier ou d'une archive : nom avec icône, taille ; résumé en tête.
import AppKit
import UniformTypeIdentifiers

@MainActor
final class TreeView: NSView, NSOutlineViewDataSource, NSOutlineViewDelegate {
    private let roots: [TreeNode]
    private let outline = NSOutlineView()
    private let scroll = NSScrollView()
    private let summary = NSTextField(labelWithString: "")
    private var icons: [String: NSImage] = [:]

    init(listing: Listing, title: String) {
        roots = listing.roots
        super.init(frame: NSRect(x: 0, y: 0, width: 640, height: 520))
        appearance = NSAppearance(named: .darkAqua)
        wantsLayer = true
        layer?.backgroundColor = Backdrops.surround

        let fmt = ByteCountFormatter(); fmt.countStyle = .file
        var parts = [L.t("tree.files", listing.fileCount)]
        if listing.dirCount > 0 { parts.append(L.t("tree.dirs", listing.dirCount)) }
        if listing.totalSize > 0 { parts.append(fmt.string(fromByteCount: listing.totalSize)) }
        if listing.partial { parts.append(L.t("tree.partial")) }
        summary.stringValue = title + "  ·  " + parts.joined(separator: " · ")
        summary.font = .systemFont(ofSize: 12, weight: .medium)
        summary.textColor = NSColor(srgbRed: 0.667, green: 0.667, blue: 0.667, alpha: 1)
        summary.lineBreakMode = .byTruncatingMiddle
        summary.translatesAutoresizingMaskIntoConstraints = false

        let nameCol = NSTableColumn(identifier: .init("name")); nameCol.title = L.t("tree.name"); nameCol.minWidth = 160
        let sizeCol = NSTableColumn(identifier: .init("size")); sizeCol.title = L.t("tree.size"); sizeCol.width = 90; sizeCol.maxWidth = 120
        outline.addTableColumn(nameCol); outline.addTableColumn(sizeCol)
        outline.outlineTableColumn = nameCol
        outline.headerView = NSTableHeaderView()
        outline.rowHeight = 22
        outline.usesAlternatingRowBackgroundColors = false
        outline.backgroundColor = .clear
        outline.indentationPerLevel = 16
        outline.columnAutoresizingStyle = .firstColumnOnlyAutoresizingStyle
        outline.dataSource = self; outline.delegate = self

        scroll.documentView = outline
        scroll.hasVerticalScroller = true
        scroll.drawsBackground = false
        scroll.translatesAutoresizingMaskIntoConstraints = false
        addSubview(summary); addSubview(scroll)
        NSLayoutConstraint.activate([
            summary.topAnchor.constraint(equalTo: topAnchor, constant: 10),
            summary.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 14),
            summary.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -14),
            scroll.topAnchor.constraint(equalTo: summary.bottomAnchor, constant: 8),
            scroll.leadingAnchor.constraint(equalTo: leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: trailingAnchor),
            scroll.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
        outline.reloadData()
        if roots.count <= 12 { for r in roots where r.isDir { outline.expandItem(r) } }
    }

    required init?(coder: NSCoder) { fatalError() }

    // MARK: Données

    func outlineView(_ o: NSOutlineView, numberOfChildrenOfItem item: Any?) -> Int {
        (item as? TreeNode)?.kids.count ?? roots.count
    }
    func outlineView(_ o: NSOutlineView, child index: Int, ofItem item: Any?) -> Any {
        ((item as? TreeNode)?.kids ?? roots)[index]
    }
    func outlineView(_ o: NSOutlineView, isItemExpandable item: Any) -> Bool { (item as? TreeNode)?.hasKids ?? false }

    func outlineView(_ o: NSOutlineView, viewFor col: NSTableColumn?, item: Any) -> NSView? {
        guard let n = item as? TreeNode else { return nil }
        let id = NSUserInterfaceItemIdentifier(col?.identifier.rawValue ?? "name")
        let cell = (o.makeView(withIdentifier: id, owner: self) as? NSTableCellView) ?? makeCell(id)
        if id.rawValue == "size" {
            cell.textField?.stringValue = n.isDir && n.size == 0 ? "" : ByteCountFormatter.string(fromByteCount: n.size, countStyle: .file)
        } else {
            cell.textField?.stringValue = n.name
            cell.imageView?.image = icon(for: n)
        }
        return cell
    }

    private func makeCell(_ id: NSUserInterfaceItemIdentifier) -> NSTableCellView {
        let c = NSTableCellView(); c.identifier = id
        let t = NSTextField(labelWithString: "")
        t.font = id.rawValue == "size" ? .monospacedDigitSystemFont(ofSize: 12, weight: .regular) : .systemFont(ofSize: 13)
        t.lineBreakMode = .byTruncatingMiddle
        t.alignment = id.rawValue == "size" ? .right : .left
        t.translatesAutoresizingMaskIntoConstraints = false
        c.addSubview(t); c.textField = t
        if id.rawValue == "size" {
            NSLayoutConstraint.activate([t.leadingAnchor.constraint(equalTo: c.leadingAnchor, constant: 2), t.trailingAnchor.constraint(equalTo: c.trailingAnchor, constant: -8), t.centerYAnchor.constraint(equalTo: c.centerYAnchor)])
            t.textColor = NSColor(srgbRed: 0.667, green: 0.667, blue: 0.667, alpha: 1)
        } else {
            let i = NSImageView(); i.translatesAutoresizingMaskIntoConstraints = false
            c.addSubview(i); c.imageView = i
            NSLayoutConstraint.activate([
                i.leadingAnchor.constraint(equalTo: c.leadingAnchor, constant: 2), i.centerYAnchor.constraint(equalTo: c.centerYAnchor),
                i.widthAnchor.constraint(equalToConstant: 16), i.heightAnchor.constraint(equalToConstant: 16),
                t.leadingAnchor.constraint(equalTo: i.trailingAnchor, constant: 6), t.trailingAnchor.constraint(equalTo: c.trailingAnchor, constant: -4),
                t.centerYAnchor.constraint(equalTo: c.centerYAnchor),
            ])
        }
        return c
    }

    private func icon(for n: TreeNode) -> NSImage {
        let ext = n.isDir ? "/" : (n.name as NSString).pathExtension.lowercased()
        if let i = icons[ext] { return i }
        let type: UTType = n.isDir ? .folder : (UTType(filenameExtension: ext) ?? .data)
        let i = NSWorkspace.shared.icon(for: type)
        i.size = NSSize(width: 16, height: 16)
        icons[ext] = i
        return i
    }
}
