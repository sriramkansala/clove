// Renders a placeholder 1024×1024 app icon: a dark gradient squircle with a black
// "island" pill and a warm clove-coloured activity dot.
//   swift scripts/make_icon.swift <out.png>
import AppKit

let size: CGFloat = 1024
let out = CommandLine.arguments.dropFirst().first ?? "icon_1024.png"
let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(size), pixelsHigh: Int(size),
                           bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                           colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)

// macOS icon grid: 824pt body centred in the 1024 canvas.
let body = NSRect(x: 100, y: 100, width: 824, height: 824)
let squircle = NSBezierPath(roundedRect: body, xRadius: 185, yRadius: 185)
NSGradient(colors: [NSColor(srgbRed: 0.24, green: 0.15, blue: 0.33, alpha: 1),
                    NSColor(srgbRed: 0.06, green: 0.05, blue: 0.09, alpha: 1)])!
    .draw(in: squircle, angle: -90)

// Island pill near the top.
let pill = NSRect(x: 262, y: 590, width: 500, height: 150)
NSColor.black.setFill()
NSBezierPath(roundedRect: pill, xRadius: 75, yRadius: 75).fill()

// Activity dot inside the pill.
NSColor(srgbRed: 0.85, green: 0.47, blue: 0.20, alpha: 1).setFill()
NSBezierPath(ovalIn: NSRect(x: 652, y: 630, width: 70, height: 70)).fill()

// Soft highlight on the pill's left: a small "artwork" square.
NSColor(white: 1, alpha: 0.18).setFill()
NSBezierPath(roundedRect: NSRect(x: 305, y: 625, width: 80, height: 80), xRadius: 18, yRadius: 18).fill()

NSGraphicsContext.current = nil
try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: out))
print("wrote \(out)")
