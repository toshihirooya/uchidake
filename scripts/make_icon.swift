// アプリのアイコン（1024×1024 の PNG）を描いて書き出す。
// 使い方: swift scripts/make_icon.swift Uchidake/Assets.xcassets/AppIcon.appiconset/AppIcon.png
//
// 絵は「家の中にレンズ」。色はアプリ内の Theme（暗い紺とミント）に合わせている。
// 角の丸みと透明は付けない（iOS が丸く切り抜く）。

import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

let size = 1024
let unit = CGFloat(size) / 180  // 絵は 180×180 の座標で描く

func color(_ red: CGFloat, _ green: CGFloat, _ blue: CGFloat) -> CGColor {
    CGColor(srgbRed: red, green: green, blue: blue, alpha: 1)
}

let background = color(0.07, 0.08, 0.11)
let mint = color(0.42, 0.80, 0.68)
let white = color(1, 1, 1)

guard CommandLine.arguments.count == 2 else {
    FileHandle.standardError.write(Data("書き出し先のパスを 1 つ指定してください\n".utf8))
    exit(1)
}
let destination = URL(fileURLWithPath: CommandLine.arguments[1])

let context = CGContext(
    data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: 0,
    space: CGColorSpace(name: CGColorSpace.sRGB)!,
    bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!

// 左上を原点にして、180×180 の座標で描けるようにする
context.translateBy(x: 0, y: CGFloat(size))
context.scaleBy(x: unit, y: -unit)

context.setFillColor(background)
context.fill(CGRect(x: 0, y: 0, width: 180, height: 180))

// 家（上下の中央に来るよう少し下げる）
context.translateBy(x: 0, y: 3)
let house = CGMutablePath()
house.addLines(between: [
    CGPoint(x: 90, y: 30), CGPoint(x: 152, y: 84), CGPoint(x: 136, y: 84), CGPoint(x: 136, y: 144),
    CGPoint(x: 44, y: 144), CGPoint(x: 44, y: 84), CGPoint(x: 28, y: 84),
])
house.closeSubpath()
context.addPath(house)
context.setFillColor(mint)
context.setStrokeColor(mint)
context.setLineWidth(10)
context.setLineJoin(.round)
context.drawPath(using: .fillStroke)

// レンズ
func circle(x: CGFloat, y: CGFloat, radius: CGFloat, fill: CGColor) {
    context.setFillColor(fill)
    context.fillEllipse(in: CGRect(x: x - radius, y: y - radius, width: radius * 2, height: radius * 2))
}
circle(x: 90, y: 102, radius: 28, fill: background)
circle(x: 90, y: 102, radius: 15, fill: mint)
circle(x: 84, y: 96, radius: 4, fill: white)

guard let image = context.makeImage(),
      let output = CGImageDestinationCreateWithURL(destination as CFURL, UTType.png.identifier as CFString, 1, nil) else {
    FileHandle.standardError.write(Data("画像を作れませんでした\n".utf8))
    exit(1)
}
CGImageDestinationAddImage(output, image, nil)
guard CGImageDestinationFinalize(output) else {
    FileHandle.standardError.write(Data("書き出せませんでした: \(destination.path)\n".utf8))
    exit(1)
}
