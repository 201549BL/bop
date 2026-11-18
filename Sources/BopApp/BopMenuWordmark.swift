import AppKit
import SwiftUI

struct BopMenuWordmark: View {
    static let width: CGFloat = 42
    static let detectionDuration: Double = 1.0
    static let animationDuration = Double(Glyph.exclamation.rawValue) * glyphStagger + glyphJumpDuration
    static let listeningDotColor = NSColor.systemGreen
    static let listeningDotDiameter: CGFloat = 3.5
    static let listeningDotOffset = CGSize(width: 18, height: 1)

    private static let glyphStagger = 0.09
    private static let glyphJumpDuration = 0.32

    var isListening = false
    var isDetected = false
    var jumpTime: Double? = nil

    var body: some View {
        let lettering = BopLettering(width: 32)
        ZStack {
            if isDetected, let jumpTime, jumpTime < Self.animationDuration {
                ForEach(Glyph.allCases, id: \.self) { glyph in
                    let elapsed = jumpTime - Double(glyph.rawValue) * Self.glyphStagger
                    lettering
                        .mask(GlyphMask(left: glyph.rawValue, right: glyph.rawValue + 1))
                        .offset(y: -glyph.jumpHeight(at: elapsed))
                }
            } else {
                lettering
            }

            if isListening {
                Circle()
                    .fill(Color(nsColor: Self.listeningDotColor))
                    .frame(width: Self.listeningDotDiameter, height: Self.listeningDotDiameter)
                    .offset(Self.listeningDotOffset)
            }

            if isDetected, jumpTime == nil {
                Capsule()
                    .fill(.foreground)
                    .frame(width: 8, height: 1.25)
                    .offset(y: 9.5)
            }
        }
        .frame(width: Self.width, height: 22)
    }

    private enum Glyph: Int, CaseIterable {
        case b, o, p, exclamation

        @MainActor
        func jumpHeight(at elapsed: Double) -> CGFloat {
            let progress = elapsed / BopMenuWordmark.glyphJumpDuration
            guard progress > 0, progress < 1 else { return 0 }

            let peak = 0.42
            let height: CGFloat = self == .exclamation ? 2 : 3
            if progress < peak {
                return height * UnitCurve.easeOut.value(at: progress / peak)
            }
            let descent = (progress - peak) / (1 - peak)
            return height * (1 - descent * descent)
        }
    }

    private struct GlyphMask: Shape {
        let left: Int
        let right: Int

        // The intermediate edges follow the gaps between glyphs in the 512 × 512 artwork.
        private static let edges: [[CGPoint]] = [
            [CGPoint(x: 0, y: 0), CGPoint(x: 0, y: 512)],
            [
                CGPoint(x: 179, y: 0), CGPoint(x: 178, y: 184), CGPoint(x: 171, y: 203),
                CGPoint(x: 168, y: 217), CGPoint(x: 164, y: 234), CGPoint(x: 153, y: 260),
                CGPoint(x: 162, y: 269), CGPoint(x: 174, y: 285), CGPoint(x: 177.5, y: 297),
                CGPoint(x: 177.5, y: 308), CGPoint(x: 174, y: 324), CGPoint(x: 171, y: 341),
                CGPoint(x: 171, y: 512)
            ],
            [
                CGPoint(x: 277, y: 0), CGPoint(x: 277, y: 182), CGPoint(x: 280, y: 200),
                CGPoint(x: 283.5, y: 225), CGPoint(x: 285, y: 246), CGPoint(x: 285, y: 270),
                CGPoint(x: 283.5, y: 282), CGPoint(x: 280, y: 310), CGPoint(x: 274, y: 337),
                CGPoint(x: 274, y: 512)
            ],
            [
                CGPoint(x: 401, y: 0), CGPoint(x: 401, y: 182), CGPoint(x: 398, y: 207),
                CGPoint(x: 395.5, y: 225), CGPoint(x: 393, y: 239), CGPoint(x: 389, y: 250),
                CGPoint(x: 375, y: 270), CGPoint(x: 344, y: 299), CGPoint(x: 344, y: 512)
            ],
            [CGPoint(x: 512, y: 0), CGPoint(x: 512, y: 512)]
        ]

        func path(in rect: CGRect) -> Path {
            // BopLettering centers the source square inside a 90%-width crop.
            let scale = rect.width / (0.9 * 512)
            let outline = Self.edges[left] + Self.edges[right].reversed()
            var path = Path()
            path.addLines(outline.map { point in
                CGPoint(x: rect.midX + (point.x - 256) * scale, y: rect.midY + (point.y - 256) * scale)
            })
            path.closeSubpath()
            return path
        }
    }
}
