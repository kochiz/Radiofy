#!/usr/bin/env swift
import AppKit
import Foundation

// Logo oficial: 6 barras GORDAS + guatita + play redondo

let size = 1024
let img = NSImage(size: NSSize(width: size, height: size))
img.lockFocus()

NSColor(calibratedRed: 0.972, green: 0.961, blue: 0.949, alpha: 1).setFill()
NSBezierPath(rect: NSRect(x: 0, y: 0, width: size, height: size)).fill()

func hex(_ s: String) -> NSColor {
    var h: UInt64 = 0
    Scanner(string: String(s.dropFirst())).scanHexInt64(&h)
    return NSColor(calibratedRed: CGFloat((h >> 16) & 0xff)/255,
                   green: CGFloat((h >> 8) & 0xff)/255,
                   blue: CGFloat(h & 0xff)/255, alpha: 1)
}
func lerp(_ a: CGFloat, _ b: CGFloat, _ t: CGFloat) -> CGFloat { a + (b - a) * t }
let stops: [(CGFloat, NSColor)] = [
    (0, hex("#5B2BFF")), (0.16, hex("#C12BFF")), (0.56, hex("#FF2D7A")),
    (0.89, hex("#FF7A18")), (1, hex("#FFD000"))
]
func colorAt(_ t: CGFloat) -> NSColor {
    let u = min(1, max(0, t))
    for i in 0..<(stops.count - 1) {
        let a = stops[i], b = stops[i + 1]
        if u >= a.0 && u <= b.0 {
            let k = (u - a.0) / max(0.0001, b.0 - a.0)
            var ar: CGFloat=0, ag: CGFloat=0, ab: CGFloat=0, aa: CGFloat=0
            var br: CGFloat=0, bg: CGFloat=0, bb: CGFloat=0, ba: CGFloat=0
            a.1.getRed(&ar, green: &ag, blue: &ab, alpha: &aa)
            b.1.getRed(&br, green: &bg, blue: &bb, alpha: &ba)
            return NSColor(calibratedRed: lerp(ar, br, k), green: lerp(ag, bg, k), blue: lerp(ab, bb, k), alpha: 1)
        }
    }
    return stops.last!.1
}

let barCount = 6
let barW: CGFloat = 78
let gap: CGFloat = 26
let heights: [CGFloat] = [220, 400, 560, 560, 400, 220]
let totalW = CGFloat(barCount) * barW + CGFloat(barCount - 1) * gap
let x0 = (CGFloat(size) - totalW) / 2
let midY = CGFloat(size) * 0.50
let hMax = heights.max()!

for i in 0..<(barCount - 1) {
    let overlap = min(heights[i], heights[i + 1])
    let cx = x0 + CGFloat(i + 1) * (barW + gap) - gap / 2
    let rx: CGFloat = 48 * (0.85 + 0.25 * (overlap / hMax))
    let ry: CGFloat = 58 * (0.85 + 0.35 * (overlap / hMax))
    colorAt((cx - x0) / totalW).setFill()
    NSBezierPath(ovalIn: NSRect(x: cx - rx, y: midY - ry, width: rx * 2, height: ry * 2)).fill()
}

for i in 0..<barCount {
    let h = heights[i]
    let x = x0 + CGFloat(i) * (barW + gap)
    let y = midY - h / 2
    colorAt((x + barW / 2 - x0) / totalW).setFill()
    NSBezierPath(roundedRect: NSRect(x: x, y: y, width: barW, height: h),
                 xRadius: barW / 2, yRadius: barW / 2).fill()
}

func roundedTriangle(points: [NSPoint], radius: CGFloat) -> NSBezierPath {
    let path = NSBezierPath()
    let n = points.count
    for i in 0..<n {
        let prev = points[(i + n - 1) % n]
        let cur = points[i]
        let next = points[(i + 1) % n]
        var v1 = NSPoint(x: prev.x - cur.x, y: prev.y - cur.y)
        var v2 = NSPoint(x: next.x - cur.x, y: next.y - cur.y)
        let L1 = max(0.001, hypot(v1.x, v1.y))
        let L2 = max(0.001, hypot(v2.x, v2.y))
        let r1 = min(radius, L1 * 0.42)
        let r2 = min(radius, L2 * 0.42)
        v1.x /= L1; v1.y /= L1; v2.x /= L2; v2.y /= L2
        let p0 = NSPoint(x: cur.x + v1.x * r1, y: cur.y + v1.y * r1)
        let p1 = NSPoint(x: cur.x + v2.x * r2, y: cur.y + v2.y * r2)
        if i == 0 { path.move(to: p0) } else { path.line(to: p0) }
        path.curve(to: p1, controlPoint1: cur, controlPoint2: cur)
    }
    path.close()
    return path
}

let cx = CGFloat(size) / 2
let cy = midY
NSColor.white.setFill()
roundedTriangle(points: [
    NSPoint(x: cx - 90, y: cy - 118),
    NSPoint(x: cx - 90, y: cy + 118),
    NSPoint(x: cx + 128, y: cy)
], radius: 42).fill()

img.unlockFocus()

let root = URL(fileURLWithPath: CommandLine.arguments.count > 1
    ? CommandLine.arguments[1] : FileManager.default.currentDirectoryPath)
let master = root.appendingPathComponent("icon-master.png")
let tiff = img.tiffRepresentation!
let rep = NSBitmapImageRep(data: tiff)!
try! rep.representation(using: .png, properties: [:])!.write(to: master)

let iconset = root.appendingPathComponent("AppIcon.iconset")
try? FileManager.default.removeItem(at: iconset)
try! FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)
let named: [(String, Int)] = [
    ("icon_16x16.png", 16), ("icon_16x16@2x.png", 32),
    ("icon_32x32.png", 32), ("icon_32x32@2x.png", 64),
    ("icon_128x128.png", 128), ("icon_128x128@2x.png", 256),
    ("icon_256x256.png", 256), ("icon_256x256@2x.png", 512),
    ("icon_512x512.png", 512), ("icon_512x512@2x.png", 1024),
]
for (name, px) in named {
    let scaled = NSImage(size: NSSize(width: px, height: px))
    scaled.lockFocus()
    img.draw(in: NSRect(x: 0, y: 0, width: px, height: px),
             from: NSRect(x: 0, y: 0, width: size, height: size),
             operation: .copy, fraction: 1)
    scaled.unlockFocus()
    let t = scaled.tiffRepresentation!
    let r = NSBitmapImageRep(data: t)!
    try! r.representation(using: .png, properties: [:])!.write(to: iconset.appendingPathComponent(name))
}
let icns = root.appendingPathComponent("AppIcon.icns")
let task = Process()
task.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
task.arguments = ["-c", "icns", iconset.path, "-o", icns.path]
try! task.run(); task.waitUntilExit()
print("ok \(task.terminationStatus) \(icns.path)")
try? FileManager.default.removeItem(at: iconset)
