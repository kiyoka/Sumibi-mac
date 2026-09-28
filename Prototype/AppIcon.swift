import AppKit

// iOS版のアイコン(橙地に黒の線画)から線画を取り出し、iOS版より少し濃い橙の地に描いたmacOS用のアイコンを作る。
// 形はmacOSのアプリアイコンの格子(1024pxの中に824pxの角丸の正方形)に合わせる。
// 生成した画像はSumibi-mac側で管理し、iOS版の元画像は変更しない。
// 使い方: swift Prototype/AppIcon.swift <iOS版AppIcon.png> <地の色 RRGGBB> <出力PNG>

guard CommandLine.arguments.count == 4,
      let source = NSImage(contentsOfFile: CommandLine.arguments[1]),
      let cgSource = source.cgImage(forProposedRect: nil, context: nil, hints: nil),
      let hex = UInt32(CommandLine.arguments[2], radix: 16) else {
    fatalError("expected the iOS AppIcon.png path, a background color (RRGGBB) and an output path")
}

let width = cgSource.width
let height = cgSource.height
var pixels = [UInt8](repeating: 0, count: width * height * 4)
let rgb = CGColorSpaceCreateDeviceRGB()
pixels.withUnsafeMutableBytes { buffer in
    let context = CGContext(data: buffer.baseAddress, width: width, height: height, bitsPerComponent: 8,
                            bytesPerRow: width * 4, space: rgb,
                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    context.draw(cgSource, in: CGRect(x: 0, y: 0, width: width, height: height))
}

// 地の橙の明るさを基準に、暗いほど不透明な黒の線画にする。線の縁の中間色も滑らかに残る。
func luminance(_ i: Int) -> Double {
    0.299 * Double(pixels[i]) + 0.587 * Double(pixels[i + 1]) + 0.114 * Double(pixels[i + 2])
}
let background = luminance(0)
var mask = [UInt8](repeating: 0, count: width * height * 4)
for i in stride(from: 0, to: mask.count, by: 4) {
    let alpha = max(0, min(1, (background - luminance(i)) / background))
    mask[i + 3] = UInt8((alpha * 255).rounded())
}
let lineArt = mask.withUnsafeMutableBytes { buffer -> CGImage in
    CGContext(data: buffer.baseAddress, width: width, height: height, bitsPerComponent: 8,
              bytesPerRow: width * 4, space: rgb,
              bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!.makeImage()!
}

let side = 1024.0
let body = CGRect(x: 100, y: 100, width: 824, height: 824)
let context = CGContext(data: nil, width: Int(side), height: Int(side), bitsPerComponent: 8, bytesPerRow: 0,
                        space: rgb, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
context.interpolationQuality = .high
let shape = CGPath(roundedRect: body, cornerWidth: 185, cornerHeight: 185, transform: nil)
// macOSのアイコンと同じく、下へ淡い影を落とす。
context.saveGState()
context.setShadow(offset: CGSize(width: 0, height: -10), blur: 20, color: NSColor.black.withAlphaComponent(0.3).cgColor)
context.setFillColor(red: Double((hex >> 16) & 0xFF) / 255, green: Double((hex >> 8) & 0xFF) / 255,
                     blue: Double(hex & 0xFF) / 255, alpha: 1)
context.addPath(shape)
context.fillPath()
context.restoreGState()
// iOS版の正方形全体を角丸の正方形に収める。線画の大きさと位置の比率はiOS版のまま。
context.addPath(shape)
context.clip()
context.draw(lineArt, in: body)

let rep = NSBitmapImageRep(cgImage: context.makeImage()!)
try rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: CommandLine.arguments[3]))
