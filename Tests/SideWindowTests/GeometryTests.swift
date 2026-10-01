import CoreGraphics
import Testing
@testable import SideWindow

struct GeometryTests {
    let screen = CGRect(x: 0, y: 0, width: 1440, height: 900)

    // MARK: - 拡大範囲

    @Test func selectionMapsToSourceRectWithTopLeftOrigin() {
        // 800×600 のウィンドウを 400×300 で表示中、右上 1/4 を選ぶ（ビューは左下原点）
        let rect = Geometry.sourceRect(for: CGRect(x: 200, y: 150, width: 200, height: 150),
                                       viewSize: CGSize(width: 400, height: 300),
                                       shownArea: CGRect(x: 0, y: 0, width: 800, height: 600),
                                       windowSize: CGSize(width: 800, height: 600))
        #expect(rect == CGRect(x: 400, y: 0, width: 400, height: 300))
    }

    @Test func selectionInsideZoomedAreaIsRelativeToThatArea() {
        let rect = Geometry.sourceRect(for: CGRect(x: 0, y: 0, width: 100, height: 100),
                                       viewSize: CGSize(width: 200, height: 200),
                                       shownArea: CGRect(x: 100, y: 50, width: 400, height: 400),
                                       windowSize: CGSize(width: 800, height: 600))
        // 左下 1/4 → 範囲の左下（上から 200 ずれた位置）
        #expect(rect == CGRect(x: 100, y: 250, width: 200, height: 200))
    }

    @Test func tinySelectionIsRejected() {
        let rect = Geometry.sourceRect(for: CGRect(x: 0, y: 0, width: 2, height: 2),
                                       viewSize: CGSize(width: 400, height: 300),
                                       shownArea: CGRect(x: 0, y: 0, width: 800, height: 600),
                                       windowSize: CGSize(width: 800, height: 600))
        #expect(rect == nil)
    }

    @Test func zoomKeepsPanelFootprintAndCenter() {
        let current = CGRect(x: 900, y: 500, width: 400, height: 300)
        let frame = Geometry.zoomedFrame(current: current, contentAspect: CGSize(width: 200, height: 200), visible: screen)
        // 正方形の範囲は同じ面積の正方形になり、中心は変わらない
        #expect(abs(frame.width - frame.height) < 0.001)
        #expect(abs(frame.width * frame.height - current.width * current.height) < 1)
        #expect(frame.midX == current.midX)
        #expect(frame.midY == current.midY)
    }

    @Test func zoomNearScreenEdgeStaysOnScreen() {
        let current = CGRect(x: 1300, y: 800, width: 400, height: 300)
        let frame = Geometry.zoomedFrame(current: current, contentAspect: CGSize(width: 400, height: 300), visible: screen)
        #expect(screen.contains(frame))
    }

    @Test func showAllRestoresPreviousFullSize() {
        let zoomed = CGRect(x: 100, y: 100, width: 300, height: 300)
        let frame = Geometry.fullFrame(current: zoomed, previousSize: CGSize(width: 480, height: 360),
                                       windowSize: CGSize(width: 800, height: 600), visible: screen)
        #expect(frame.size == CGSize(width: 480, height: 360))
        #expect(frame.midX == zoomed.midX)
        #expect(screen.contains(frame))
    }

    @Test func repeatedZoomDoesNotShrinkPanel() {
        var frame = CGRect(x: 600, y: 400, width: 400, height: 300)
        let area = frame.width * frame.height
        for aspect in [CGSize(width: 1, height: 1), CGSize(width: 16, height: 9), CGSize(width: 3, height: 4), CGSize(width: 4, height: 3)] {
            frame = Geometry.zoomedFrame(current: frame, contentAspect: aspect, visible: screen)
        }
        #expect(abs(frame.width * frame.height - area) < 1)
        #expect(abs(frame.width - 400) < 0.5)
    }

    @Test func captureDensityIsCappedByNativePixelsAndPanel() {
        // パネルが大きい（拡大表示）→ 元の画素数まで
        #expect(Geometry.captureDensity(nativeScale: 2, shownWidth: 80, displayWidth: 800) == 2)
        // パネルが小さい（縮小表示）→ パネルの画素数に合わせる
        #expect(Geometry.captureDensity(nativeScale: 2, shownWidth: 640, displayWidth: 520) == CGFloat(520) / CGFloat(640))
        #expect(Geometry.captureSize(area: CGSize(width: 100, height: 50), density: 1.5) == CGSize(width: 150, height: 75))
    }

    @Test func captureAreaAddsMarginAroundZoomWithinWindow() {
        let window = CGSize(width: 800, height: 600)
        #expect(Geometry.captureArea(for: nil, windowSize: window) == CGRect(origin: .zero, size: window))
        let area = Geometry.captureArea(for: CGRect(x: 400, y: 100, width: 200, height: 100), windowSize: window)
        #expect(area == CGRect(x: 350, y: 75, width: 300, height: 150))
        // 端では窓の外に出ない
        let edge = Geometry.captureArea(for: CGRect(x: 0, y: 0, width: 200, height: 100), windowSize: window)
        #expect(edge == CGRect(x: 0, y: 0, width: 250, height: 125))
    }

    @Test func normalizedCropFindsTargetInsideArea() {
        let area = CGRect(x: 100, y: 100, width: 400, height: 200)
        #expect(Geometry.normalizedCrop(CGRect(x: 200, y: 150, width: 200, height: 100), in: area)
                == CGRect(x: 0.25, y: 0.25, width: 0.5, height: 0.5))
        #expect(Geometry.normalizedCrop(area, in: area) == CGRect(x: 0, y: 0, width: 1, height: 1))
        // 少しはみ出したら内側へずらす
        #expect(Geometry.normalizedCrop(CGRect(x: 350, y: 150, width: 200, height: 100), in: area)
                == CGRect(x: 0.5, y: 0.25, width: 0.5, height: 0.5))
        // 範囲より大きければ切り出せない
        #expect(Geometry.normalizedCrop(CGRect(x: 0, y: 0, width: 800, height: 600), in: area) == nil)
    }

    @Test func panMovesZoomOppositeToScrollAndStaysInWindow() {
        let window = CGSize(width: 800, height: 600)
        let zoom = CGRect(x: 200, y: 200, width: 200, height: 100)
        // パネル幅 400 → 1 ポイントのスクロールで元ウィンドウでは 0.5 ポイント
        let panned = Geometry.panned(zoom, by: CGVector(dx: -40, dy: 20), viewWidth: 400, windowSize: window)
        #expect(panned == CGRect(x: 220, y: 190, width: 200, height: 100))
        let clamped = Geometry.panned(zoom, by: CGVector(dx: 10_000, dy: -10_000), viewWidth: 400, windowSize: window)
        #expect(clamped == CGRect(x: 0, y: 500, width: 200, height: 100))
    }

    @Test func newPanelUsesRememberedPlaceOrTopRight() {
        let content = CGSize(width: 800, height: 400)
        // 覚えている場所がなければ右上
        let fresh = Geometry.placement(for: content, remembered: nil, visible: screen, index: 0)
        #expect(abs(fresh.maxX - (screen.maxX - 16)) < 0.5 && abs(fresh.maxY - (screen.maxY - 16)) < 0.5)
        #expect(fresh.width <= 480)
        // 覚えている場所があれば、同じ中心・同じ面積で新しい縦横比にする
        let remembered = CGRect(x: 100, y: 100, width: 300, height: 300)
        let placed = Geometry.placement(for: content, remembered: remembered, visible: screen, index: 0)
        #expect(abs(placed.midX - remembered.midX) < 0.5 && abs(placed.midY - remembered.midY) < 0.5)
        #expect(abs(placed.width * placed.height - 90_000) < 1)
        #expect(abs(placed.width / placed.height - 2) < 0.001)
        // 2 枚目は少しずらす
        let second = Geometry.placement(for: content, remembered: remembered, visible: screen, index: 1)
        #expect(second.minX < placed.minX && second.minY < placed.minY)
    }

    // MARK: - リサイズ

    @Test func edgesNearBordersAndCorners() {
        let size = CGSize(width: 400, height: 300)
        #expect(Geometry.edges(at: CGPoint(x: 200, y: 150), in: size).isEmpty)
        #expect(Geometry.edges(at: CGPoint(x: 2, y: 150), in: size) == [.left])
        #expect(Geometry.edges(at: CGPoint(x: 398, y: 150), in: size) == [.right])
        #expect(Geometry.edges(at: CGPoint(x: 200, y: 2), in: size) == [.bottom])
        #expect(Geometry.edges(at: CGPoint(x: 200, y: 298), in: size) == [.top])
        // 右下の角は広めにつかめる
        #expect(Geometry.edges(at: CGPoint(x: 398, y: 18), in: size) == [.right, .bottom])
        #expect(Geometry.edges(at: CGPoint(x: 385, y: 3), in: size) == [.right, .bottom])
        // 操作バーのボタンがある高さでは上辺にならない
        #expect(Geometry.edges(at: CGPoint(x: 380, y: 285), in: size).isEmpty)
    }

    @Test func cornerResizeKeepsAspectAndAnchorsOppositeCorner() {
        let start = CGRect(x: 100, y: 100, width: 400, height: 300)
        let frame = Geometry.resized(start, edges: [.right, .bottom], by: CGVector(dx: 80, dy: -10),
                                     aspect: CGSize(width: 4, height: 3), max: screen.size)
        #expect(frame.width == 480)
        #expect(frame.height == 360)
        #expect(frame.minX == start.minX)
        #expect(frame.maxY == start.maxY)
    }

    @Test func leftEdgeResizeAnchorsRightEdge() {
        let start = CGRect(x: 100, y: 100, width: 400, height: 300)
        let frame = Geometry.resized(start, edges: [.left], by: CGVector(dx: 100, dy: 0),
                                     aspect: CGSize(width: 4, height: 3), max: screen.size)
        #expect(frame.width == 300)
        #expect(frame.maxX == start.maxX)
    }

    @Test func topEdgeResizeAnchorsBottomEdge() {
        let start = CGRect(x: 100, y: 100, width: 400, height: 300)
        let frame = Geometry.resized(start, edges: [.top], by: CGVector(dx: 0, dy: 60),
                                     aspect: CGSize(width: 4, height: 3), max: screen.size)
        #expect(frame.height == 360)
        #expect(frame.minY == start.minY)
    }

    @Test func resizeRespectsMinimumAndScreenSize() {
        let start = CGRect(x: 100, y: 100, width: 400, height: 300)
        let aspect = CGSize(width: 4, height: 3)
        let small = Geometry.resized(start, edges: [.right], by: CGVector(dx: -1000, dy: 0), aspect: aspect, max: screen.size)
        #expect(small.width == Geometry.minWidth)
        let big = Geometry.resized(start, edges: [.right], by: CGVector(dx: 5000, dy: 0), aspect: aspect, max: screen.size)
        #expect(big.height == screen.height)
        #expect(abs(big.width / big.height - 4.0 / 3.0) < 0.001)
    }

    @Test func scaleKeepsAnchorPointFixed() {
        let start = CGRect(x: 100, y: 100, width: 400, height: 300)
        let frame = Geometry.scaled(start, by: 1.5, anchor: CGPoint(x: 0.25, y: 0.5),
                                    aspect: CGSize(width: 4, height: 3), max: screen.size)
        #expect(frame.size == CGSize(width: 600, height: 450))
        #expect(frame.minX + frame.width * 0.25 == start.minX + start.width * 0.25)
        #expect(frame.midY == start.midY)
    }

    // MARK: - 移動

    @Test func snapsToScreenEdgesWithGap() {
        let frame = CGRect(x: 1440 - 400 - 12, y: 5, width: 400, height: 300)
        let snapped = Geometry.snapped(frame, to: screen)
        #expect(snapped.maxX == CGFloat(1432))
        #expect(snapped.minY == CGFloat(8))
    }

    @Test func doesNotSnapAwayFromEdges() {
        let frame = CGRect(x: 500, y: 300, width: 400, height: 300)
        #expect(Geometry.snapped(frame, to: screen) == frame)
    }
}
