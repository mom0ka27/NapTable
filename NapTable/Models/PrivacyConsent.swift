import Combine
import Foundation

nonisolated enum PrivacyPolicy {
    /// 协议的一节。小标题和正文成对写在一起，页面只管排版，数量不会对不上。
    struct Clause: Equatable {
        let title: String
        let body: String
    }
    static let version = 1
    /// 协议页头显示的日期。改正文时一并更新；收集范围或用途有实质变化时还要提升 `version`，请所有人重新同意。
    static let updatedAt = "2026.10.07"
    static let basicKey = "naptable.privacy.basic.version"
    static let liveKey = "naptable.privacy.live.version"
    static let onboardingKey = "naptable.onboarding.imported"
    static func basicAllowed(_ defaults: UserDefaults = .standard) -> Bool {
        defaults.integer(forKey: basicKey) == version
    }
    static func liveAllowed(_ defaults: UserDefaults = .standard) -> Bool {
        basicAllowed(defaults) && defaults.integer(forKey: liveKey) == version
    }
    static let basicTitle = "基础使用统计与隐私协议"
    static let basicClauses = [
        Clause(title: "我们收集哪些信息", body: "使用本 App 前，请阅读并同意本协议。继续使用需同意上传：当前课表关联的学校标识、系统名称与版本、设备型号标识、App 版本、随机生成的安装标识和本协议版本。服务端同时记录首次与最近上报时间。"),
        Clause(title: "这些数据用于什么", body: "这些数据用于统计各学校的使用设备数、系统适配和故障排查。安装标识用于去重，不是姓名、手机号、广告标识或设备序列号。标识与凭据保存在仅限本机的钥匙串，不通过 iCloud 同步；同一台设备重装后如能恢复该标识，会沿用原统计记录，重新同意本协议后才会上报。钥匙串被清除或无法恢复时，仍可能被统计为新设备。基础统计和实时活动上传的内容不包含课程名称、教师、教室、学校账号或密码；与你主动生成分享码时的上传不同，那部分见下文。"),
        Clause(title: "主动分享课表", body: "主动生成分享码时（分享界面里的「生成分享码」），这张课表的完整内容会上传到你以为课表服务端，包括课程名称、教师、教室、周次和节次，以及学期第一周、节次时间和调休安排；拿到分享码的人都能查看。分享码可在持有管理凭证的设备上撤销，包括通过 iCloud 同步了凭证的设备。撤销后服务端删除这份分享，朋友无法再获取更新，但已经保存到对方设备上的副本不会被删除。为防止批量发布，服务端还会给每份分享记下发布者的匿名标识（下文的 App Attest 设备密钥，没有时用网络地址，均为哈希值），用来限制每人同时保留的分享数量和发布频率；超过 180 天既没人查看也没更新、也没有设备关心的分享会被自动删除。不生成分享码就不会有这些上传。"),
        Clause(title: "可选的 iCloud 同步", body: "iCloud 同步默认关闭，由你在设置中选择开启。开启后，自己的课表、课程、学期与节次设置、已保存的共享课表及备注、分享管理凭证、关心对象与修改设备名称会保存到 Apple 提供的个人 iCloud 私有数据库，用于同一 Apple 账号下的设备间同步。本机修改上传和设置项同步自动完成，不弹出确认；只有发现远程新增、删除或课程内容更新时，才列出修改内容、时间与来源设备，请你确认是否接收。接收自己的课表可选择更新对应课表、替换当前课表或新建课表。实时活动开关、提前显示时间、分节计时、系统权限、实时活动隐私许可和显示偏好由本机保存，不参与同步。关闭同步会停止后续同步，但保留本机及云端已有数据；本机删除自动上传，远程删除须确认后才影响本机课表。App 不单独保存学校账号和密码，也不会将它们纳入同步；学校网页的 Cookie、缓存及登录会话保留在本机，以便下次导入。"),
        Clause(title: "可选的图片导入", body: "图片导入为可选功能。你选择课表图片并单独同意上传后，App 会将压缩且去除元数据的图片发送至你以为课表服务端，再由服务端配置的 AI 服务（OpenAI 或兼容服务）识别课程。请先裁掉姓名、学号等无关内容；识别结果需要你核对后才保存为本机课表。你以为课表服务端不保存图片或识别课程，只保存调用时间、匿名设备及网络地址哈希、模型、调用结果、课程条数、耗时、token 用量与脱敏错误摘要，用于限额、使用统计和故障排查，数据库记录保留 90 天并在后续调用或统计查询时清理。AI 服务的数据保留规则由其提供方决定；使用 OpenAI Responses 时服务端设置 store=false，这不等于第三方完全不保留数据。不使用图片导入则不会上传这些图片。"),
        Clause(title: "App Attest 请求验证", body: "发布分享、图片导入、开启实时活动和上报基础统计时，App 会使用 Apple 的 App Attest 证明请求来自正版 App 而不是脚本：App 在本机安全芯片里生成一把随机密钥，服务端只保存它的标识和公钥，并按天统计校验结果，不包含个人信息。"),
        Clause(title: "何时上报与保存多久", body: "统计在同意后于打开 App、回到前台或当前学校变化时自动上报，通过 HTTPS 发送至你以为课表服务端。学校归属以当前选中的课表为准；没有关联学校时计为未关联设备。后台以近 30 天上报设备为使用人数，每个随机安装标识只计一次，并展示汇总的系统版本和设备型号；每日打开人数只保存当天的设备总数，不记录单台设备在哪些日期使用。原始统计记录保留至最后上报后 90 天，在下一次统计写入或查询时清理；数据库运维备份保留最近 14 份，随新备份轮换。网络请求也可能产生包含 IP 地址的服务器访问日志。"),
        Clause(title: "你的选择", body: "不同意则无法进入 App 主界面，也不会上报上述基础统计。停止使用后不再上报，已有统计记录按上述期限清理。课表导入时，你会连接学校登录页面；账号和密码在学校页面中输入，不上传至本 App 的统计接口。"),
    ]
    static let liveTitle = "实时活动信息上传许可"
    static let liveClauses = [
        Clause(title: "由你决定是否开启", body: "此项为可选许可，不影响导入和查看课表。启用实时活动前，需要同意将实现该功能所需的部分信息发送至你以为课表服务端及 Apple 推送服务。"),
        Clause(title: "需要哪些信息", body: "信息包括随机设备标识、推送令牌、学校标识、课表范围标识，以及当前课表的时间结构：节次时间、学期第一周与周数、调休日期，每门课的星期、起止节次、周次和随机课程编号，以及提前提醒、分节计时等设置。上传内容不包含课程名称、教师姓名、教室或学校账号密码；这些展示内容由手机本地课表生成（唯一的例外是你主动生成分享码时上传的整张课表，正文见基础协议）。关心共享课表时，还会上传所关心分享的分享码：服务端据此记录本设备关心了哪份分享，并在分享更新时自动重新安排；这时的推送可能带有该共享课表的课程名称、教师和教室，这些内容本来就由分享者发布在服务端。"),
        Clause(title: "不同系统如何处理", body: "服务端据此计算每节课的提醒时间并发送通知，不打开 App 也能按时提醒；iOS 26 及以上还会在本机预约最近几节。信息仅用于同步、安排和排查实时活动，不用于基础使用人数统计。"),
        Clause(title: "Beta 与试用权益", body: "服务端启用 Beta 免费模式时，实时活动可免费使用，无需开始试用或通过 Apple App Store 购买，也不会消耗 30 天试用。Beta 免费模式结束后，实时活动提供一次 30 天免费试用，试用在你首次确认试用时开始，到期不会自动扣款；试用结束后可通过 Apple App Store 一次买断并永久解锁。买断交易属于你的 Apple 账号，可在其他设备恢复；退款或撤销后，服务端会停止后续实时活动安排。"),
        Clause(title: "如何撤回许可", body: "你可以先不允许，之后开启实时活动时再决定。在“设置 → 隐私与数据”中可撤回此项许可；撤回会关闭实时活动，清除服务端当前设备的推送令牌、上传的课表和关心关系。离线时会在恢复连接后重试清除；已经提交给 Apple 的通知可能仍送达。服务端可能保留不含推送令牌和课表的撤销、发送及备份记录，用于防止重复发送和排查问题。"),
    ]
}

@MainActor final class PrivacyConsent: ObservableObject {
    static let shared = PrivacyConsent()
    private let defaults: UserDefaults
    @Published private(set) var basicAccepted: Bool
    @Published private(set) var liveAccepted: Bool
    @Published private(set) var onboardingCompleted: Bool

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        basicAccepted = PrivacyPolicy.basicAllowed(defaults)
        liveAccepted = PrivacyPolicy.liveAllowed(defaults)
        onboardingCompleted = defaults.bool(forKey: PrivacyPolicy.onboardingKey)
    }
    func acceptBasic(liveActivities: Bool) {
        defaults.set(PrivacyPolicy.version, forKey: PrivacyPolicy.basicKey)
        defaults.set(Date(), forKey: "naptable.privacy.basic.acceptedAt")
        basicAccepted = true
        setLiveConsent(liveActivities)
    }
    func setLiveConsent(_ accepted: Bool) {
        let allowed = accepted && basicAccepted
        defaults.set(allowed ? PrivacyPolicy.version : 0, forKey: PrivacyPolicy.liveKey)
        defaults.set(Date(), forKey: "naptable.privacy.live.updatedAt")
        liveAccepted = allowed
    }
    func completeOnboarding(hasImportedCourses: Bool) {
        guard basicAccepted, hasImportedCourses else { return }
        defaults.set(true, forKey: PrivacyPolicy.onboardingKey)
        onboardingCompleted = true
    }
}
