#!/usr/bin/env swift
//
// crop-tiles.swift — cut full-resolution JPEG tiles from the original shelf PNGs.
//
// The originals (~5712×4284, ~25 MB) live in ../samples and are never committed.
// This produces legible ~1500 px crops for the Wave 4 recogniser tests.
//
// Usage:
//   swift scripts/crop-tiles.swift <in.png> <out.jpg> <x> <y> <w> <h> [quality]
//
// x,y = top-left offset in the ORIGINAL pixel space; w,h = crop size in px.
// quality defaults to 0.8. Regions are clamped to the image bounds.

import Foundation
import ImageIO
import CoreGraphics
import UniformTypeIdentifiers

let args = CommandLine.arguments
guard args.count >= 7 else {
    FileHandle.standardError.write(Data("usage: crop-tiles.swift <in> <out> <x> <y> <w> <h> [quality]\n".utf8))
    exit(2)
}
let inPath = args[1], outPath = args[2]
guard let x = Int(args[3]), let y = Int(args[4]), let w = Int(args[5]), let h = Int(args[6]) else {
    FileHandle.standardError.write(Data("x/y/w/h must be integers\n".utf8)); exit(2)
}
let quality = args.count > 7 ? (Double(args[7]) ?? 0.8) : 0.8

guard let src = CGImageSourceCreateWithURL(URL(fileURLWithPath: inPath) as CFURL, nil),
      let img = CGImageSourceCreateImageAtIndex(src, 0, nil) else {
    FileHandle.standardError.write(Data("cannot read \(inPath)\n".utf8)); exit(1)
}
let maxW = img.width, maxH = img.height
let cx = max(0, min(x, maxW - 1))
let cy = max(0, min(y, maxH - 1))
let cw = min(w, maxW - cx)
let ch = min(h, maxH - cy)
guard let cropped = img.cropping(to: CGRect(x: cx, y: cy, width: cw, height: ch)) else {
    FileHandle.standardError.write(Data("crop failed\n".utf8)); exit(1)
}
guard let dst = CGImageDestinationCreateWithURL(URL(fileURLWithPath: outPath) as CFURL, UTType.jpeg.identifier as CFString, 1, nil) else {
    FileHandle.standardError.write(Data("cannot open \(outPath)\n".utf8)); exit(1)
}
CGImageDestinationAddImage(dst, cropped, [kCGImageDestinationLossyCompressionQuality: quality] as CFDictionary)
guard CGImageDestinationFinalize(dst) else {
    FileHandle.standardError.write(Data("write failed\n".utf8)); exit(1)
}
print("\(outPath): \(cw)x\(ch)")
