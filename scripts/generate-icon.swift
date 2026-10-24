// Rebuild: swift scripts/generate-icon.swift build/AppIcon.iconset
//         iconutil -c icns build/AppIcon.iconset -o Resources/AppIcon.icns
import AppKit
import Foundation

let destination = URL(fileURLWithPath: CommandLine.arguments.dropFirst().first ?? "build/AppIcon.iconset")
try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
for size in [16, 32, 128, 256, 512] {
    for scale in [1, 2] {
        let pixels = size * scale
        guard let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels,
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0),
            let context = NSGraphicsContext(bitmapImageRep: bitmap) else { fatalError("Cannot create icon bitmap") }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = context
        let transform = AffineTransform(scale: CGFloat(pixels) / 1024)
        (transform as NSAffineTransform).concat()
        let tile = NSBezierPath(roundedRect: NSRect(x: 64, y: 64, width: 896, height: 896), xRadius: 204, yRadius: 204)
        NSGradient(starting: NSColor(calibratedRed: 0.09, green: 0.19, blue: 0.32, alpha: 1),
                   ending: NSColor(calibratedRed: 0.03, green: 0.08, blue: 0.16, alpha: 1))?.draw(in: tile, angle: -90)
        let arc = NSBezierPath()
        arc.appendArc(withCenter: NSPoint(x: 512, y: 510), radius: 292, startAngle: -40, endAngle: 220)
        arc.lineWidth = 62
        arc.lineCapStyle = .round
        NSColor(calibratedWhite: 1, alpha: 0.15).setStroke()
        arc.stroke()
        let quota = NSBezierPath()
        quota.appendArc(withCenter: NSPoint(x: 512, y: 510), radius: 292, startAngle: 44, endAngle: 220)
        quota.lineWidth = 62
        quota.lineCapStyle = .round
        NSColor(calibratedRed: 0.24, green: 0.88, blue: 0.72, alpha: 1).setStroke()
        quota.stroke()
        let pulse = NSBezierPath()
        pulse.move(to: NSPoint(x: 280, y: 450))
        for point in [NSPoint(x: 405, y: 450), NSPoint(x: 462, y: 585), NSPoint(x: 544, y: 340),
                      NSPoint(x: 608, y: 450), NSPoint(x: 744, y: 450)] { pulse.line(to: point) }
        pulse.lineWidth = 38
        pulse.lineJoinStyle = .round
        pulse.lineCapStyle = .round
        NSColor.white.setStroke()
        pulse.stroke()
        NSGraphicsContext.restoreGraphicsState()
        guard let png = bitmap.representation(using: .png, properties: [:]) else { fatalError("Cannot encode icon") }
        let suffix = scale == 2 ? "@2x" : ""
        try png.write(to: destination.appendingPathComponent("icon_\(size)x\(size)\(suffix).png"))
    }
}
