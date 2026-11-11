// Рисует иконку приложения 1024x1024: оранжевый квадрат с пламенем и надписью T90.
import AppKit

let size = 1024
let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: size, pixelsHigh: size,
                           bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                           colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)

let rect = NSRect(x: 100, y: 100, width: 824, height: 824)
let bg = NSBezierPath(roundedRect: rect, xRadius: 185, yRadius: 185)
NSGradient(starting: NSColor(red: 0.16, green: 0.17, blue: 0.20, alpha: 1),
           ending: NSColor(red: 0.05, green: 0.05, blue: 0.07, alpha: 1))!.draw(in: bg, angle: -90)

if let sym = NSImage(systemSymbolName: "flame.fill", accessibilityDescription: nil)?
    .withSymbolConfiguration(.init(pointSize: 400, weight: .bold)
        .applying(.init(paletteColors: [NSColor.systemOrange]))) {
    let s = sym.size
    sym.draw(in: NSRect(x: (1024 - s.width) / 2, y: 400, width: s.width, height: s.height))
}

let text = "T90" as NSString
let attrs: [NSAttributedString.Key: Any] = [
    .font: NSFont.systemFont(ofSize: 190, weight: .heavy),
    .foregroundColor: NSColor.white,
]
let ts = text.size(withAttributes: attrs)
text.draw(at: NSPoint(x: (1024 - ts.width) / 2, y: 170), withAttributes: attrs)

NSGraphicsContext.restoreGraphicsState()
try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: CommandLine.arguments[1]))
