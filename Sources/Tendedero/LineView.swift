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
    static func x(index: Int, count: Int, width: CGFloat, visible: Int, scroll: CGFloat) -> CGFloat {
        photoX(index: index, count: count, width: width, visible: visible, scroll: scroll)
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
            let displayed = line.items
            ZStack(alignment: .topLeading) {
                Rope(width: width)
                HStack(spacing: 8) {
                    HStack(spacing: 12) {
                    Button { withAnimation(.easeOut(duration: 0.2)) { line.scroll(by: Layout.spacing * CGFloat(line.visibleCount)) } } label: {
                        Label("更早", systemImage: "chevron.left")
                    }
                    .disabled(line.scroll >= CGFloat(max(0, line.items.count - line.visibleCount)) * Layout.spacing)
                    Button { CaptureDrawer.shared.show() } label: { Label("搜索与整理", systemImage: "magnifyingglass") }
                    }.frame(width: 200)
                    Rectangle().fill(Color.white.opacity(0.18)).frame(width: 1, height: 24)
                    HStack(spacing: 7) {
                        Image(systemName: "plus").font(.system(size: 23, weight: .medium))
                        Text("拖入图片").font(.system(size: 12, weight: .semibold))
                    }
                    .frame(width: 114, height: 42)
                    .foregroundStyle(.white)
                    .background(Color(red: 0.30, green: 0.35, blue: 0.86), in: RoundedRectangle(cornerRadius: 12))
                    .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(Color.white.opacity(0.22)))
                    .overlay(CaptureDrop())
                    .help("拖入图片或文字 · 单击添加 · 双击上传剪贴板图片")
                    .background(GeometryReader { g in Color.clear.preference(key: HitRectsKey.self, value: [dropID: g.frame(in: .named("line"))]) })
                    Rectangle().fill(Color.white.opacity(0.18)).frame(width: 1, height: 24)
                    HStack(spacing: 12) {
                    Button { CaptureWaterfall.shared.show() } label: { Label("展开", systemImage: "chevron.down") }
                        .help("展开全部采集，瀑布流浏览")
                    Button { withAnimation(.easeOut(duration: 0.2)) { line.scroll(by: -Layout.spacing * CGFloat(line.visibleCount)) } } label: {
                        Label("更新", systemImage: "chevron.right")
                    }
                    .disabled(line.scroll <= 0)
                    Button { CaptureSettings.shared.show() } label: {
                        Image(systemName: "gearshape")
                            .font(.system(size: 15, weight: .medium))
                            .frame(width: 24, height: 24)
                    }
                    .help("设置 · 快捷键、采集与同步")
                    .accessibilityLabel("设置")
                    }.frame(width: 200)
                }
                .font(.system(size: 12, weight: .semibold))
                .buttonStyle(CaptureDockButtonStyle())
                .padding(.horizontal, 14).padding(.vertical, 7)
                .background(Color(red: 0.16, green: 0.17, blue: 0.20).opacity(0.98), in: RoundedRectangle(cornerRadius: 19))
                .overlay(RoundedRectangle(cornerRadius: 19).strokeBorder(.white.opacity(0.20)))
                .shadow(color: .black.opacity(0.14), radius: 10, y: 3)
                .background(GeometryReader { g in Color.clear.preference(key: HitRectsKey.self, value: [handleID: g.frame(in: .named("line"))]) })
                .position(x: width / 2, y: Layout.panelHeight - 34)
                .zIndex(2)

                if importer.message != "＋ 拖入图片" {
                    Text(importer.message).font(.system(size: 11, weight: .medium)).foregroundStyle(.white).lineLimit(1)
                        .padding(.horizontal, 10).padding(.vertical, 3)
                        .background(Color(white: 0.18).opacity(0.98), in: Capsule())
                        .position(x: width / 2, y: Layout.panelHeight - 72)
                        .allowsHitTesting(false).zIndex(3)
                }

                ForEach(Array(displayed.enumerated()), id: \.element.id) { index, item in
                    let x = Layout.x(index: index, count: displayed.count, width: width, visible: line.visibleCount, scroll: line.scroll)
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

/// Explicit colors remain readable even when the accessory panel is inactive.
private struct CaptureDockButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var enabled
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .foregroundStyle(Color(white: enabled ? 0.97 : 0.58))
            .padding(.vertical, 9).padding(.horizontal, 5)
            .background(Color.white.opacity(configuration.isPressed && enabled ? 0.15 : 0), in: RoundedRectangle(cornerRadius: 8))
            .contentShape(Rectangle())
    }
}
