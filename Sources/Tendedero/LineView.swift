import SwiftUI

enum Layout {
    /// How big the photos hang, from Size in the menu bar. The clip, the rope
    /// and the glass frame keep their size; the photos and the room they take
    /// grow or shrink. Medium is the original size.
    enum Size: String, CaseIterable {
        case small, medium, large

        var scale: CGFloat {
            switch self {
            case .small: 0.8
            case .medium: 1
            case .large: 1.35
            }
        }
    }

    static var size: Size {
        get { Size(rawValue: UserDefaults.standard.string(forKey: "lineSize") ?? "") ?? .medium }
        set { UserDefaults.standard.set(newValue.rawValue, forKey: "lineSize") }
    }

    static var photoMaxHeight: CGFloat { (104 * size.scale).rounded() }
    static var cardWidth: CGFloat { (150 * size.scale).rounded() }
    static var spacing: CGFloat { cardWidth + 24 }
    static var panelHeight: CGFloat { photoMaxHeight + 106 }
    static let ropeTop: CGFloat = 10
    static let pinAbove: CGFloat = 9.5

    /// The rope hangs as a parabola from edge to edge of the screen.
    static func sag(width: CGFloat) -> CGFloat { min(30, width * 0.018) }

    static func ropeY(x: CGFloat, width: CGFloat) -> CGFloat {
        guard width > 0 else { return ropeTop }
        let f = x / width
        return ropeTop + 4 * sag(width: width) * f * (1 - f)
    }

    /// Photos hang `spacing` apart, centred. When there are more than the
    /// `visible` that fit: with Keep on line set, they keep their spacing,
    /// the newest stays where the last one would hang on a full line, and
    /// `scroll` brings older ones in from the left. Otherwise (a line hung
    /// on a wider screen) they move closer together so none is past the edge.
    /// Fixed edge-to-edge gaps, measured from the central 152-point drop card.
    static func centeredPositions(widths: [CGFloat], width: CGFloat) -> [CGFloat] {
        let split = widths.count / 2
        var positions = Array(repeating: CGFloat.zero, count: widths.count)
        let gap: CGFloat = 24
        var left = width / 2 - 76 - gap
        for i in (0..<split).reversed() {
            positions[i] = left - widths[i] / 2
            left -= widths[i] + gap
        }
        var right = width / 2 + 76 + gap
        for i in split..<widths.count {
            positions[i] = right + widths[i] / 2
            right += widths[i] + gap
        }
        return positions
    }

    static func x(index: Int, count: Int, width: CGFloat, visible: Int, scroll: CGFloat) -> CGFloat {
        let gap = cardWidth + 176
        let available = max(240, width - gap)
        let raw = photoX(index: index, count: count, width: available, visible: visible, scroll: scroll)
        return raw < available / 2 ? raw : raw + gap
    }

    private static func photoX(index: Int, count: Int, width: CGFloat, visible: Int, scroll: CGFloat) -> CGFloat {
        if Line.keepOnLine != nil && count > visible {
            let newest = width / 2 + CGFloat(visible - 1) * spacing / 2
            return newest - CGFloat(count - 1 - index) * spacing + scroll
        }
        let gaps = CGFloat(max(count - 1, 0))
        let step = gaps > 0 ? min(spacing, max(0, width - 200) / gaps) : spacing
        return width / 2 - gaps * step / 2 + CGFloat(index) * step
    }
}

struct LineView: View {
    @ObservedObject var line: Line
    @ObservedObject private var importer = CaptureImport.shared
    private let dropID = UUID(uuidString: "11223344-0000-0000-0000-000000000002")!
    private let handleID = UUID(uuidString: "11223344-0000-0000-0000-000000000001")!

    var body: some View {
        GeometryReader { geo in
            let width = geo.size.width
            let displayed = Array(line.items.suffix(max(1, line.visibleCount)))
            let positions = Layout.centeredPositions(widths: displayed.map { PeggedView.cardSize(for: $0.thumb.size).width }, width: width)
            ZStack(alignment: .topLeading) {
                Rope(width: width)
                Button("搜索与整理  ﹀") { CaptureDrawer.shared.show() }
                    .buttonStyle(.borderedProminent)
                    .background(GeometryReader { g in Color.clear.preference(key: HitRectsKey.self, value: [handleID: g.frame(in: .named("line"))]) })
                    .simultaneousGesture(DragGesture(minimumDistance: 12).onEnded { value in if value.translation.height > 20 { CaptureDrawer.shared.show() } })
                    .position(x: width / 2, y: Layout.panelHeight - 20)

                VStack(spacing: 8) {
                    Image(systemName: "plus").font(.system(size: 27, weight: .light))
                    Text("拖入图片").font(.system(size: 13, weight: .semibold))
                    Text(importer.message == "＋ 拖入图片" ? "或点击添加" : importer.message)
                        .font(.system(size: 10)).foregroundStyle(.secondary).lineLimit(2)
                }
                .frame(width: 152, height: 112)
                .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 18))
                .overlay(RoundedRectangle(cornerRadius: 18).strokeBorder(Color.orange.opacity(0.7), style: StrokeStyle(lineWidth: 1.5, dash: [5, 4])))
                .overlay(CaptureDrop())
                .background(GeometryReader { g in Color.clear.preference(key: HitRectsKey.self, value: [dropID: g.frame(in: .named("line"))]) })
                .position(x: width / 2, y: 96)
                .zIndex(2)

                ForEach(Array(displayed.enumerated()), id: \.element.id) { index, item in
                    let x = positions[index]
                    let ropeY: CGFloat = 34
                    PeggedView(item: item, line: line)
                        .frame(width: Layout.cardWidth, height: Layout.panelHeight - ropeY, alignment: .top)
                        // Photos scrolled towards an edge fade out before they reach it.
                        .opacity(min(1, max(0, min(x, width - x) / 90)))
                        .position(x: x, y: ropeY - Layout.pinAbove + (Layout.panelHeight - ropeY) / 2)
                }
            }
            .animation(.spring(response: 0.55, dampingFraction: 0.78), value: line.items.map(\.id))
            .animation(.easeInOut(duration: 0.3), value: line.items.isEmpty)
            // Tucked away, the whole line waits above the top edge and slides
            // out from under the menu bar, the way an auto-hiding Dock does.
            .offset(y: line.revealed ? 0 : -(Layout.panelHeight + 12))
            .animation(line.revealed ? .spring(response: 0.42, dampingFraction: 0.82)
                                     : .easeIn(duration: 0.22), value: line.revealed)
        }
        .coordinateSpace(name: "line")
        .onPreferenceChange(HitRectsKey.self) { rects in
            line.hitRects = rects
        }
    }
}

private struct Hint: View {
    var body: some View {
        Text(L("Take a screenshot and it will hang here"))
            .font(.system(size: 12, weight: .medium, design: .rounded))
            .foregroundStyle(.secondary)
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background(.regularMaterial, in: Capsule())
    }
}

/// A thin, neutral line: a mid gray core with a faint highlight and a soft
/// shadow, so it reads on light and dark backgrounds alike. It fades out at
/// both ends so it seems to come from beyond the screen.
struct Rope: View {
    let width: CGFloat

    private var path: Path {
        Path { p in
            let top = Layout.ropeTop
            p.move(to: CGPoint(x: -20, y: top))
            p.addQuadCurve(
                to: CGPoint(x: width + 20, y: top),
                control: CGPoint(x: width / 2, y: top + 2 * Layout.sag(width: width)))
        }
    }

    var body: some View {
        ZStack {
            path.stroke(Color.black.opacity(0.22), lineWidth: 1.4).offset(y: 1.2).blur(radius: 1.2)
            path.stroke(Color(white: 0.55), lineWidth: 1.2)
            path.stroke(Color.white.opacity(0.45), lineWidth: 0.4).offset(y: -0.35)
        }
        .mask(
            LinearGradient(stops: [
                .init(color: .clear, location: 0),
                .init(color: .black, location: 0.08),
                .init(color: .black, location: 0.92),
                .init(color: .clear, location: 1),
            ], startPoint: .leading, endPoint: .trailing)
        )
        .allowsHitTesting(false)
    }
}

struct HitRectsKey: PreferenceKey {
    static var defaultValue: [UUID: CGRect] = [:]
    static func reduce(value: inout [UUID: CGRect], nextValue: () -> [UUID: CGRect]) {
        value.merge(nextValue()) { $1 }
    }
}
