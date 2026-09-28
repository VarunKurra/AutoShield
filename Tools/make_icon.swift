import AppKit
import Foundation

// Takes the supplied artwork and re-masks it to a clean continuous-corner
// squircle. The saturation pass left a noisy fringe on the anti-aliased edge;
// clipping to a real path removes it without touching a pixel inside.

let src = CommandLine.arguments[1]
let out = CommandLine.arguments[2]
try? FileManager.default.createDirectory(atPath: out, withIntermediateDirectories: true)

guard let art = NSImage(contentsOfFile: src) else { fatalError("cannot read \(src)") }

// Report the colours in use, so the app palette can be matched to them.
if let tiff = art.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff) {
    for (label, fx, fy) in [("top-left", 0.24, 0.20), ("centre", 0.5, 0.5),
                            ("bottom-right", 0.78, 0.82), ("top-right", 0.76, 0.22)] {
        let x = Int(Double(rep.pixelsWide) * fx), y = Int(Double(rep.pixelsHigh) * fy)
        if let c = rep.colorAt(x: x, y: y)?.usingColorSpace(.sRGB) {
            print(String(format: "  %@: #%02X%02X%02X", label,
                         Int(c.redComponent * 255), Int(c.greenComponent * 255),
                         Int(c.blueComponent * 255)))
        }
    }
}

func render(_ px: Int) -> Data? {
    let s = CGFloat(px)
    let image = NSImage(size: NSSize(width: s, height: s))
    image.lockFocus()
    NSGraphicsContext.current?.imageInterpolation = .high

    // macOS icons sit inside their canvas.
    let inset = s * 0.10
    let rect = CGRect(x: inset, y: inset, width: s - inset * 2, height: s - inset * 2)
    let radius = rect.width * 0.2237

    NSGraphicsContext.saveGraphicsState()
    NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius).addClip()
    // The artwork is drawn slightly oversize so its ragged outer edge falls
    // outside the clip and the plate ends on a clean curve.
    let bleed = rect.insetBy(dx: -rect.width * 0.035, dy: -rect.height * 0.035)
    art.draw(in: bleed, from: .zero, operation: .sourceOver, fraction: 1)
    NSGraphicsContext.restoreGraphicsState()

    image.unlockFocus()
    guard let tiff = image.tiffRepresentation,
          let rep = NSBitmapImageRep(data: tiff) else { return nil }
    rep.size = NSSize(width: px, height: px)
    return rep.representation(using: .png, properties: [:])
}

let sizes: [(Int, String)] = [
    (16, "icon_16x16"), (32, "icon_16x16@2x"), (32, "icon_32x32"), (64, "icon_32x32@2x"),
    (128, "icon_128x128"), (256, "icon_128x128@2x"), (256, "icon_256x256"),
    (512, "icon_256x256@2x"), (512, "icon_512x512"), (1024, "icon_512x512@2x"),
]
for (px, name) in sizes {
    if let d = render(px) { try d.write(to: URL(fileURLWithPath: "\(out)/\(name).png")) }
}
print("rendered \(sizes.count) sizes")
