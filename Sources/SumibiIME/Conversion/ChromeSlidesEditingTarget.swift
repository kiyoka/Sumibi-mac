import AppKit
import ApplicationServices

/// The focused browser field is shared by the canvas and speaker notes.
/// Only a recognized Slides edit page with an inactive notes editor is eligible.
struct ChromeSlidesEditingTarget {
    private let process: pid_t
    private let field: AXUIElement
    private let page: URL

    static let chromeBundleID = "com.google.Chrome"

    static func capture() -> Self? {
        guard AXIsProcessTrusted(), let app = NSWorkspace.shared.frontmostApplication,
              app.bundleIdentifier == chromeBundleID else { return nil }
        let browser = AXUIElementCreateApplication(app.processIdentifier)
        AXUIElementSetMessagingTimeout(browser, 0.05)
        guard let field = element(browser, kAXFocusedUIElementAttribute),
              role(field) == kAXTextAreaRole,
              labels(field).contains(where: ["Document content", "ドキュメントのコンテンツ"].contains) else { return nil }
        let deadline = ProcessInfo.processInfo.systemUptime + 0.25
        var current = field
        for _ in 0..<24 {
            guard ProcessInfo.processInfo.systemUptime < deadline else { return nil }
            if role(current) == "AXWebArea", let url = value(current, kAXURLAttribute) as? URL,
               isSlidesEditPage(url) {
                guard notesAreInactive(in: current, deadline: deadline) else { return nil }
                return Self(process: app.processIdentifier, field: field, page: url)
            }
            guard let parent = element(current, kAXParentAttribute), !CFEqual(parent, current) else { break }
            current = parent
        }
        return nil
    }

    func matchesCurrentFocus() -> Bool {
        guard let current = Self.capture() else { return false }
        return process == current.process && page == current.page && CFEqual(field, current.field)
    }

    static func isSlidesEditPage(_ url: URL) -> Bool {
        guard url.scheme == "https", url.host == "docs.google.com", url.port == nil,
              url.user == nil, url.password == nil else { return false }
        let parts = url.path.split(separator: "/")
        return parts.count == 4 && parts[0] == "presentation" && parts[1] == "d" && parts[3] == "edit"
    }

    private static func notesAreInactive(in page: AXUIElement, deadline: TimeInterval) -> Bool {
        let notesLabels = ["Speaker notes", "スピーカー ノート"]
        var queue: [(AXUIElement, Bool)] = [(page, false)]
        var index = 0
        var sawNotes = false
        while index < queue.count {
            guard ProcessInfo.processInfo.systemUptime < deadline else { return false }
            let (node, insideNotes) = queue[index]
            index += 1
            guard let nodeRole = role(node) else { return false }
            let isNotes = (nodeRole == kAXGroupRole || nodeRole == kAXTextAreaRole)
                && labels(node).contains(where: notesLabels.contains)
            sawNotes = sawNotes || isNotes
            if (insideNotes || isNotes) && nodeRole == kAXTextAreaRole { return false }
            var children: CFTypeRef?
            switch AXUIElementCopyAttributeValue(node, kAXChildrenAttribute as CFString, &children) {
            case .success:
                guard let elements = children as? [AXUIElement], elements.count <= 512 - queue.count else { return false }
                queue.append(contentsOf: elements.map { ($0, insideNotes || isNotes) })
            case .attributeUnsupported, .noValue:
                break
            default:
                return false
            }
        }
        return sawNotes
    }

    private static func role(_ element: AXUIElement) -> String? {
        value(element, kAXRoleAttribute) as? String
    }

    private static func labels(_ element: AXUIElement) -> [String] {
        [kAXTitleAttribute, kAXDescriptionAttribute].compactMap { value(element, $0) as? String }
    }

    private static func value(_ element: AXUIElement, _ name: String) -> CFTypeRef? {
        var result: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, name as CFString, &result) == .success else { return nil }
        return result
    }

    private static func element(_ parent: AXUIElement, _ name: String) -> AXUIElement? {
        guard let result = value(parent, name), CFGetTypeID(result) == AXUIElementGetTypeID() else { return nil }
        return (result as! AXUIElement)
    }
}
