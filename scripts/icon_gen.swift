// Flat icon family shared by KimiUsage, GlmUsage and CodexUsage.
// Run from the project root: swift scripts/icon_gen.swift
import AppKit

enum Brand {
    case kimi, glm, codex

    static var current: Brand {
        let directory = FileManager.default.currentDirectoryPath.lowercased()
        if directory.contains("kimi") { return .kimi }
        if directory.contains("glm") { return .glm }
        return .codex
    }

    var background: NSColor {
        switch self {
        case .kimi: return NSColor(red: 0.055, green: 0.105, blue: 0.235, alpha: 1)
        case .glm: return NSColor(red: 0.055, green: 0.205, blue: 0.180, alpha: 1)
        case .codex: return NSColor(red: 0.105, green: 0.110, blue: 0.120, alpha: 1)
        }
    }

    var accent: NSColor {
        switch self {
        case .kimi: return NSColor(red: 0.285, green: 0.545, blue: 1.000, alpha: 1)
        case .glm: return NSColor(red: 0.415, green: 0.875, blue: 0.655, alpha: 1)
        case .codex: return NSColor(red: 1.000, green: 0.625, blue: 0.390, alpha: 1)
        }
    }
}

func line(_ points: [NSPoint], width: CGFloat, color: NSColor) {
    let path = NSBezierPath()
    path.lineWidth = width
    path.lineCapStyle = .round
    path.lineJoinStyle = .round
    path.move(to: points[0])
    for point in points.dropFirst() { path.line(to: point) }
    color.setStroke()
    path.stroke()
}

let brand = Brand.current
let canvas: CGFloat = 1024
let white = NSColor(calibratedWhite: 1, alpha: 1)
let image = NSImage(size: NSSize(width: canvas, height: canvas))
image.lockFocus()

let tile = NSBezierPath(roundedRect: NSRect(x: 64, y: 64, width: 896, height: 896),
                        xRadius: 196, yRadius: 196)
brand.background.setFill()
tile.fill()

switch brand {
case .kimi:
    // A moon silhouette is a simple visual cue for Kimi's name.
    let moon = NSBezierPath(ovalIn: NSRect(x: 322, y: 385, width: 382, height: 382))
    white.setFill()
    moon.fill()
    let cutout = NSBezierPath(ovalIn: NSRect(x: 421, y: 481, width: 348, height: 348))
    brand.background.setFill()
    cutout.fill()
    let star = NSBezierPath(ovalIn: NSRect(x: 647, y: 683, width: 48, height: 48))
    brand.accent.setFill()
    star.fill()

case .glm:
    // The G is also a circular quota dial.
    let dial = NSBezierPath()
    dial.lineWidth = 72
    dial.lineCapStyle = .round
    dial.appendArc(withCenter: NSPoint(x: 512, y: 575), radius: 165,
                   startAngle: 42, endAngle: 318, clockwise: false)
    white.setStroke()
    dial.stroke()
    line([NSPoint(x: 635, y: 465), NSPoint(x: 675, y: 505),
          NSPoint(x: 675, y: 553), NSPoint(x: 534, y: 553)],
         width: 72, color: white)

case .codex:
    // Code brackets form a compact terminal mark.
    line([NSPoint(x: 439, y: 733), NSPoint(x: 319, y: 574), NSPoint(x: 439, y: 415)],
         width: 74, color: white)
    line([NSPoint(x: 585, y: 733), NSPoint(x: 705, y: 574), NSPoint(x: 585, y: 415)],
         width: 74, color: white)
}

// Shared meter track identifies all three as usage monitors.
line([NSPoint(x: 338, y: 288), NSPoint(x: 686, y: 288)], width: 30,
     color: NSColor(calibratedWhite: 1, alpha: 0.23))
line([NSPoint(x: 338, y: 288), NSPoint(x: 572, y: 288)], width: 30,
     color: brand.accent)
image.unlockFocus()

let files = FileManager.default
let iconset = URL(fileURLWithPath: "AppIcon.iconset", isDirectory: true)
try? files.removeItem(at: iconset)
try files.createDirectory(at: iconset, withIntermediateDirectories: true)

func png(_ size: Int) -> Data {
    let output = NSImage(size: NSSize(width: size, height: size))
    output.lockFocus()
    NSGraphicsContext.current?.imageInterpolation = .high
    image.draw(in: NSRect(x: 0, y: 0, width: size, height: size),
               from: NSRect(x: 0, y: 0, width: canvas, height: canvas),
               operation: .copy, fraction: 1)
    output.unlockFocus()
    guard let tiff = output.tiffRepresentation,
          let bitmap = NSBitmapImageRep(data: tiff),
          let data = bitmap.representation(using: .png, properties: [:]) else {
        fatalError("Could not render PNG at \(size) px")
    }
    return data
}

for (pointSize, retina) in [(16, false), (16, true), (32, false), (32, true),
                            (128, false), (128, true), (256, false), (256, true),
                            (512, false), (512, true)] {
    let pixels = retina ? pointSize * 2 : pointSize
    let suffix = retina ? "@2x" : ""
    let name = "icon_\(pointSize)x\(pointSize)\(suffix).png"
    try png(pixels).write(to: iconset.appendingPathComponent(name))
}
try png(1024).write(to: URL(fileURLWithPath: "icon_1024x1024.png"))

let iconutil = Process()
iconutil.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
iconutil.arguments = ["-c", "icns", "AppIcon.iconset"]
try iconutil.run()
iconutil.waitUntilExit()
guard iconutil.terminationStatus == 0 else { fatalError("iconutil failed") }
print("Generated AppIcon.icns for \(brand)")
