import CoreGraphics

/// パネルのどの辺・角をつかんでいるか
struct Edges: OptionSet, Hashable {
    let rawValue: Int
    static let left = Edges(rawValue: 1 << 0)
    static let right = Edges(rawValue: 1 << 1)
    static let top = Edges(rawValue: 1 << 2)
    static let bottom = Edges(rawValue: 1 << 3)

    var isHorizontal: Bool { !intersection([.left, .right]).isEmpty }
    var isVertical: Bool { !intersection([.top, .bottom]).isEmpty }
}

/// パネルの位置・大きさの計算。AppKit の座標系（左下原点）で扱う
enum Geometry {
    static let minWidth: CGFloat = 120
    static let minHeight: CGFloat = 60

    /// 縦横比を保って box に収まる最大の大きさ
    static func fit(_ size: CGSize, in box: CGSize) -> CGSize {
        guard size.width > 0, size.height > 0 else { return box }
        let scale = min(box.width / size.width, box.height / size.height)
        return CGSize(width: size.width * scale, height: size.height * scale)
    }

    /// 縦横比を保ったまま、最小サイズ以上・max 以下に収める
    static func clampSize(_ size: CGSize, aspect: CGSize, max: CGSize) -> CGSize {
        let ratio = aspect.width / Swift.max(aspect.height, 1)
        let minWidth = Swift.max(minWidth, minHeight * ratio)
        let maxWidth = Swift.max(minWidth, Swift.min(max.width, max.height * ratio))
        let width = Swift.min(Swift.max(size.width, minWidth), maxWidth)
        return CGSize(width: width, height: width / ratio)
    }

    /// 画面からはみ出さないよう、大きすぎれば縮めてから内側へずらす
    static func clamp(_ frame: CGRect, aspect: CGSize, into visible: CGRect) -> CGRect {
        let size = clampSize(frame.size, aspect: aspect, max: visible.size)
        var result = CGRect(x: frame.midX - size.width / 2, y: frame.midY - size.height / 2,
                            width: size.width, height: size.height)
        if size == frame.size { result.origin = frame.origin }
        result.origin.x = Swift.min(Swift.max(result.minX, visible.minX), visible.maxX - result.width)
        result.origin.y = Swift.min(Swift.max(result.minY, visible.minY), visible.maxY - result.height)
        return result
    }

    /// パネル上で選んだ範囲（ビュー座標・左下原点）を、元ウィンドウ上の範囲（ポイント・左上原点）に変換する
    static func sourceRect(for selection: CGRect, viewSize: CGSize, shownArea: CGRect, windowSize: CGSize) -> CGRect? {
        guard viewSize.width > 0, viewSize.height > 0 else { return nil }
        let sx = shownArea.width / viewSize.width
        let sy = shownArea.height / viewSize.height
        let rect = CGRect(x: shownArea.minX + selection.minX * sx,
                          y: shownArea.minY + (viewSize.height - selection.maxY) * sy,
                          width: selection.width * sx,
                          height: selection.height * sy)
            .intersection(CGRect(origin: .zero, size: windowSize))
        guard !rect.isNull, rect.width >= 8, rect.height >= 8 else { return nil }
        return rect
    }

    /// 拡大後のパネル枠。今のパネルと同じ中心・同じ面積のまま、選んだ範囲の縦横比にする
    /// （枠に収めるだけだと、拡大や戻すを繰り返すたびにパネルが小さくなっていく）
    static func zoomedFrame(current: CGRect, contentAspect: CGSize, visible: CGRect) -> CGRect {
        let ratio = contentAspect.width / Swift.max(contentAspect.height, 1)
        let width = (current.width * current.height * ratio).squareRoot()
        let size = CGSize(width: width, height: width / ratio)
        let frame = CGRect(x: current.midX - size.width / 2, y: current.midY - size.height / 2,
                           width: size.width, height: size.height)
        return clamp(frame, aspect: contentAspect, into: visible)
    }

    /// 全体表示に戻すときの枠。以前の全体表示の大きさで、今のパネルの中心に置く
    static func fullFrame(current: CGRect, previousSize: CGSize?, windowSize: CGSize, visible: CGRect) -> CGRect {
        let size = previousSize.map { fit(windowSize, in: $0) } ?? fit(windowSize, in: CGSize(width: 520, height: 520))
        let frame = CGRect(x: current.midX - size.width / 2, y: current.midY - size.height / 2,
                           width: size.width, height: size.height)
        return clamp(frame, aspect: windowSize, into: visible)
    }

    /// つかんでいる位置から、どの辺・角のリサイズになるか。空ならパネルの移動
    static func edges(at point: CGPoint, in size: CGSize) -> Edges {
        let margin: CGFloat = 8
        // 上辺は操作バーのボタンと重ならないよう細くする
        let topMargin: CGFloat = 5
        let corner: CGFloat = 22
        var edges: Edges = []
        if point.x < margin { edges.insert(.left) }
        if point.x > size.width - margin { edges.insert(.right) }
        if point.y < margin { edges.insert(.bottom) }
        if point.y > size.height - topMargin { edges.insert(.top) }
        // 角は広めにつかめるようにする（上側は操作バーがあるので広げない）
        if edges.isHorizontal, point.y < corner { edges.insert(.bottom) }
        if edges.isVertical {
            if point.x < corner { edges.insert(.left) }
            if point.x > size.width - corner { edges.insert(.right) }
        }
        return edges
    }

    /// 縦横比を保ってリサイズする。つかんだ辺・角の反対側を固定する
    static func resized(_ start: CGRect, edges: Edges, by delta: CGVector, aspect: CGSize, max: CGSize) -> CGRect {
        let ratio = aspect.width / Swift.max(aspect.height, 1)
        let widthFromX = start.width + (edges.contains(.right) ? delta.dx : edges.contains(.left) ? -delta.dx : 0)
        let widthFromY = (start.height + (edges.contains(.top) ? delta.dy : edges.contains(.bottom) ? -delta.dy : 0)) * ratio
        let width: CGFloat
        if edges.isHorizontal && edges.isVertical {
            // 角：大きく動かした方に合わせる
            width = abs(widthFromX - start.width) >= abs(widthFromY - start.width) ? widthFromX : widthFromY
        } else if edges.isHorizontal {
            width = widthFromX
        } else {
            width = widthFromY
        }
        let size = clampSize(CGSize(width: width, height: width / ratio), aspect: aspect, max: max)
        var frame = CGRect(x: start.minX, y: start.maxY - size.height, width: size.width, height: size.height)
        if edges.contains(.left) { frame.origin.x = start.maxX - size.width }
        if edges.contains(.top) && !edges.contains(.bottom) { frame.origin.y = start.minY }
        return frame
    }

    /// anchor（パネル内の割合 0〜1）を動かさずに拡大縮小する
    static func scaled(_ frame: CGRect, by factor: CGFloat, anchor: CGPoint, aspect: CGSize, max: CGSize) -> CGRect {
        let size = clampSize(CGSize(width: frame.width * factor, height: frame.height * factor), aspect: aspect, max: max)
        let point = CGPoint(x: frame.minX + frame.width * anchor.x, y: frame.minY + frame.height * anchor.y)
        return CGRect(x: point.x - size.width * anchor.x, y: point.y - size.height * anchor.y,
                      width: size.width, height: size.height)
    }

    /// 取り込む範囲。拡大中は周りに余白を付けて取り込み、少しの移動（スクロール）なら取り込み直さずに済ませる
    static func captureArea(for zoom: CGRect?, windowSize: CGSize, margin: CGFloat = 0.25) -> CGRect {
        let whole = CGRect(origin: .zero, size: windowSize)
        guard let zoom else { return whole }
        return zoom.insetBy(dx: -zoom.width * margin, dy: -zoom.height * margin).intersection(whole)
    }

    /// 取り込む細かさ（元ウィンドウの 1 ポイントあたりのピクセル数）。元の画素数が上限（それ以上は細かくならない）。
    /// パネルの方が小さければパネルの画素数に合わせる（画面側で縮めるより文字がきれい）
    static func captureDensity(nativeScale: CGFloat, shownWidth: CGFloat, displayWidth: CGFloat) -> CGFloat {
        guard displayWidth > 0, shownWidth > 0 else { return nativeScale }
        return min(nativeScale, displayWidth / shownWidth)
    }

    static func captureSize(area: CGSize, density: CGFloat) -> CGSize {
        CGSize(width: max(1, (area.width * density).rounded(.up)), height: max(1, (area.height * density).rounded(.up)))
    }

    /// target が area の中のどこにあるか（area に対する割合、左上原点）。
    /// 少しはみ出していれば内側へずらす（スクロールで取り込み直しが追いつくまでのあいだ）。area より大きければ nil
    static func normalizedCrop(_ target: CGRect, in area: CGRect) -> CGRect? {
        guard area.width > 0, area.height > 0,
              target.width <= area.width + 0.5, target.height <= area.height + 0.5 else { return nil }
        var shifted = target
        shifted.origin.x = min(max(target.minX, area.minX), max(area.minX, area.maxX - target.width))
        shifted.origin.y = min(max(target.minY, area.minY), max(area.minY, area.maxY - target.height))
        return CGRect(x: (shifted.minX - area.minX) / area.width, y: (shifted.minY - area.minY) / area.height,
                      width: min(1, shifted.width / area.width), height: min(1, shifted.height / area.height))
    }

    /// 拡大中にスクロールした分だけ、映す範囲を動かす（指の動きに合わせて中身が動く向き）。
    /// delta はパネル上のポイント（AppKit のスクロール量そのまま）、zoom は元ウィンドウ上の範囲（左上原点）
    static func panned(_ zoom: CGRect, by delta: CGVector, viewWidth: CGFloat, windowSize: CGSize) -> CGRect {
        guard viewWidth > 0 else { return zoom }
        let scale = zoom.width / viewWidth
        var result = zoom
        result.origin.x = min(max(zoom.minX - delta.dx * scale, 0), max(0, windowSize.width - zoom.width))
        result.origin.y = min(max(zoom.minY - delta.dy * scale, 0), max(0, windowSize.height - zoom.height))
        return result
    }

    /// 新しいパネルの置き場所。前にユーザーが置いた場所があれば同じ場所・同じくらいの大きさに、
    /// なければ画面の右上に置く。複数あれば少しずつずらす
    static func placement(for contentSize: CGSize, remembered: CGRect?, visible: CGRect, index: Int) -> CGRect {
        let offset = CGFloat(index % 8) * 28
        if let remembered, remembered.intersects(visible), remembered.width > 0, remembered.height > 0 {
            let frame = zoomedFrame(current: remembered, contentAspect: contentSize, visible: visible)
            return clamp(frame.offsetBy(dx: -offset, dy: -offset), aspect: contentSize, into: visible)
        }
        let limit = CGSize(width: min(contentSize.width, 480), height: min(contentSize.height, 480))
        let size = clampSize(fit(contentSize, in: limit), aspect: contentSize, max: visible.size)
        return clamp(CGRect(x: visible.maxX - size.width - 16 - offset, y: visible.maxY - size.height - 16 - offset,
                            width: size.width, height: size.height), aspect: contentSize, into: visible)
    }

    /// 画面の端に近ければ、少し余白をあけて吸い付かせる
    static func snapped(_ frame: CGRect, to visible: CGRect, threshold: CGFloat = 14, gap: CGFloat = 8) -> CGRect {
        let target = visible.insetBy(dx: gap, dy: gap)
        var origin = frame.origin
        if abs(frame.minX - target.minX) < threshold {
            origin.x = target.minX
        } else if abs(frame.maxX - target.maxX) < threshold {
            origin.x = target.maxX - frame.width
        }
        if abs(frame.minY - target.minY) < threshold {
            origin.y = target.minY
        } else if abs(frame.maxY - target.maxY) < threshold {
            origin.y = target.maxY - frame.height
        }
        return CGRect(origin: origin, size: frame.size)
    }
}
