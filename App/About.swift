// qLOOKS — fenêtre « À propos » (modèle Socle : swift/AboutWindow.swift).
import AppKit

@MainActor
enum About {
    private static var window: NSWindow?

    private static let sideMargin: CGFloat = 28
    private static let textWidth: CGFloat = 300

    static func show() {
        if window == nil { window = makeWindow() }
        window?.center()
        window?.present()
    }

    private static func label(_ text: String, size: CGFloat = 12, bold: Bool = false, secondary: Bool = false) -> NSTextField {
        let field = NSTextField(wrappingLabelWithString: text)
        field.font = bold ? NSFont.boldSystemFont(ofSize: size) : NSFont.systemFont(ofSize: size)
        field.textColor = secondary ? .secondaryLabelColor : .labelColor
        field.alignment = .center
        field.preferredMaxLayoutWidth = textWidth
        field.isSelectable = false
        field.translatesAutoresizingMaskIntoConstraints = false
        field.widthAnchor.constraint(lessThanOrEqualToConstant: textWidth).isActive = true
        return field
    }

    /// Nom de l'appli avec son « m » dans la couleur du logo.
    private static func nameLabel() -> NSTextField {
        let f = label("qLOOKS", size: 17, bold: true)
        let s = NSMutableAttributedString(string: "qLOOKS", attributes: [.font: NSFont.boldSystemFont(ofSize: 17), .foregroundColor: NSColor.labelColor])
        s.addAttribute(.foregroundColor, value: NSColor(srgbRed: 0x8b / 255, green: 0x5c / 255, blue: 0xf6 / 255, alpha: 1), range: NSRange(location: 0, length: 1))
        f.attributedStringValue = s
        f.alignment = .center
        return f
    }

    private static func makeWindow() -> NSWindow {
        let info = Bundle.main.infoDictionary ?? [:]
        let version = info["CFBundleShortVersionString"] as? String ?? "?"
        let build = info["CFBundleVersion"] as? String ?? "?"

        let icon = NSImageView(image: NSApp.applicationIconImage)
        icon.imageScaling = .scaleProportionallyUpOrDown
        icon.translatesAutoresizingMaskIntoConstraints = false
        icon.widthAnchor.constraint(equalToConstant: 84).isActive = true
        icon.heightAnchor.constraint(equalToConstant: 84).isActive = true

        let views: [NSView] = [
            icon,
            nameLabel(),
            label(L.t("about.version", version, build), secondary: true),
            label(L.t("about.tagline")),
            label(L.t("about.authors"), bold: true),
            label(L.t("about.license")),
            label(L.t("about.disclaimer"), secondary: true),
            label(L.t("about.credit"), secondary: true),
        ]
        let stack = NSStackView(views: views)
        stack.orientation = .vertical
        stack.alignment = .centerX
        stack.spacing = 12
        stack.setCustomSpacing(6, after: views[1])
        stack.setCustomSpacing(18, after: views[2])
        stack.edgeInsets = NSEdgeInsets(top: 28, left: sideMargin, bottom: 28, right: sideMargin)
        stack.translatesAutoresizingMaskIntoConstraints = false
        stack.widthAnchor.constraint(equalToConstant: textWidth + 2 * sideMargin).isActive = true

        let window = NSWindow(contentRect: .zero, styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.title = L.t("about.menu")
        window.isReleasedWhenClosed = false
        let content = NSView()
        content.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: content.topAnchor),
            stack.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            stack.bottomAnchor.constraint(equalTo: content.bottomAnchor),
        ])
        window.contentView = content
        content.layoutSubtreeIfNeeded()
        content.layoutSubtreeIfNeeded()
        window.setContentSize(content.fittingSize)
        return window
    }
}
