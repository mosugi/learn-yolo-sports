#!/usr/bin/env swift
// アプリアイコン（ライト / ダーク / ティント）を生成して AppIcon.appiconset に書き出す
// 使い方: swift scripts/generate_app_icon.swift

import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

let size = 1024
let outputDir = URL(fileURLWithPath: #filePath)
    .deletingLastPathComponent()
    .deletingLastPathComponent()
    .appendingPathComponent("learn-yolo-sports/Assets.xcassets/AppIcon.appiconset")

struct Palette {
    var backgroundTop: CGColor
    var backgroundBottom: CGColor
    var pitchLine: CGColor
    var ballFill: CGColor
    var ballPatch: CGColor
    var box: CGColor
    var label: CGColor
}

func rgb(_ hex: UInt32, _ alpha: CGFloat = 1) -> CGColor {
    CGColor(
        srgbRed: CGFloat((hex >> 16) & 0xFF) / 255,
        green: CGFloat((hex >> 8) & 0xFF) / 255,
        blue: CGFloat(hex & 0xFF) / 255,
        alpha: alpha
    )
}

let palettes: [(String, Palette)] = [
    ("AppIcon.png", Palette(
        backgroundTop: rgb(0x14A44D), backgroundBottom: rgb(0x07562A),
        pitchLine: rgb(0xFFFFFF, 0.22), ballFill: rgb(0xFFFFFF), ballPatch: rgb(0x1C1C1E),
        box: rgb(0xFFD60A), label: rgb(0xFFD60A)
    )),
    ("AppIcon-Dark.png", Palette(
        backgroundTop: rgb(0x0E2A1A), backgroundBottom: rgb(0x020805),
        pitchLine: rgb(0x30D158, 0.25), ballFill: rgb(0xF2F2F7), ballPatch: rgb(0x1C1C1E),
        box: rgb(0xFFD60A), label: rgb(0xFFD60A)
    )),
    ("AppIcon-Tinted.png", Palette(
        backgroundTop: rgb(0x000000), backgroundBottom: rgb(0x000000),
        pitchLine: rgb(0xFFFFFF, 0.25), ballFill: rgb(0xFFFFFF), ballPatch: rgb(0x000000),
        box: rgb(0xFFFFFF, 0.85), label: rgb(0xFFFFFF, 0.85)
    )),
]

func regularPolygon(center: CGPoint, radius: CGFloat, sides: Int, rotation: CGFloat) -> CGPath {
    let path = CGMutablePath()
    for i in 0..<sides {
        let angle = rotation + CGFloat(i) * 2 * .pi / CGFloat(sides)
        let point = CGPoint(x: center.x + radius * cos(angle), y: center.y + radius * sin(angle))
        i == 0 ? path.move(to: point) : path.addLine(to: point)
    }
    path.closeSubpath()
    return path
}

func drawIcon(_ p: Palette, in ctx: CGContext) {
    let s = CGFloat(size)

    // 背景（ピッチの縦グラデーション）
    let gradient = CGGradient(
        colorsSpace: CGColorSpace(name: CGColorSpace.sRGB),
        colors: [p.backgroundTop, p.backgroundBottom] as CFArray,
        locations: [0, 1]
    )!
    ctx.drawLinearGradient(gradient, start: CGPoint(x: 0, y: s), end: CGPoint(x: 0, y: 0), options: [])

    // ピッチライン（ハーフウェイラインとセンターサークル）
    ctx.setStrokeColor(p.pitchLine)
    ctx.setLineWidth(14)
    ctx.move(to: CGPoint(x: 0, y: s / 2))
    ctx.addLine(to: CGPoint(x: s, y: s / 2))
    ctx.strokePath()
    ctx.strokeEllipse(in: CGRect(x: s / 2 - 300, y: s / 2 - 300, width: 600, height: 600))

    // ボール
    let center = CGPoint(x: s / 2, y: s / 2)
    let radius: CGFloat = 220
    let ballRect = CGRect(x: center.x - radius, y: center.y - radius, width: radius * 2, height: radius * 2)
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -14), blur: 36, color: rgb(0x000000, 0.35))
    ctx.setFillColor(p.ballFill)
    ctx.fillEllipse(in: ballRect)
    ctx.restoreGState()

    ctx.saveGState()
    ctx.addEllipse(in: ballRect)
    ctx.clip()
    ctx.setFillColor(p.ballPatch)
    ctx.setStrokeColor(p.ballPatch)
    ctx.setLineWidth(10)
    let pentagonRadius: CGFloat = 78
    let top = CGFloat.pi / 2
    ctx.addPath(regularPolygon(center: center, radius: pentagonRadius, sides: 5, rotation: top))
    ctx.fillPath()
    for i in 0..<5 {
        let angle = top + CGFloat(i) * 2 * .pi / 5
        let vertex = CGPoint(x: center.x + pentagonRadius * cos(angle), y: center.y + pentagonRadius * sin(angle))
        let outer = CGPoint(x: center.x + 205 * cos(angle), y: center.y + 205 * sin(angle))
        ctx.move(to: vertex)
        ctx.addLine(to: outer)
        ctx.strokePath()
        let patch = CGPoint(x: center.x + 250 * cos(angle), y: center.y + 250 * sin(angle))
        ctx.addPath(regularPolygon(center: patch, radius: 72, sides: 5, rotation: angle + .pi))
        ctx.fillPath()
    }
    ctx.restoreGState()

    // 検出ボックス（コーナーブラケット）
    let box = ballRect.insetBy(dx: -62, dy: -62)
    let arm: CGFloat = 112
    ctx.setStrokeColor(p.box)
    ctx.setLineWidth(30)
    ctx.setLineCap(.round)
    ctx.setLineJoin(.round)
    let corners: [(CGPoint, CGFloat, CGFloat)] = [
        (CGPoint(x: box.minX, y: box.maxY), 1, -1),
        (CGPoint(x: box.maxX, y: box.maxY), -1, -1),
        (CGPoint(x: box.minX, y: box.minY), 1, 1),
        (CGPoint(x: box.maxX, y: box.minY), -1, 1),
    ]
    for (corner, dx, dy) in corners {
        ctx.move(to: CGPoint(x: corner.x, y: corner.y + dy * arm))
        ctx.addLine(to: corner)
        ctx.addLine(to: CGPoint(x: corner.x + dx * arm, y: corner.y))
        ctx.strokePath()
    }

    // ラベルタグ（ボックス左上）
    let tag = CGRect(x: box.minX - 15, y: box.maxY + 38, width: 190, height: 62)
    ctx.setFillColor(p.label)
    ctx.addPath(CGPath(roundedRect: tag, cornerWidth: 20, cornerHeight: 20, transform: nil))
    ctx.fillPath()
}

for (fileName, palette) in palettes {
    let ctx = CGContext(
        data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: 0,
        space: CGColorSpace(name: CGColorSpace.sRGB)!,
        bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
    )!
    drawIcon(palette, in: ctx)
    let url = outputDir.appendingPathComponent(fileName)
    let dest = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil)!
    CGImageDestinationAddImage(dest, ctx.makeImage()!, nil)
    guard CGImageDestinationFinalize(dest) else { fatalError("書き出しに失敗: \(fileName)") }
    print("wrote \(url.path)")
}
