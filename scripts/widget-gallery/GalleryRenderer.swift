import SwiftUI
import UIKit
import WidgetKit

enum GalleryRenderer {
    struct Output {
        let png: Data
        let pointSize: CGSize
    }

    enum Failure: LocalizedError {
        case render
        var errorDescription: String? { "渲染失败" }
    }

    /// 把任务里的全局设置写进 App Group 的 UserDefaults，走和小组件一样的读取与解码。
    static func applySettings(_ job: GalleryJob) {
        let defaults = UserDefaults(suiteName: NextWidgetConfiguration.appGroup) ?? .standard
        defaults.set(job.theme ?? "bunny", forKey: NextWidgetConfiguration.globalThemeKey)
        if let rgb = GalleryRGB(hex: job.customColor) {
            let value = ScheduleLiveActivityRGB(red: rgb.red, green: rgb.green, blue: rgb.blue)
            defaults.set(try? JSONEncoder().encode(value), forKey: NextWidgetConfiguration.globalCustomColorKey)
        } else {
            defaults.removeObject(forKey: NextWidgetConfiguration.globalCustomColorKey)
        }
        defaults.set(job.solid ?? false, forKey: NextWidgetConfiguration.solidCourseColorsKey)
        let flags = job.display ?? [:]
        let options = ScheduleWidgetDisplayOptions(
            showCourseName: flags["showCourseName"] ?? true,
            showRoom: flags["showRoom"] ?? true,
            showTeacher: flags["showTeacher"] ?? true,
            showTime: flags["showTime"] ?? true,
            showLunarDate: flags["showLunarDate"] ?? true,
            showHoliday: flags["showHoliday"] ?? true,
            holidayAlwaysVisible: flags["holidayAlwaysVisible"] ?? true
        )
        defaults.set(try? JSONEncoder().encode(options), forKey: NextWidgetConfiguration.widgetDisplayOptionsKey)
        defaults.set(job.persistent ?? false, forKey: NextWidgetConfiguration.liveActivityPersistentKey)
    }

    static func payload(for job: GalleryJob, now: Date) -> WidgetSchedulePayload {
        job.payload ?? GalleryPayload.make(job: job, now: now)
    }

    static func render(_ job: GalleryJob) throws -> Output {
        applySettings(job)
        let now = GalleryTime.instant(date: job.date, time: job.time)
        WidgetClock.override = now
        let payload = payload(for: job, now: now)
        ChineseCalendarInfo.usePublishedHolidays(payload.holidays ?? [])

        let device = GalleryDevice.named(job.device)
        let scheme: ColorScheme = job.scheme == "dark" ? .dark : .light
        let (view, size) = job.isActivity
            ? activityView(job: job, payload: payload, now: now, device: device, scheme: scheme)
            : widgetView(job: job, payload: payload, now: now, device: device, scheme: scheme)

        let backdrop = Color(galleryHex: job.backdrop) ?? .clear
        let renderer = ImageRenderer(
            content: view.environment(\.colorScheme, scheme).frame(width: size.width, height: size.height).background(backdrop)
        )
        renderer.scale = CGFloat(job.scale ?? Double(device.scale))
        renderer.proposedSize = ProposedViewSize(size)
        renderer.isOpaque = false
        // 刚启动时第一次渲染偶尔拿不到图（字体还没加载好），再试一次。
        guard let image = renderer.uiImage ?? renderer.uiImage, let png = image.pngData() else { throw Failure.render }
        return Output(png: png, pointSize: size)
    }

    // MARK: 小组件

    private static func widgetView(
        job: GalleryJob,
        payload: WidgetSchedulePayload,
        now: Date,
        device: GalleryDevice,
        scheme: ColorScheme
    ) -> (AnyView, CGSize) {
        let family = GalleryCatalog.family(job.family)
        let kind = WidgetGalleryViews.Kind(rawValue: job.kind ?? "") ?? .upcoming
        let state: ScheduleEntryState
        switch job.state {
        case "unconfigured": state = .unconfigured
        case "failed": state = .failed("课表数据解码失败，请重新打开 App 同步。")
        default: state = .loaded(payload)
        }
        let configuration = ScheduleWidgetConfiguration(
            afterClass: ScheduleWidgetAfterClassStyle(rawValue: job.afterClass ?? "") ?? .nextCourseDay,
            upcomingCourseCount: job.courseCount == 2 ? 2 : 1,
            layout: ScheduleWidgetLayoutStyle(rawValue: job.layout ?? "") ?? (kind == .twoday ? .list : .timeline)
        )
        let entry = ScheduleEntry(date: now, state: state, configuration: configuration, celebrating: job.celebrating ?? false)
        let size = device.size(for: family)
        let isAccessory = family == .accessoryInline || family == .accessoryCircular || family == .accessoryRectangular
        // 锁屏小组件默认是半透明（vibrant），桌面默认全彩。
        let mode = job.renderingMode ?? (isAccessory ? "vibrant" : "fullColor")
        let content = WidgetGalleryViews.widget(kind: kind, family: family, entry: entry)
            .environment(\.widgetRenderingMode, renderingMode(mode))
            .environment(\.scheduleWidgetFireworksPreviewTime, job.fireworksTime)

        if isAccessory {
            // 锁屏上的内容一律按深色画（壁纸之上是白字），再按渲染模式处理颜色。
            let accessory = AnyView(
                ZStack {
                    if family == .accessoryCircular {
                        // 系统的 AccessoryWidgetBackground 在 App 里画不出来，补一个半透明圆底。
                        Circle().fill(Color.white.opacity(mode == "fullColor" ? 0.18 : 0.22))
                    }
                    content.environment(\.colorScheme, .dark)
                        .frame(width: size.width, height: size.height, alignment: family == .accessoryInline ? .leading : .center)
                }
                .environment(\.colorScheme, .dark)
            )
            return (styled(accessory, mode: mode, tint: nil, size: size), size)
        }

        let tint = Color(galleryHex: job.tint)
        let widget = AnyView(
            content
                .padding(16)
                .frame(width: size.width, height: size.height)
        )
        let body: AnyView
        if mode == "fullColor" {
            body = AnyView(widget.background(WidgetGalleryViews.widgetBackground(for: scheme)))
        } else {
            // 染色桌面：底是压暗的玻璃，内容整体换成浅色，按原来的不透明度保留层次。
            let glass = (tint ?? Color(red: 0.36, green: 0.42, blue: 0.55)).opacity(scheme == .dark ? 0.35 : 0.55)
            body = AnyView(
                styled(widget, mode: mode, tint: tint, size: size)
                    .background(Color.black.opacity(0.55))
                    .background(glass)
            )
        }
        return (AnyView(body.clipShape(RoundedRectangle(cornerRadius: device.cornerRadius, style: .continuous))), size)
    }

    private static func renderingMode(_ name: String) -> WidgetRenderingMode {
        switch name {
        case "accented": return .accented
        case "vibrant": return .vibrant
        default: return .fullColor
        }
    }

    /// 非全彩模式：系统把颜色去掉，只按亮度（vibrant）或不透明度（accented）留下层次。
    private static func styled(_ view: AnyView, mode: String, tint: Color?, size: CGSize) -> AnyView {
        switch mode {
        case "vibrant":
            // 锁屏内容按深色画，本来就是白字灰字；去掉颜色，亮度层次留着。
            return AnyView(view.grayscale(1).compositingGroup())
        case "accented":
            let foreground = tint.map { Color.white.mix(with: $0, by: 0.25) } ?? Color.white
            return AnyView(
                Rectangle().fill(foreground)
                    .frame(width: size.width, height: size.height)
                    .mask { view }
            )
        default:
            return view
        }
    }

    // MARK: 实时活动

    private static func activityView(
        job: GalleryJob,
        payload: WidgetSchedulePayload,
        now: Date,
        device: GalleryDevice,
        scheme: ColorScheme
    ) -> (AnyView, CGSize) {
        let resolved = GalleryActivity.resolve(payload: payload, job: job, now: now)
        func part(_ value: WidgetGalleryViews.ActivityPart) -> AnyView {
            WidgetGalleryViews.liveActivity(value, state: resolved.state, attributes: resolved.attributes, isStale: resolved.isStale)
        }
        let width = device.activityWidth

        switch job.activity {
        case "watch":
            let size = CGSize(width: 176, height: 92)
            return (AnyView(
                part(.watch)
                    .frame(width: size.width, height: size.height)
                    .background(WidgetGalleryViews.activitySurface)
                    .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
                    .environment(\.colorScheme, .dark)
            ), size)

        case "islandCompact":
            // 灵动岛紧凑态：左右两块夹着中间的摄像头区。尺寸按 HIG 的 430pt 屏幕推算。
            let camera: CGFloat = 125
            let height: CGFloat = 36.67
            let size = CGSize(width: camera + 2 * 62, height: height)
            return (AnyView(
                HStack(spacing: 0) {
                    part(.compactLeading).frame(width: 62, height: height).padding(.leading, 6)
                    Spacer(minLength: 0)
                    part(.compactTrailing).frame(width: 62, height: height, alignment: .trailing).padding(.trailing, 12)
                }
                .frame(width: size.width, height: size.height)
                .background(Capsule().fill(Color.black))
                .environment(\.colorScheme, .dark)
            ), size)

        case "islandMinimal":
            let size = CGSize(width: 36.67, height: 36.67)
            return (AnyView(
                part(.minimal)
                    .frame(width: size.width, height: size.height)
                    .background(Circle().fill(Color.black))
                    .environment(\.colorScheme, .dark)
            ), size)

        case "islandExpanded":
            // 展开态：上面一行左右两块避开摄像头，下面整行。系统边距是经验值。
            let content = VStack(spacing: 0) {
                HStack(alignment: .top, spacing: 0) {
                    part(.islandLeading).frame(maxWidth: .infinity, alignment: .leading)
                    Color.clear.frame(width: 125, height: 1)
                    part(.islandTrailing).frame(maxWidth: .infinity, alignment: .trailing)
                }
                .padding(.top, 14)
                part(.islandBottom)
            }
            .padding(.horizontal, 18)
            .padding(.bottom, 10)
            .frame(width: width)
            let height = min(160, measuredHeight(content, width: width))
            let size = CGSize(width: width, height: max(height, 84))
            return (AnyView(
                ZStack(alignment: .top) {
                    RoundedRectangle(cornerRadius: 44, style: .continuous).fill(Color.black)
                    content
                    // 摄像头的位置，只是参考线。
                    Capsule().stroke(Color.white.opacity(0.12), lineWidth: 1)
                        .frame(width: 125, height: 36.67)
                        .padding(.top, 11)
                }
                .frame(width: size.width, height: size.height, alignment: .top)
                .clipShape(RoundedRectangle(cornerRadius: 44, style: .continuous))
                .environment(\.colorScheme, .dark)
            ), size)

        default:
            // 锁屏卡片：系统给的是一层随深浅色变化的磨砂底，最高 160pt。
            let card = part(.lockScreen).frame(width: width)
            let height = min(160, measuredHeight(card, width: width, scheme: scheme))
            let size = CGSize(width: width, height: height)
            let background = scheme == .dark ? Color(white: 0.08).opacity(0.86) : Color(white: 0.97).opacity(0.9)
            return (AnyView(
                card
                    .frame(width: size.width, height: size.height)
                    .background(background)
                    .clipShape(RoundedRectangle(cornerRadius: 24, style: .continuous))
            ), size)
        }
    }

    private static func measuredHeight<V: View>(_ view: V, width: CGFloat, scheme: ColorScheme = .dark) -> CGFloat {
        let controller = UIHostingController(rootView: view.environment(\.colorScheme, scheme))
        let size = controller.sizeThatFits(in: CGSize(width: width, height: 1000))
        return ceil(size.height)
    }
}
