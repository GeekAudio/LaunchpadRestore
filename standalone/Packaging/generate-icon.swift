import AppKit

let size = 1024
let bitmap = NSBitmapImageRep(
    bitmapDataPlanes: nil,
    pixelsWide: size,
    pixelsHigh: size,
    bitsPerSample: 8,
    samplesPerPixel: 4,
    hasAlpha: true,
    isPlanar: false,
    colorSpaceName: .deviceRGB,
    bytesPerRow: 0,
    bitsPerPixel: 0
)!
let context = NSGraphicsContext(bitmapImageRep: bitmap)!
NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = context
defer { NSGraphicsContext.restoreGraphicsState() }

NSColor.clear.setFill()
NSRect(x: 0, y: 0, width: size, height: size).fill()

let background = NSBezierPath(
    roundedRect: NSRect(x: 52, y: 52, width: 920, height: 920),
    xRadius: 220,
    yRadius: 220
)
NSColor(calibratedRed: 0.09, green: 0.12, blue: 0.20, alpha: 1).setFill()
background.fill()

let colors: [NSColor] = [
    .init(calibratedRed: 0.98, green: 0.39, blue: 0.40, alpha: 1),
    .init(calibratedRed: 1.00, green: 0.72, blue: 0.28, alpha: 1),
    .init(calibratedRed: 0.30, green: 0.78, blue: 0.77, alpha: 1),
    .init(calibratedRed: 0.45, green: 0.58, blue: 1.00, alpha: 1),
    .init(calibratedRed: 0.70, green: 0.49, blue: 0.98, alpha: 1),
    .init(calibratedRed: 0.43, green: 0.82, blue: 0.52, alpha: 1),
    .init(calibratedRed: 0.99, green: 0.57, blue: 0.34, alpha: 1),
    .init(calibratedRed: 0.38, green: 0.66, blue: 0.94, alpha: 1),
    .init(calibratedRed: 0.92, green: 0.51, blue: 0.71, alpha: 1),
]
for row in 0..<3 {
    for column in 0..<3 {
        let rect = NSRect(
            x: 184 + column * 220,
            y: 184 + (2 - row) * 220,
            width: 184,
            height: 184
        )
        let tile = NSBezierPath(roundedRect: rect, xRadius: 43, yRadius: 43)
        colors[row * 3 + column].setFill()
        tile.fill()
    }
}
context.flushGraphics()
guard let data = bitmap.representation(using: .png, properties: [:]) else {
    fatalError("Could not render app icon")
}
try data.write(to: URL(fileURLWithPath: CommandLine.arguments[1]))
