import SwiftUI
import WidgetKit

/// 小组件预览画廊。只在模拟器里跑，由 `scripts/widget-gallery.sh` 编译安装，
/// 不进正式工程。打开后在 8765 端口提供网页和渲染接口。
@main
struct WidgetGalleryApp: App {
    @State private var status = "启动中…"
    private let server: GalleryServer?

    init() {
        let port = UInt16(ProcessInfo.processInfo.environment["GALLERY_PORT"] ?? "") ?? 8765
        server = try? GalleryServer(port: port, handler: GalleryRoutes.handle)
        server?.start()
        _status = State(initialValue: server == nil ? "端口 \(port) 启动失败" : "http://127.0.0.1:\(port)")
    }

    var body: some Scene {
        WindowGroup {
            VStack(spacing: 12) {
                Image(systemName: "square.grid.2x2")
                    .font(.system(size: 44))
                Text("NapTable 小组件画廊")
                    .font(.headline)
                Text(status)
                    .font(.system(.body, design: .monospaced))
                    .foregroundStyle(.secondary)
                Text("在 Mac 的浏览器里打开上面的地址")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            .padding()
        }
    }
}

enum GalleryRoutes {
    /// 网页从这里读。启动参数 `--web-root <目录>` 指向仓库里的源文件，改网页不用重新编译。
    private static var webRoot: URL? {
        let arguments = ProcessInfo.processInfo.arguments
        if let index = arguments.firstIndex(of: "--web-root"), index + 1 < arguments.count {
            return URL(fileURLWithPath: arguments[index + 1])
        }
        return nil
    }

    static func handle(_ request: GalleryServer.Request) -> GalleryServer.Response {
        switch (request.method, request.path) {
        case ("GET", "/"), ("GET", "/index.html"):
            return file("index.html", type: "text/html; charset=utf-8")
        case ("GET", "/api/meta"):
            return .json(meta)
        case ("GET", "/api/render"), ("POST", "/api/render"):
            return render(request)
        case ("GET", "/api/payload"), ("POST", "/api/payload"):
            guard let job = job(from: request) else { return .text("任务 JSON 解析失败", status: 400) }
            let now = GalleryTime.instant(date: job.date, time: job.time)
            WidgetClock.override = now
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
            let data = (try? encoder.encode(GalleryRenderer.payload(for: job, now: now))) ?? Data()
            return GalleryServer.Response(body: data)
        case ("GET", "/api/activity-state"), ("POST", "/api/activity-state"):
            // 给 --reference 用：按这组设置算出实时活动这一刻的内容，交给正式 App 开一个真的。
            guard let job = job(from: request) else { return .text("任务 JSON 解析失败", status: 400) }
            GalleryRenderer.applySettings(job)
            let now = GalleryTime.instant(date: job.date, time: job.time)
            WidgetClock.override = now
            let resolved = GalleryActivity.resolve(payload: GalleryRenderer.payload(for: job, now: now), job: job, now: now)
            let data = (try? JSONEncoder().encode(resolved.state)) ?? Data()
            return GalleryServer.Response(body: data)
        case ("GET", "/api/health"):
            return .text("ok", status: 200)
        default:
            return .text("没有这个地址：\(request.path)", status: 404)
        }
    }

    private static func job(from request: GalleryServer.Request) -> GalleryJob? {
        var data = request.body
        if data.isEmpty, let encoded = request.query["j"] {
            data = Data(base64URL: encoded) ?? Data(encoded.utf8)
        }
        if data.isEmpty { data = Data("{}".utf8) }
        return try? JSONDecoder().decode(GalleryJob.self, from: data)
    }

    private static func render(_ request: GalleryServer.Request) -> GalleryServer.Response {
        guard let job = job(from: request) else { return .text("任务 JSON 解析失败", status: 400) }
        do {
            let output = try GalleryRenderer.render(job)
            return GalleryServer.Response(
                contentType: "image/png",
                body: output.png,
                headers: [
                    "X-Point-Width": String(format: "%.2f", output.pointSize.width),
                    "X-Point-Height": String(format: "%.2f", output.pointSize.height),
                ]
            )
        } catch {
            return .text(error.localizedDescription, status: 500)
        }
    }

    /// 先读仓库里的源文件（改网页不用重编），读不到就用编译时打进 App 的那份。
    /// 仓库在「文稿」里时模拟器进程可能没有权限读，不能只靠前者。
    private static func file(_ name: String, type: String) -> GalleryServer.Response {
        let candidates = [webRoot?.appendingPathComponent(name), Bundle.main.url(forResource: name, withExtension: nil)]
        for url in candidates.compactMap({ $0 }) {
            if let data = try? Data(contentsOf: url) {
                return GalleryServer.Response(contentType: type, body: data)
            }
        }
        return .text("找不到 \(name)", status: 404)
    }

    // MARK: 网页要的选项

    struct Meta: Encodable {
        struct Item: Encodable {
            let id: String
            let title: String
            var detail: String? = nil
            var color: String? = nil
        }

        let widgets: [GalleryWidgetInfo]
        let activityParts: [Item]
        let families: [Item]
        let devices: [GalleryDevice]
        let scenarios: [Item]
        let themes: [Item]
        let timePresets: [Item]
        let today: String
        /// 默认看的日期：今天，周末就换成下周一，不然一打开全是休息状态。
        let defaultDate: String
    }

    private static var meta: Meta {
        Meta(
            widgets: GalleryCatalog.widgets,
            activityParts: [
                .init(id: "lockScreen", title: "锁屏卡片"),
                .init(id: "islandExpanded", title: "灵动岛 · 展开"),
                .init(id: "islandCompact", title: "灵动岛 · 紧凑"),
                .init(id: "islandMinimal", title: "灵动岛 · 最小"),
                .init(id: "watch", title: "手表智能叠放"),
            ],
            families: [
                .init(id: "systemSmall", title: "小"),
                .init(id: "systemMedium", title: "中"),
                .init(id: "systemLarge", title: "大"),
                .init(id: "accessoryInline", title: "锁屏 · 行内"),
                .init(id: "accessoryCircular", title: "锁屏 · 圆形"),
                .init(id: "accessoryRectangular", title: "锁屏 · 矩形"),
            ],
            devices: GalleryDevice.all,
            scenarios: GalleryScenarios.all.map { .init(id: $0.id, title: $0.title, detail: $0.detail) },
            themes: ScheduleLiveActivityTheme.allCases.map { theme in
                let rgb = theme.brandColor
                return .init(
                    id: theme.rawValue, title: theme.title,
                    color: String(format: "#%02X%02X%02X", Int(rgb.red * 255), Int(rgb.green * 255), Int(rgb.blue * 255))
                )
            },
            timePresets: GalleryTime.presets.map { .init(id: $0.id, title: $0.title, detail: $0.time) },
            today: WidgetSchedulePayload.dateString(Date()),
            defaultDate: WidgetSchedulePayload.dateString(defaultDate)
        )
    }

    private static var defaultDate: Date {
        let calendar = GalleryTime.calendar
        let today = Date()
        switch calendar.component(.weekday, from: today) {
        case 7: return calendar.date(byAdding: .day, value: 2, to: today) ?? today
        case 1: return calendar.date(byAdding: .day, value: 1, to: today) ?? today
        default: return today
        }
    }
}

private extension Data {
    init?(base64URL value: String) {
        var text = value.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        while text.count % 4 != 0 { text += "=" }
        self.init(base64Encoded: text)
    }
}
