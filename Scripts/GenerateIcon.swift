import AppKit
import CoreGraphics
import Foundation

let output = URL(fileURLWithPath: CommandLine.arguments[1])
try FileManager.default.createDirectory(at: output.deletingLastPathComponent(), withIntermediateDirectories: true)
let colorSpace = CGColorSpace(name: CGColorSpace.sRGB)!

func color(_ red: CGFloat, _ green: CGFloat, _ blue: CGFloat, _ alpha: CGFloat = 1) -> CGColor {
    CGColor(red: red, green: green, blue: blue, alpha: alpha)
}

func draw(size: Int) -> Data {
    let context = CGContext(data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: 0,
                            space: colorSpace, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    context.scaleBy(x: CGFloat(size) / 1024, y: CGFloat(size) / 1024)
    let tile = CGPath(roundedRect: CGRect(x: 100, y: 100, width: 824, height: 824),
                      cornerWidth: 188, cornerHeight: 188, transform: nil)
    context.saveGState()
    context.setShadow(offset: CGSize(width: 0, height: -16), blur: 36, color: color(0.02, 0.16, 0.10, 0.24))
    context.setFillColor(color(0.05, 0.41, 0.26))
    context.addPath(tile)
    context.fillPath()
    context.restoreGState()

    context.saveGState()
    context.addPath(tile)
    context.clip()
    let gradient = CGGradient(colorsSpace: colorSpace,
                              colors: [color(0.24, 0.74, 0.49), color(0.05, 0.42, 0.28)] as CFArray,
                              locations: [0, 1])!
    context.drawLinearGradient(gradient, start: CGPoint(x: 290, y: 950), end: CGPoint(x: 670, y: 120), options: [.drawsAfterEndLocation, .drawsBeforeStartLocation])
    context.restoreGState()
    context.setStrokeColor(color(1, 1, 1, 0.18))
    context.setLineWidth(3)
    context.addPath(tile)
    context.strokePath()

    func bubble(_ bounds: CGRect, tail: [CGPoint], fill: CGColor, dots: [CGPoint], ink: CGColor) {
        context.saveGState()
        context.setShadow(offset: CGSize(width: 0, height: -8), blur: 18, color: color(0.03, 0.20, 0.12, 0.22))
        context.setFillColor(fill)
        let path = CGMutablePath()
        path.addRoundedRect(in: bounds, cornerWidth: 90, cornerHeight: 90)
        path.move(to: tail[0])
        path.addQuadCurve(to: tail[2], control: tail[1])
        path.addLine(to: tail[3])
        path.closeSubpath()
        context.addPath(path)
        context.fillPath()
        context.restoreGState()
        context.setFillColor(ink)
        for dot in dots {
            context.fillEllipse(in: CGRect(x: dot.x - 17, y: dot.y - 17, width: 34, height: 34))
        }
    }

    bubble(CGRect(x: 225, y: 453, width: 384, height: 243),
           tail: [CGPoint(x: 284, y: 490), CGPoint(x: 271, y: 457), CGPoint(x: 263, y: 425), CGPoint(x: 350, y: 474)],
           fill: color(0.98, 1, 0.99), dots: [CGPoint(x: 345, y: 573), CGPoint(x: 416, y: 573), CGPoint(x: 487, y: 573)],
           ink: color(0.09, 0.43, 0.29))
    bubble(CGRect(x: 463, y: 333, width: 341, height: 224),
           tail: [CGPoint(x: 735, y: 373), CGPoint(x: 754, y: 338), CGPoint(x: 766, y: 308), CGPoint(x: 675, y: 350)],
           fill: color(0.80, 0.95, 0.73), dots: [CGPoint(x: 565, y: 444), CGPoint(x: 633, y: 444), CGPoint(x: 701, y: 444)],
           ink: color(0.09, 0.43, 0.29))

    return NSBitmapImageRep(cgImage: context.makeImage()!).representation(using: .png, properties: [:])!
}

func word(_ value: Int) -> Data {
    var bytes = UInt32(value).bigEndian
    return Data(bytes: &bytes, count: MemoryLayout<UInt32>.size)
}

let sizes = [("icp4", 16), ("icp5", 32), ("icp6", 64), ("ic07", 128), ("ic08", 256), ("ic09", 512), ("ic10", 1024)]
var resources = Data()
for (type, size) in sizes {
    let png = draw(size: size)
    resources.append(Data(type.utf8))
    resources.append(word(png.count + 8))
    resources.append(png)
}
let header = Data("icns".utf8) + word(resources.count + 8)
try (header + resources).write(to: output)
