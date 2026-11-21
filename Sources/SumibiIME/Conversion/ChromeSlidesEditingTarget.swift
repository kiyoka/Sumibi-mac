import ApplicationServices
import Foundation

/// The focused browser field is shared by the canvas and speaker notes.
struct ChromeSlidesEditingTarget {
    let process: pid_t
    private let field: AXUIElement
    private let page: URL

    static let chromeBundleID = "com.google.Chrome"
    private static let accessibilityQueue = DispatchQueue(label: "org.sumibi.slides-accessibility", qos: .userInitiated)

    static func capture(process: pid_t, completion: @escaping (Self?) -> Void) {
        accessibilityQueue.async {
            let target = capture(process: process)
            DispatchQueue.main.async { completion(target) }
        }
    }

    func revalidate(completion: @escaping (Bool) -> Void) {
        Self.accessibilityQueue.async {
            let current = Self.capture(process: process)
            let matches = current.map { page == $0.page && CFEqual(field, $0.field) } ?? false
            DispatchQueue.main.async { completion(matches) }
        }
    }

    // Fixed codes only. The browser URL, labels, and document content stay out of logs.
    private enum Rejection: Int {
        case accessibilityDenied = 1, missingFocus = 3, unexpectedFocusRole
        case unexpectedFocusLabel, missingSlidesPage, deadlineExceeded
    }

    private static func reject(_ reason: Rejection, error: AXError? = nil) -> Self? {
        DiagnosticLog.record(.slidesDirectTargetRejected, counters: [reason.rawValue] + (error.map { [Int($0.rawValue)] } ?? []))
        return nil
    }

    private static func capture(process: pid_t) -> Self? {
        guard AXIsProcessTrusted() else { return reject(.accessibilityDenied) }
        let browser = AXUIElementCreateApplication(process)
        AXUIElementSetMessagingTimeout(browser, 0.12)
        var focused: CFTypeRef?
        let focusError = AXUIElementCopyAttributeValue(browser, kAXFocusedUIElementAttribute as CFString, &focused)
        guard focusError == .success, let focused, CFGetTypeID(focused) == AXUIElementGetTypeID() else {
            return reject(.missingFocus, error: focusError)
        }
        let field = focused as! AXUIElement
        guard role(field) == kAXTextAreaRole else { return reject(.unexpectedFocusRole) }
        guard labels(field).contains(where: ["Document content", "ドキュメントのコンテンツ"].contains) else {
            return reject(.unexpectedFocusLabel)
        }
        let deadline = ProcessInfo.processInfo.systemUptime + 0.25
        var current = field
        for _ in 0..<24 {
            guard ProcessInfo.processInfo.systemUptime < deadline else { return reject(.deadlineExceeded) }
            if role(current) == "AXWebArea", let url = value(current, kAXURLAttribute) as? URL,
               isSlidesEditPage(url) {
                return Self(process: process, field: field, page: url)
            }
            guard let parent = element(current, kAXParentAttribute), !CFEqual(parent, current) else { break }
            current = parent
        }
        return reject(.missingSlidesPage)
    }

    static func isSlidesEditPage(_ url: URL) -> Bool {
        guard url.scheme == "https", url.host == "docs.google.com", url.port == nil,
              url.user == nil, url.password == nil else { return false }
        let parts = url.path.split(separator: "/")
        return parts.count == 4 && parts[0] == "presentation" && parts[1] == "d" && parts[3] == "edit"
    }

    private static func role(_ element: AXUIElement) -> String? {
        value(element, kAXRoleAttribute) as? String
    }

    private static func labels(_ element: AXUIElement) -> [String] {
        [kAXTitleAttribute, kAXDescriptionAttribute].compactMap { value(element, $0) as? String }
    }

    private static func value(_ element: AXUIElement, _ name: String) -> CFTypeRef? {
        AXUIElementSetMessagingTimeout(element, 0.05)
        var result: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, name as CFString, &result) == .success else { return nil }
        return result
    }

    private static func element(_ parent: AXUIElement, _ name: String) -> AXUIElement? {
        guard let result = value(parent, name), CFGetTypeID(result) == AXUIElementGetTypeID() else { return nil }
        return (result as! AXUIElement)
    }
}
