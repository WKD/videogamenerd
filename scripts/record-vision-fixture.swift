#!/usr/bin/env swift
//
// record-vision-fixture.swift — OCR a committed shelf tile with Apple Vision and dump
// the recognised lines (text + tile-pixel rect + confidence) as a JSON fixture, so the
// VisionSpineClusterer tests are deterministic without running Vision.
//
//   swift scripts/record-vision-fixture.swift <tile.jpg> <out.json>
//
// Mirrors VisionShelfRecognizer.recognizeLines exactly (3 orientations, map back with
// toImageCoordinates, de-dup). Writes nothing personal.

import Foundation
import Vision
import ImageIO
import CoreGraphics

let args = CommandLine.arguments
guard args.count >= 3 else {
    FileHandle.standardError.write(Data("usage: record-vision-fixture.swift <in.jpg> <out.json>\n".utf8))
    exit(2)
}
let inURL = URL(fileURLWithPath: args[1])
let outURL = URL(fileURLWithPath: args[2])

guard let src = CGImageSourceCreateWithURL(inURL as CFURL, nil),
      let image = CGImageSourceCreateImageAtIndex(src, 0, nil) else {
    FileHandle.standardError.write(Data("cannot read \(args[1])\n".utf8)); exit(1)
}

struct Line: Codable { var text: String; var rect: Rect; var confidence: Double }
struct Rect: Codable { var x: Int; var y: Int; var width: Int; var height: Int }

func recognize() async throws -> [Line] {
    let size = CGSize(width: image.width, height: image.height)
    var request = RecognizeTextRequest()
    request.recognitionLevel = .accurate
    request.usesLanguageCorrection = true
    request.recognitionLanguages = [Locale.Language(identifier: "en"), Locale.Language(identifier: "fr")]
    var lines: [Line] = []
    for orientation in [CGImagePropertyOrientation.up, .right, .left] {
        let observations = try await request.perform(on: image, orientation: orientation)
        for obs in observations {
            guard let cand = obs.topCandidates(1).first else { continue }
            let text = cand.string.trimmingCharacters(in: .whitespacesAndNewlines)
            if text.isEmpty { continue }
            let cg = obs.boundingBox.toImageCoordinates(size, origin: .upperLeft)
            lines.append(Line(
                text: text,
                rect: Rect(x: Int(cg.origin.x.rounded()), y: Int(cg.origin.y.rounded()),
                           width: Int(cg.size.width.rounded()), height: Int(cg.size.height.rounded())),
                confidence: Double(cand.confidence)))
        }
    }
    // De-dup identical text with horizontal overlap, keep higher confidence.
    var kept: [Line] = []
    for line in lines.sorted(by: { $0.confidence > $1.confidence }) {
        let dup = kept.contains { e in
            e.text.lowercased() == line.text.lowercased()
            && max(0, min(e.rect.x + e.rect.width, line.rect.x + line.rect.width) - max(e.rect.x, line.rect.x)) > 0
        }
        if !dup { kept.append(line) }
    }
    return kept
}

let sem = DispatchSemaphore(value: 0)
var out: [Line] = []
Task {
    do { out = try await recognize() } catch { FileHandle.standardError.write(Data("ocr failed: \(error)\n".utf8)) }
    sem.signal()
}
sem.wait()

let encoder = JSONEncoder()
encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
let data = try encoder.encode(out.sorted { $0.rect.x < $1.rect.x })
try data.write(to: outURL)
print("\(outURL.lastPathComponent): \(out.count) lines from \(image.width)x\(image.height)")
