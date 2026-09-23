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

    这些数据用于统计各学校的使用设备数、系统适配和故障排查。安装标识用于去重，不是姓名、手机号、广告标识或设备序列号；重装 App 可能被统计为新设备。基础统计不包含课程名称、教师、教室、学校账号或密码。

    统计在同意后于打开 App、回到前台或当前学校变化时自动上报，通过 HTTPS 发送至 你以为课表 服务端。学校归属以当前选中的课表为准；没有关联学校时计为未关联设备。后台以近 30 天上报设备为使用人数，每台安装只计一次，并展示汇总的系统版本和设备型号。原始统计记录保留至最后上报后 90 天，在下一次统计写入或查询时清理；数据库运维备份保留最近 14 份，随新备份轮换。网络请求也可能产生包含 IP 地址的服务器访问日志。

    不同意则无法进入 App 主界面，也不会上报上述基础统计。停止使用后不再上报，已有统计记录按上述期限清理。课表导入时，你会连接学校登录页面；账号和密码在学校页面中输入，不上传至 你以为课表 统计接口。
    """
    static let liveTitle = "实时通知信息上传许可"
    static let liveText = """
    此项为可选许可，不影响导入和查看课表。启用实时通知前，需要同意将实现该功能所需的部分信息发送至 你以为课表 服务端及 Apple 推送服务。

    信息包括随机设备标识、推送令牌、学校标识、课表范围标识、作息版本，以及需要远程调度时的课程实例标识、上课日期、起止节次和提前提醒设置。上传计划不包含课程名称、教师姓名、教室或学校账号密码；这些展示内容由手机本地课表生成。

    iOS 18 自动上传提醒计划，由服务端安排通知；iOS 26 及以上采用本地预约，仍需注册设备并获取学校作息和通知频道配置，正常情况下不上传完整的远程提醒计划。信息仅用于同步、安排和排查实时通知，不用于基础使用人数统计。

    你可以先不允许，之后开启实时通知时再决定。在“设置 → 隐私与数据”中可撤回此项许可；撤回会关闭实时通知，清除服务端当前设备的推送令牌与计划。离线时会在恢复连接后重试清除；已经提交给 Apple 的通知可能仍送达。服务端可能保留不含推送令牌和完整计划的撤销、调度及备份记录，用于防止重复发送和排查问题。
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
