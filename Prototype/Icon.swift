import AppKit

guard CommandLine.arguments.count == 2 else { fatalError("expected an output path") }

let size = NSSize(width: 64, height: 64)
let image = NSImage(size: size, flipped: false) { bounds in
    NSColor(calibratedRed: 0.22, green: 0.20, blue: 0.19, alpha: 1).setFill()
    NSBezierPath(roundedRect: bounds.insetBy(dx: 3, dy: 3), xRadius: 13, yRadius: 13).fill()
    let text = NSAttributedString(
        string: "炭",
        attributes: [
            .font: NSFont.systemFont(ofSize: 38, weight: .semibold),
            .foregroundColor: NSColor.white
        ]
    )
    let textSize = text.size()
    text.draw(at: NSPoint(x: (bounds.width - textSize.width) / 2,
                          y: (bounds.height - textSize.height) / 2))
    return true
}

guard let data = image.tiffRepresentation else { fatalError("failed to create prototype icon") }
try data.write(to: URL(fileURLWithPath: CommandLine.arguments[1]))
