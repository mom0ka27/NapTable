import Combine
import Foundation

nonisolated enum PrivacyPolicy {
    static let version = 1
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
    static let basicText = """
    使用 你以为课表 前，请阅读并同意本协议。继续使用需允许上传：当前课表关联的学校标识、系统名称与版本、设备型号标识、App 版本、随机生成的安装标识和本协议版本。服务端同时记录首次与最近上报时间。

    这些数据用于统计各学校的使用设备数、系统适配和故障排查。安装标识用于去重，不是姓名、手机号、广告标识或设备序列号；重装 App 可能被统计为新设备。基础统计和实时通知上传的内容不包含课程名称、教师、教室、学校账号或密码；与你主动生成分享码时的上传不同，那部分见下文。

    主动生成分享码时（分享界面里的「生成分享码」），这张课表的完整内容会上传到 你以为课表 服务端，包括课程名称、教师、教室、周次和节次，以及学期第一周、节次时间和调休安排；拿到分享码的人都能查看。分享码可在持有管理凭证的设备上撤销，包括通过 iCloud 同步了凭证的设备。撤销后服务端删除这份分享，朋友无法再获取更新，但已经保存到对方设备上的副本不会被删除。为防止批量发布，服务端还会给每份分享记下发布者的匿名标识（下文的 App Attest 设备密钥，没有时用网络地址，均为哈希值），用来限制每人同时保留的分享数量和发布频率；超过 180 天既没人查看也没更新、也没有设备关心的分享会被自动删除。不生成分享码就不会有这些上传。

    iCloud 同步默认关闭，由你在设置中选择开启。开启后，自己的课表、课程、学期与节次设置、已保存的共享课表及备注、分享管理凭证会上传至 Apple 提供的个人 iCloud 私有数据库，用于同一 Apple 账号下的设备间同步。学校账号和密码、设备通知设置与显示偏好不会上传至该数据库。关闭同步会停止后续同步，但保留本机及云端已有数据；删除记录会在同步开启时传播到其他设备。

    发布分享、开启实时通知和上报基础统计时，App 会使用 Apple 的 App Attest 证明请求来自正版 App 而不是脚本：App 在本机安全芯片里生成一把随机密钥，服务端只保存它的标识和公钥，并按天统计校验结果，不包含个人信息。

    统计在同意后于打开 App、回到前台或当前学校变化时自动上报，通过 HTTPS 发送至 你以为课表 服务端。学校归属以当前选中的课表为准；没有关联学校时计为未关联设备。后台以近 30 天上报设备为使用人数，每台安装只计一次，并展示汇总的系统版本和设备型号；每日打开人数只保存当天的设备总数，不记录单台设备在哪些日期使用。原始统计记录保留至最后上报后 90 天，在下一次统计写入或查询时清理；数据库运维备份保留最近 14 份，随新备份轮换。网络请求也可能产生包含 IP 地址的服务器访问日志。

    不同意则无法进入 App 主界面，也不会上报上述基础统计。停止使用后不再上报，已有统计记录按上述期限清理。课表导入时，你会连接学校登录页面；账号和密码在学校页面中输入，不上传至 你以为课表 统计接口。
    """
    static let liveTitle = "实时通知信息上传许可"
    static let liveText = """
    此项为可选许可，不影响导入和查看课表。启用实时通知前，需要同意将实现该功能所需的部分信息发送至 你以为课表 服务端及 Apple 推送服务。

    信息包括随机设备标识、推送令牌、学校标识、课表范围标识，以及当前课表的时间结构：节次时间、学期第一周与周数、调休日期，每门课的星期、起止节次、周次和随机课程编号，以及提前提醒、分节计时等设置。上传内容不包含课程名称、教师姓名、教室或学校账号密码；这些展示内容由手机本地课表生成（唯一的例外是你主动生成分享码时上传的整张课表，正文见基础协议）。关心共享课表时，还会上传所关心分享的分享码：服务端据此记录本设备关心了哪份分享，并在分享更新时自动重新安排；这时的推送可能带有该共享课表的课程名称、教师和教室，这些内容本来就由分享者发布在服务端。

    服务端据此计算每节课的提醒时间并发送通知，不打开 App 也能按时提醒；iOS 26 及以上还会在本机预约最近几节。信息仅用于同步、安排和排查实时通知，不用于基础使用人数统计。

    服务端启用 Beta 免费模式时，实时活动可免费使用，无需开始试用或通过 Apple App Store 购买，也不会消耗 30 天试用。Beta 免费模式结束后，实时活动提供一次 30 天免费试用，试用在你首次确认试用时开始，到期不会自动扣款；试用结束后可通过 Apple App Store 一次买断并永久解锁。买断交易属于你的 Apple 账号，可在其他设备恢复；退款或撤销后，服务端会停止后续实时活动安排。

    你可以先不允许，之后开启实时通知时再决定。在“设置 → 隐私与数据”中可撤回此项许可；撤回会关闭实时通知，清除服务端当前设备的推送令牌、上传的课表和关心关系。离线时会在恢复连接后重试清除；已经提交给 Apple 的通知可能仍送达。服务端可能保留不含推送令牌和课表的撤销、发送及备份记录，用于防止重复发送和排查问题。
    """
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
