import AppKit

guard CommandLine.arguments.count == 3 else { fatalError("expected TIFF and PNG output paths") }

func render(size: CGFloat) -> NSImage {
    NSImage(size: NSSize(width: size, height: size), flipped: false) { bounds in
        NSColor(calibratedRed: 0.22, green: 0.20, blue: 0.19, alpha: 1).setFill()
        NSBezierPath(roundedRect: bounds.insetBy(dx: size * 0.047, dy: size * 0.047),
                     xRadius: size * 0.203, yRadius: size * 0.203).fill()
        let text = NSAttributedString(
            string: "炭",
            attributes: [
                .font: NSFont.systemFont(ofSize: size * 0.594, weight: .semibold),
                .foregroundColor: NSColor.white
            ]
        )
        let textSize = text.size()
        text.draw(at: NSPoint(x: (bounds.width - textSize.width) / 2,
                              y: (bounds.height - textSize.height) / 2))
        return true
    }
}

guard let tiff = render(size: 64).tiffRepresentation,
      let source = render(size: 1024).tiffRepresentation,
      let png = NSBitmapImageRep(data: source)?.representation(using: .png, properties: [:]) else {
    fatalError("failed to create prototype icon")
}
try tiff.write(to: URL(fileURLWithPath: CommandLine.arguments[1]))
try png.write(to: URL(fileURLWithPath: CommandLine.arguments[2]))
