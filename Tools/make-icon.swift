// make-icon.swift — 把一张方图做成 macOS 风格的应用图标
//
// 用法：swift Tools/make-icon.swift <输入图> <输出.iconset 目录>
//   生成 .icns 再交给 iconutil：iconutil -c icns <iconset> -o AppIcon.icns
//
// 为什么不能直接把方图塞进 .icns：macOS 应用图标有固定规范——内容只占画布
// 824/1024，外面留透明边距，四角是半径 185/1024 的圆角。直接放满画布的正方图，
// 在 Finder 和程序坞里会比旁边所有原生 App 都大一圈，而且四角是直角。

import Foundation
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers

let arguments = CommandLine.arguments
guard arguments.count >= 3 else {
    FileHandle.standardError.write(Data("用法：make-icon.swift <输入图> <输出.iconset>\n".utf8))
    exit(1)
}
let inputURL = URL(fileURLWithPath: arguments[1])
let outputDirectory = URL(fileURLWithPath: arguments[2])

guard let source = CGImageSourceCreateWithURL(inputURL as CFURL, nil),
      let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
    FileHandle.standardError.write(Data("读不出输入图：\(inputURL.path)\n".utf8))
    exit(1)
}

/// macOS 图标网格：内容和圆角都按画布比例算，才能保证每个尺寸看起来一致
let contentRatio: CGFloat = 824.0 / 1024.0
let cornerRatio: CGFloat = 185.0 / 1024.0

func render(side size: Int) -> CGImage? {
    guard let context = CGContext(data: nil, width: size, height: size,
                                  bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
    else { return nil }

    context.interpolationQuality = .high

    let canvas = CGFloat(size)
    let content = canvas * contentRatio
    let inset = (canvas - content) / 2
    let rect = CGRect(x: inset, y: inset, width: content, height: content)
    let radius = canvas * cornerRatio

    // 先按圆角矩形裁出区域再画图，四个角自然变成透明
    context.addPath(CGPath(roundedRect: rect, cornerWidth: radius, cornerHeight: radius,
                           transform: nil))
    context.clip()
    context.draw(image, in: rect)
    return context.makeImage()
}

// .iconset 必须是这 10 个文件，缺了 iconutil 会报错或生成不完整的 .icns
let entries: [(name: String, size: Int)] = [
    ("icon_16x16.png", 16),   ("icon_16x16@2x.png", 32),
    ("icon_32x32.png", 32),   ("icon_32x32@2x.png", 64),
    ("icon_128x128.png", 128), ("icon_128x128@2x.png", 256),
    ("icon_256x256.png", 256), ("icon_256x256@2x.png", 512),
    ("icon_512x512.png", 512), ("icon_512x512@2x.png", 1024),
]

try? FileManager.default.createDirectory(at: outputDirectory, withIntermediateDirectories: true)

for entry in entries {
    guard let rendered = render(side: entry.size) else {
        FileHandle.standardError.write(Data("渲染 \(entry.name) 失败\n".utf8))
        exit(1)
    }
    let destination = outputDirectory.appendingPathComponent(entry.name)
    guard let writer = CGImageDestinationCreateWithURL(
        destination as CFURL, UTType.png.identifier as CFString, 1, nil) else {
        FileHandle.standardError.write(Data("写不出 \(destination.path)\n".utf8))
        exit(1)
    }
    CGImageDestinationAddImage(writer, rendered, nil)
    guard CGImageDestinationFinalize(writer) else {
        FileHandle.standardError.write(Data("落盘失败 \(destination.path)\n".utf8))
        exit(1)
    }
}

print("已生成 \(entries.count) 个尺寸 → \(outputDirectory.path)")
