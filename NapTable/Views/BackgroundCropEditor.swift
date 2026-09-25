import ImageIO
import SwiftUI
import UniformTypeIdentifiers

/// 选完背景图后先到这里摆好位置和大小，再按课表页的比例裁出来保存。
///
/// 课表页用 `scaledToFill` 铺满全屏，所以只要裁出来的图和屏幕同比例，这里
/// 看到的就是课表页上的样子。预览叠了一层示意格子，并按不透明度混合，
/// 方便判断图放上去之后课表还看不看得清。
///
/// 改动实时生效，没有「保存」这一步：不透明度直接绑在设置上，位置和大小
/// 每次松手后稍等一下就重新裁一张写进去。设置里是推进导航栈的一页，返回就是
/// 完成；本身不带 `NavigationStack`，需要弹出来用时由调用方包一层并传 `onDone`。
struct BackgroundCropEditor: View {
    let image: CGImage
    var initialPlacement = NativeSchedulePreferences.BackgroundPlacement()
    /// 两种外观的不透明度，拖动时直接改到设置里。
    @Binding var opacity: Opacity
    /// 打开时预览哪种外观；nil 跟随系统。
    var initialPreviewDark: Bool? = nil
    /// 两种外观各有一张图时，这张图只属于一种外观：预览锁定在它上面，
    /// 也只调它的不透明度。两种外观共用一张图时可以来回切换。
    var locksPreviewAppearance = false
    /// 刚从相册选的图：一进来就按默认摆放存一次，课表立刻换上它。
    var commitsOnAppear = false
    var onDone: (() -> Void)?
    /// 摆放有变化时调用，写入裁好的图；写失败时抛错。
    let onCommit: (_ jpeg: Data, _ placement: NativeSchedulePreferences.BackgroundPlacement) throws -> Void

    /// 浅色、深色各一个不透明度。
    struct Opacity: Equatable {
        var light: Double
        var dark: Double
    }

    @Environment(\.colorScheme) private var systemScheme

    @State private var scale: CGFloat = 1
    /// 以画框宽度为单位的偏移，预览画框和保存时的画框大小不同也能直接复用。
    @State private var offset: CGSize = .zero
    @State private var gestureScale: CGFloat = 1
    @State private var dragTranslation: CGSize = .zero
    @State private var adjusting = false
    /// 预览按哪种外观画。滑块调的也是这种外观的不透明度。
    @State private var previewDark = false
    @State private var failed = false
    /// 等着写入的那次裁剪。连续调整时只保留最后一次。
    @State private var pendingCommit: Task<Void, Never>?
    @State private var hasUncommittedChanges = false
    /// `onAppear` 可能不止来一次，初始摆放和首次写入只做一回，免得把调好的位置冲掉。
    @State private var didAppear = false

    static let maxScale: CGFloat = 4

    var body: some View {
        VStack(spacing: 16) {
            GeometryReader { proxy in
                canvas(area: proxy.size)
            }
            .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
            controls
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 12)
        .background(Color.appGroupedBackground.ignoresSafeArea())
        .navigationTitle(locksPreviewAppearance ? (previewDark ? "调整深色背景" : "调整浅色背景") : "调整背景")
        .appInlineNavigationTitle()
        #if os(iOS)
        // 预览要尽量高，这一页用不上底部的 Tab 栏。
        .toolbar(.hidden, for: .tabBar)
        #endif
        .toolbar {
            if let onDone {
                ToolbarItem(placement: .confirmationAction) {
                    Button("完成") {
                        commitNow()
                        onDone()
                    }
                }
            }
        }
        .alert("背景图片", isPresented: $failed) {
            Button("知道了", role: .cancel) {}
        } message: {
            Text("调整未能保存，请重试或更换图片。")
        }
        // 返回时还没轮到的那次裁剪马上写掉，不丢最后一下调整。
        .onDisappear { commitNow() }
        .onAppear {
            guard !didAppear else { return }
            didAppear = true
            previewDark = initialPreviewDark ?? (systemScheme == .dark)
            scale = min(Self.maxScale, max(1, initialPlacement.scale))
            offset = CGSize(width: initialPlacement.offsetX, height: initialPlacement.offsetY)
            if commitsOnAppear {
                hasUncommittedChanges = true
                commitNow()
            }
        }
    }

    /// 画框四周留白，框外露出原图被裁掉的部分并压暗，一眼就知道哪些会被裁掉。
    private func canvas(area: CGSize) -> some View {
        let frame = Self.fit(Self.targetAspect, in: CGSize(width: area.width * 0.78, height: area.height * 0.9))
        let liveScale = min(Self.maxScale, max(1, scale * gestureScale))
        let liveOffset = Self.clamp(
            CGSize(width: offset.width + dragTranslation.width / max(frame.width, 1),
                   height: offset.height + dragTranslation.height / max(frame.width, 1)),
            image: image, frame: frame, scale: liveScale
        )
        let shape = RoundedRectangle(cornerRadius: 22, style: .continuous)
        return ZStack {
            // 框外：整张图，盖一层暗色，框的位置挖空。
            BackgroundCropLayer(image: image, frame: frame, scale: liveScale, offset: liveOffset)
            Color.black.opacity(0.55)
                .mask {
                    Rectangle()
                        .overlay { shape.frame(width: frame.width, height: frame.height).blendMode(.destinationOut) }
                        .compositingGroup()
                }

            // 框内：课表页上真实的样子。拖动和缩放时图片先按原样显示、示意课表
            // 藏起来，框里框外连成一张图，好对准位置。
            ZStack {
                Color.appGroupedBackground
                BackgroundCropLayer(image: image, frame: frame, scale: liveScale, offset: liveOffset)
                    .opacity(adjusting ? 1 : currentOpacity.wrappedValue)
                TimetableSilhouette()
                    .opacity(adjusting ? 0 : 1)
                    .allowsHitTesting(false)
            }
            // 只有框里是「课表页的样子」，按选中的外观画；框外的压暗层不跟着变。
            .environment(\.colorScheme, previewDark ? .dark : .light)
            .environment(\.scheduleHasBackgroundImage, true)
            .frame(width: frame.width, height: frame.height)
            .clipShape(shape)
            .animation(.easeOut(duration: 0.15), value: adjusting)

            shape
                .strokeBorder(.white, lineWidth: 2)
                .frame(width: frame.width, height: frame.height)
                .shadow(color: .black.opacity(0.35), radius: 3)
                .allowsHitTesting(false)
        }
        .frame(width: area.width, height: area.height)
        .clipped()
        .contentShape(Rectangle())
        .gesture(
            DragGesture()
                .onChanged {
                    dragTranslation = $0.translation
                    adjusting = true
                }
                .onEnded { value in
                    adjusting = false
                    offset = Self.clamp(
                        CGSize(width: offset.width + value.translation.width / frame.width,
                               height: offset.height + value.translation.height / frame.width),
                        image: image, frame: frame, scale: scale
                    )
                    dragTranslation = .zero
                    scheduleCommit()
                }
                .simultaneously(with: MagnifyGesture()
                    .onChanged {
                        gestureScale = $0.magnification
                        adjusting = true
                    }
                    .onEnded { value in
                        adjusting = false
                        scale = min(Self.maxScale, max(1, scale * value.magnification))
                        gestureScale = 1
                        offset = Self.clamp(offset, image: image, frame: frame, scale: scale)
                        scheduleCommit()
                    })
        )
        .onTapGesture(count: 2) { reset() }
        .onChange(of: scale) { _, value in
            offset = Self.clamp(offset, image: image, frame: frame, scale: value)
        }
        .accessibilityElement()
        .accessibilityLabel("背景预览")
        .accessibilityHint("拖动调整位置，双指缩放调整大小，轻点两下还原")
    }

    private var controls: some View {
        VStack(spacing: 10) {
            HStack {
                Text("大小")
                Slider(value: $scale, in: 1...Self.maxScale) { editing in
                    adjusting = editing
                    if !editing { scheduleCommit() }
                }
                Text("\(Int((scale * 100).rounded()))%")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
                    .frame(width: 44, alignment: .trailing)
            }
            if !locksPreviewAppearance {
                Picker("预览外观", selection: $previewDark) {
                    Text("浅色模式").tag(false)
                    Text("深色模式").tag(true)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
            }
            HStack {
                Text(previewDark ? "深色不透明度" : "浅色不透明度")
                Slider(value: currentOpacity, in: NativeSchedulePreferences.backgroundOpacityRange, step: 0.01)
                Text("\(Int((currentOpacity.wrappedValue * 100).rounded()))%")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
                    .frame(width: 44, alignment: .trailing)
            }
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 2) {
                    Label("白框外的变暗区域将被裁去", systemImage: "crop")
                        .font(.footnote.weight(.medium))
                    Text("拖动调整位置，双指缩放调整大小")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button("还原") { reset() }
                    .font(.footnote)
                    .disabled(scale == 1 && offset == .zero)
            }
        }
    }

    /// 滑块绑定到正在预览的那种外观。
    private var currentOpacity: Binding<Double> {
        previewDark ? $opacity.dark : $opacity.light
    }

    private func reset() {
        withAnimation(.easeOut(duration: 0.2)) {
            scale = 1
            offset = .zero
        }
        scheduleCommit()
    }

    /// 松手后稍等一下再裁：连着拖几下只写最后一次，不会每一下都重新编码 JPEG。
    private func scheduleCommit() {
        hasUncommittedChanges = true
        pendingCommit?.cancel()
        pendingCommit = Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(300))
            guard !Task.isCancelled else { return }
            commitNow()
        }
    }

    @MainActor
    private func commitNow() {
        pendingCommit?.cancel()
        pendingCommit = nil
        guard hasUncommittedChanges else { return }
        hasUncommittedChanges = false
        do {
            guard let data = Self.render(image: image, scale: scale, offset: offset) else { throw CommitError.render }
            try onCommit(data, .init(scale: scale, offsetX: offset.width, offsetY: offset.height))
        } catch {
            failed = true
        }
    }

    private enum CommitError: Error { case render }

    /// 以一个固定尺寸的画框重放同样的摆放，再按原图的清晰度渲染成 JPEG，
    /// 这样裁出来的结果和屏幕上预览所用的画框大小无关。
    @MainActor
    static func render(image: CGImage, scale: CGFloat, offset: CGSize, aspect: CGFloat = targetAspect) -> Data? {
        let frame = CGSize(width: 390, height: 390 / aspect)
        let layer = BackgroundCropLayer(image: image, frame: frame, scale: scale,
                                        offset: clamp(offset, image: image, frame: frame, scale: scale))
            .frame(width: frame.width, height: frame.height)
            .clipped()
        let renderer = ImageRenderer(content: layer)
        // 取画框里实际露出的那部分原图像素数，不放大也不超过 1600 像素宽。
        let visiblePixels = frame.width / (fillScale(image: image, frame: frame) * scale)
        renderer.scale = max(1, min(1600, visiblePixels)) / frame.width
        guard let output = renderer.cgImage else { return nil }
        return jpegData(output)
    }

    // MARK: Geometry

    /// 课表页铺满的区域就是整块屏幕，iPhone 上按屏幕比例裁；Mac 的窗口比例
    /// 不固定，取常见的 16:10。
    static var targetAspect: CGFloat {
        #if os(iOS)
        let bounds = UIScreen.main.bounds
        return bounds.height > 0 ? bounds.width / bounds.height : 9.0 / 19.5
        #else
        return 16.0 / 10.0
        #endif
    }

    static func fit(_ aspect: CGFloat, in size: CGSize) -> CGSize {
        guard size.width > 0, size.height > 0 else { return .zero }
        return size.width / size.height > aspect
            ? CGSize(width: size.height * aspect, height: size.height)
            : CGSize(width: size.width, height: size.width / aspect)
    }

    /// 缩放为 1 时让图片刚好盖满画框。
    static func fillScale(image: CGImage, frame: CGSize) -> CGFloat {
        let width = CGFloat(image.width), height = CGFloat(image.height)
        guard width > 0, height > 0 else { return 1 }
        return max(frame.width / width, frame.height / height)
    }

    /// 偏移不能让图片边缘露进画框里。偏移以画框宽度为单位。
    static func clamp(_ offset: CGSize, image: CGImage, frame: CGSize, scale: CGFloat) -> CGSize {
        guard frame.width > 0 else { return .zero }
        let fill = fillScale(image: image, frame: frame) * scale
        let maxX = max(0, (CGFloat(image.width) * fill - frame.width) / 2) / frame.width
        let maxY = max(0, (CGFloat(image.height) * fill - frame.height) / 2) / frame.width
        return CGSize(width: min(maxX, max(-maxX, offset.width)),
                      height: min(maxY, max(-maxY, offset.height)))
    }

    // MARK: Image IO

    /// 相册原图动辄几千万像素，先缩到长边 3000 像素再编辑；缩略图顺带把
    /// EXIF 方向转正，否则竖拍的照片会横着出现。
    static func decode(_ data: Data) -> CGImage? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: 3000,
        ]
        return CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
    }

    static func jpegData(_ image: CGImage) -> Data? {
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(
            data, UTType.jpeg.identifier as CFString, 1, nil
        ) else { return nil }
        CGImageDestinationAddImage(destination, image, [kCGImageDestinationLossyCompressionQuality: 0.9] as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { return nil }
        return data as Data
    }
}

/// 预览和保存共用的摆放：缩放为 1 时刚好盖满画框，偏移以画框宽度为单位。
struct BackgroundCropLayer: View {
    let image: CGImage
    let frame: CGSize
    let scale: CGFloat
    let offset: CGSize

    var body: some View {
        let fill = BackgroundCropEditor.fillScale(image: image, frame: frame) * scale
        Image(decorative: image, scale: 1)
            .resizable()
            .frame(width: CGFloat(image.width) * fill, height: CGFloat(image.height) * fill)
            .offset(x: offset.width * frame.width, y: offset.height * frame.width)
            .frame(width: frame.width, height: frame.height)
    }
}

/// 示意用的课表轮廓：顶栏胶囊加一张格子，只为判断背景会不会抢了课表。
/// 底色和课表页共用一套（`ScheduleCardSurface`、`scheduleCellSurface`），预览才准。
private struct TimetableSilhouette: View {
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.scheduleHasBackgroundImage) private var hasBackground
    private let columns = 5
    private let rows = 8

    var body: some View {
        GeometryReader { proxy in
            let inset = proxy.size.width * 0.05
            let gap = proxy.size.width * 0.02
            VStack(spacing: gap * 2) {
                HStack(spacing: gap) {
                    Capsule().fill(ScheduleCardSurface(hasBackground: hasBackground))
                        .frame(width: proxy.size.width * 0.42)
                    Spacer(minLength: 0)
                    Capsule().fill(ScheduleCardSurface(hasBackground: hasBackground))
                        .frame(width: proxy.size.width * 0.3)
                }
                .frame(height: proxy.size.width * 0.08)
                .padding(.top, proxy.size.height * 0.07)

                Grid(horizontalSpacing: gap, verticalSpacing: gap) {
                    ForEach(0..<rows, id: \.self) { row in
                        GridRow {
                            ForEach(0..<columns, id: \.self) { column in
                                RoundedRectangle(cornerRadius: gap * 1.4, style: .continuous)
                                    .fill(cellColor(row: row, column: column))
                            }
                        }
                    }
                }
                Spacer(minLength: proxy.size.height * 0.08)
            }
            .padding(.horizontal, inset)
        }
    }

    /// 零星几格上色当作课程卡片，其余是半透明的空格子。
    private func cellColor(row: Int, column: Int) -> Color {
        let hues: [Double] = [0.55, 0.13, 0.36, 0.95, 0.72]
        if (row * 3 + column * 2) % 5 == 0 {
            return Color(hue: hues[(row + column) % hues.count], saturation: 0.35, brightness: 0.97).opacity(0.92)
        }
        return .scheduleCellSurface(hasBackground: hasBackground, dark: colorScheme == .dark)
    }
}
