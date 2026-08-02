import Foundation
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers

// 用 CoreGraphics 按 Android 矢量图标(108 视口)重绘 macOS 图标到 1024 PNG。
// 坐标:采用 y-up(CG 默认),把 Android 的 top-down y 换算为 108 - y。

let S = 1024
let k = CGFloat(S) / 108.0
func rgb(_ r: Int, _ g: Int, _ b: Int, _ a: CGFloat = 1) -> CGColor {
    CGColor(red: CGFloat(r)/255, green: CGFloat(g)/255, blue: CGFloat(b)/255, alpha: a)
}

let cs = CGColorSpace(name: CGColorSpace.sRGB)!
let ctx = CGContext(data: nil, width: S, height: S, bitsPerComponent: 8, bytesPerRow: 0,
                    space: cs, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
ctx.scaleBy(x: k, y: k) // 之后都用 108 单位坐标(y-up)

// 圆角矩形裁剪(squircle 近似)
let full = CGRect(x: 0, y: 0, width: 108, height: 108)
let clip = CGPath(roundedRect: full, cornerWidth: 24, cornerHeight: 24, transform: nil)
ctx.addPath(clip); ctx.clip()

// 背景线性渐变:top-down (0,0)->(108,108) 即 y-up (0,108)->(108,0)
let grad = CGGradient(colorsSpace: cs, colors: [rgb(18,48,58), rgb(11,22,24)] as CFArray, locations: [0, 1])!
ctx.drawLinearGradient(grad, start: CGPoint(x: 0, y: 108), end: CGPoint(x: 108, y: 0), options: [])

// 梁:圆角矩形 (24,31,60,14) top-down -> y-up y=108-45=63
ctx.setFillColor(rgb(233,200,121))
ctx.addPath(CGPath(roundedRect: CGRect(x: 24, y: 63, width: 60, height: 14), cornerWidth: 4, cornerHeight: 4, transform: nil))
ctx.fillPath()

// 斗拱支点 (30,45,7,7)/(71,45,7,7) -> y-up 56
ctx.setFillColor(rgb(216,180,94))
ctx.fill(CGRect(x: 30, y: 56, width: 7, height: 7))
ctx.fill(CGRect(x: 71, y: 56, width: 7, height: 7))

// 三道声波:圆心 (54,70)->y-up (54,38),上半圆(y-up 上方),半径 14/24/34
func arc(_ radius: CGFloat, _ color: CGColor) {
    ctx.setStrokeColor(color)
    ctx.setLineWidth(5)
    ctx.setLineCap(.round)
    ctx.beginPath()
    ctx.addArc(center: CGPoint(x: 54, y: 38), radius: radius, startAngle: 0, endAngle: .pi, clockwise: false)
    ctx.strokePath()
}
arc(14, rgb(143,224,206, 1.0))
arc(24, rgb(111,203,184, 0.72))
arc(34, rgb(87,182,164, 0.46))

// 声源点:圆心 (54,38) 半径 4
ctx.setFillColor(rgb(244,231,196))
ctx.fillEllipse(in: CGRect(x: 50, y: 34, width: 8, height: 8))

guard let img = ctx.makeImage() else { fatalError("makeImage failed") }
let out = URL(fileURLWithPath: CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "icon_1024.png")
let dest = CGImageDestinationCreateWithURL(out as CFURL, UTType.png.identifier as CFString, 1, nil)!
CGImageDestinationAddImage(dest, img, nil)
CGImageDestinationFinalize(dest)
print("wrote \(out.path)")
