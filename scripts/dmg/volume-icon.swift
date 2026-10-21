// Renders the app's own system icon (Assets.car: squircle mask, depth, padding) into an
// .iconset at every size, for the DMG volume icon.
//   swiftc -O scripts/dmg/volume-icon.swift -o /tmp/volume-icon && /tmp/volume-icon Mouthtype.app out.iconset
import AppKit

let args = CommandLine.arguments
guard args.count == 3 else { FileHandle.standardError.write(Data("usage: volume-icon APP ICONSET\n".utf8)); exit(2) }
let icon = NSWorkspace.shared.icon(forFile: args[1])
try FileManager.default.createDirectory(atPath: args[2], withIntermediateDirectories: true)
for base in [16, 32, 128, 256, 512] {
    for scale in [1, 2] {
        let px = base * scale
        guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: px, pixelsHigh: px, bitsPerSample: 8,
                                         samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                         colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0) else { exit(1) }
        rep.size = NSSize(width: base, height: base)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        icon.draw(in: NSRect(x: 0, y: 0, width: base, height: base), from: .zero, operation: .copy, fraction: 1)
        NSGraphicsContext.restoreGraphicsState()
        let name = scale == 1 ? "icon_\(base)x\(base).png" : "icon_\(base)x\(base)@2x.png"
        try rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: "\(args[2])/\(name)"))
    }
}
