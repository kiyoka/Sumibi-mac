import AppKit

// iOS版のアイコン(橙地に黒の線画)から線画だけを取り出し、メニューバー用のテンプレート画像を作る。
// 生成した画像はSumibi-mac側で管理し、iOS版の元画像は変更しない。
// 使い方: swift Prototype/MenuBarIcon.swift <iOS版AppIcon.png> <出力先ディレクトリ>

guard CommandLine.arguments.count == 3,
      let source = NSImage(contentsOfFile: CommandLine.arguments[1]),
      let cgSource = source.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
    fatalError("expected the iOS AppIcon.png path and an output directory")
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

// 地の橙の明るさを基準に、暗いほど不透明にする。線の縁の中間色も滑らかに残る。
func luminance(_ i: Int) -> Double {
    0.299 * Double(pixels[i]) + 0.587 * Double(pixels[i + 1]) + 0.114 * Double(pixels[i + 2])
}
let background = luminance(0)
var mask = [UInt8](repeating: 0, count: width * height * 4)
var minX = width, minY = height, maxX = 0, maxY = 0
for y in 0..<height {
    for x in 0..<width {
        let i = (y * width + x) * 4
        let alpha = max(0, min(1, (background - luminance(i)) / background))
        mask[i + 3] = UInt8((alpha * 255).rounded())
        if alpha > 0.5 {
            minX = min(minX, x); maxX = max(maxX, x)
            minY = min(minY, y); maxY = max(maxY, y)
        }
    }
}

let maskImage = mask.withUnsafeMutableBytes { buffer -> CGImage in
    CGContext(data: buffer.baseAddress, width: width, height: height, bitsPerComponent: 8,
              bytesPerRow: width * 4, space: rgb,
              bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!.makeImage()!
}
let art = CGRect(x: minX, y: minY, width: maxX - minX + 1, height: maxY - minY + 1)
let cropped = maskImage.cropping(to: art)!

// メニューバーのアイコンは高さ18pt程度で使う。線画を縦いっぱいに収めた正方形に描く。
func write(points: Int, scale: Int, suffix: String) throws {
    let side = points * scale
    let context = CGContext(data: nil, width: side, height: side, bitsPerComponent: 8, bytesPerRow: 0,
                            space: rgb, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    context.interpolationQuality = .high
    let drawHeight = Double(side)
    let drawWidth = drawHeight * art.width / art.height
    context.draw(cropped, in: CGRect(x: (Double(side) - drawWidth) / 2, y: 0, width: drawWidth, height: drawHeight))
    let rep = NSBitmapImageRep(cgImage: context.makeImage()!)
    rep.size = NSSize(width: points, height: points)
    let url = URL(fileURLWithPath: CommandLine.arguments[2]).appendingPathComponent("MenuBarIcon\(suffix).png")
    try rep.representation(using: .png, properties: [:])!.write(to: url)
}
try write(points: 18, scale: 1, suffix: "")
try write(points: 18, scale: 2, suffix: "@2x")
