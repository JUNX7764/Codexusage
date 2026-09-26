// 生成 AppIcon.icns：近黑圆角方块 + 白色 "C"（模板风格，避免渐变；与 GlmUsage/KimiUsage 家族同款）
// 用法: swift scripts/icon_gen.swift   （在仓库根目录执行）
import AppKit

let size: CGFloat = 1024
let img = NSImage(size: NSSize(width: size, height: size))
img.lockFocus()
let rect = NSRect(x: 0, y: 0, width: size, height: size)
// 背景圆角方块
let bg = NSBezierPath(roundedRect: rect.insetBy(dx: 64, dy: 64), xRadius: 190, yRadius: 190)
NSColor(calibratedRed: 0.09, green: 0.09, blue: 0.11, alpha: 1).setFill()   // 近黑（Codex 终端风）
bg.fill()
// 白色 "C"
let para = NSMutableParagraphStyle()
para.alignment = .center
let attrs: [NSAttributedString.Key: Any] = [
    .font: NSFont.systemFont(ofSize: 560, weight: .bold),
    .foregroundColor: NSColor.white,
    .paragraphStyle: para
]
NSAttributedString(string: "C", attributes: attrs)
    .draw(in: NSRect(x: 0, y: 120, width: size, height: 700))
img.unlockFocus()

// 写 iconset 各尺寸 + 转 icns
let fileManager = FileManager.default
let iconset = URL(fileURLWithPath: "AppIcon.iconset")
try? fileManager.removeItem(at: iconset)
try! fileManager.createDirectory(at: iconset, withIntermediateDirectories: true)
let sizes: [(Int, Bool)] = [(16, false), (16, true), (32, false), (32, true),
                            (128, false), (128, true), (256, false), (256, true),
                            (512, false), (512, true)]
for (s, is2x) in sizes {
    let px = is2x ? s * 2 : s
    let name = "icon_\(s)x\(s)\(is2x ? "@2x" : "").png"
    let out = iconset.appendingPathComponent(name)
    let scaled = NSImage(size: NSSize(width: px, height: px))
    scaled.lockFocus()
    NSGraphicsContext.current?.imageInterpolation = .high
    img.draw(in: NSRect(x: 0, y: 0, width: CGFloat(px), height: CGFloat(px)))
    scaled.unlockFocus()
    let scaledRep = NSBitmapImageRep(data: scaled.tiffRepresentation!)!
    try! scaledRep.representation(using: .png, properties: [:])!.write(to: out)
}
_ = fileManager.createFile(atPath: "icon_1024x1024.png", contents: {
    let rep = NSBitmapImageRep(data: img.tiffRepresentation!)!
    return rep.representation(using: .png, properties: [:])
}())
try? fileManager.copyItem(at: URL(fileURLWithPath: "icon_1024x1024.png"),
                          to: iconset.appendingPathComponent("icon_512x512@2x.png"))

let proc = Process()
proc.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
proc.arguments = ["-c", "icns", "AppIcon.iconset"]
try! proc.run()
proc.waitUntilExit()
print("icon generated: AppIcon.icns")
