import AuthenticationServices
import ImageIO
import PhotosUI
import SwiftUI
import UniformTypeIdentifiers

// MARK: - Avatar

/// A round avatar: the photo the user chose, or the first letter of the
/// name on a tinted disc while there is none (or it is still loading).
struct AccountAvatarView: View {
    var url: URL?
    var name: String
    var size: CGFloat = 40

    var body: some View {
        AsyncImage(url: url) { phase in
            if let image = phase.image { image.resizable().scaledToFill() }
            else { placeholder }
        }
        .frame(width: size, height: size)
        .clipShape(Circle())
        .overlay(Circle().strokeBorder(.primary.opacity(0.08), lineWidth: 0.5))
        .accessibilityHidden(true)
    }

    private var placeholder: some View {
        ZStack {
            Circle().fill(Color.accentColor.opacity(0.16))
            if let initial = name.trimmedNonEmpty?.first {
                Text(String(initial)).font(.system(size: size * 0.42, weight: .semibold, design: .rounded))
                    .foregroundStyle(Color.accentColor)
            } else {
                Image(systemName: "person.fill").font(.system(size: size * 0.44)).foregroundStyle(Color.accentColor)
            }
        }
    }
}

enum AvatarImage {
    /// The center square of a photo, at most 256 px, as JPEG: what the service keeps.
    static func jpeg(from data: Data) -> Data? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                  kCGImageSourceCreateThumbnailFromImageAlways: true,
                  kCGImageSourceCreateThumbnailWithTransform: true,
                  kCGImageSourceThumbnailMaxPixelSize: 512,
              ] as CFDictionary) else { return nil }
        let side = min(image.width, image.height)
        guard let square = image.cropping(to: CGRect(x: (image.width - side) / 2, y: (image.height - side) / 2, width: side, height: side)) else { return nil }
        let target = min(side, 256)
        guard let context = CGContext(data: nil, width: target, height: target, bitsPerComponent: 8, bytesPerRow: 0,
                                      space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return nil }
        context.interpolationQuality = .high
        context.draw(square, in: CGRect(x: 0, y: 0, width: target, height: target))
        guard let scaled = context.makeImage() else { return nil }
        let output = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(output, UTType.jpeg.identifier as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(destination, scaled, [kCGImageDestinationLossyCompressionQuality: 0.8] as CFDictionary)
        return CGImageDestinationFinalize(destination) ? output as Data : nil
    }
}

// MARK: - Sign in

/// The system Sign in with Apple button, with the nonce fetched beforehand.
/// `onSignedIn` runs once the server accepted the sign-in.
struct AccountSignInButton: View {
    var onSignedIn: () -> Void = {}
    @ObservedObject private var account = AccountService.shared
    @Environment(\.colorScheme) private var scheme
    @State private var ready = false
    @State private var busy = false
    @State private var message: String?

    var body: some View {
        VStack(spacing: 8) {
            SignInWithAppleButton(.signIn) { request in
                account.configure(request)
            } onCompletion: { result in
                busy = true
                Task {
                    defer { busy = false }
                    do {
                        try await account.completeSignIn(result)
                        message = nil
                        onSignedIn()
                    } catch is CancellationError {
                        await prepare()
                    } catch {
                        message = error.localizedDescription
                        await prepare()
                    }
                }
            }
            .signInWithAppleButtonStyle(scheme == .dark ? .white : .black)
            .frame(height: 50)
            .disabled(!ready || busy)
            .opacity(ready && !busy ? 1 : 0.5)
            .overlay { if busy { ProgressView() } }
            if let message {
                Text(message).font(.caption).foregroundStyle(.red).multilineTextAlignment(.center)
            }
        }
        .task { await prepare() }
    }

    private func prepare() async {
        ready = false
        do { try await account.prepareSignIn(); ready = true }
        catch { message = "无法连接服务，请检查网络后重试。" }
    }
}

/// Why an account is needed, for the onboarding page and the sheet the
/// Live Activity switch opens while signed out.
struct LiveActivitySignInContent: View {
    @Environment(\.colorScheme) private var scheme
    private var colors: OnboardingColors { OnboardingColors(scheme: scheme) }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            LiveActivityPreviewArtwork()
            Text("上课前，锁屏自动提醒。")
                .font(.system(.title, design: .rounded).weight(.bold)).tracking(-0.7)
                .foregroundStyle(colors.ink).fixedSize(horizontal: false, vertical: true)
            Text("实时活动在锁屏和灵动岛上显示下一节课和倒计时，不打开 App 也会按时出现。")
                .font(.subheadline).foregroundStyle(colors.secondary).lineSpacing(3)
                .fixedSize(horizontal: false, vertical: true)
            VStack(alignment: .leading, spacing: 12) {
                point("gift", "新用户免费 30 个使用日", "只有当天真正收到提醒才算一天，放假、没课的日子不计。")
                point("person.crop.circle.badge.checkmark", "通过 Apple 登录", "不需要你的姓名和邮箱；账户用来记录使用日和订阅。")
                point("creditcard", "用完后订阅", "订阅后不限使用日；课表、小组件始终免费。")
            }
            .padding(18)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(colors.surface, in: RoundedRectangle(cornerRadius: 21))
            .overlay(RoundedRectangle(cornerRadius: 21).strokeBorder(colors.line, lineWidth: 1))
        }
    }

    private func point(_ symbol: String, _ title: String, _ detail: String) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: symbol).font(.system(size: 16, weight: .medium)).foregroundStyle(colors.accent)
                .frame(width: 32, height: 32).background(colors.soft, in: RoundedRectangle(cornerRadius: 10))
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 3) {
                Text(title).font(.subheadline.weight(.semibold)).foregroundStyle(colors.ink)
                Text(detail).font(.caption).foregroundStyle(colors.secondary).fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

/// "Signing in agrees to…", with both documents one tap away.
struct AccountConsentNote: View {
    @Environment(\.colorScheme) private var scheme
    private var colors: OnboardingColors { OnboardingColors(scheme: scheme) }

    var body: some View {
        VStack(spacing: 2) {
            Text("登录即表示同意以下两份说明").foregroundStyle(colors.secondary)
            HStack(spacing: 12) {
                NavigationLink("实时通知许可") { PrivacyDocumentView(liveActivities: true) }
                NavigationLink("账户说明") { PrivacyDocumentView(liveActivities: false, account: true) }
            }
            .foregroundStyle(colors.accent)
        }
        .font(.caption2)
        .buttonStyle(.plain)
        .frame(maxWidth: .infinity)
    }
}

/// A lock-screen Live Activity, drawn: the onboarding page's picture.
private struct LiveActivityPreviewArtwork: View {
    @Environment(\.colorScheme) private var scheme
    private var colors: OnboardingColors { OnboardingColors(scheme: scheme) }

    var body: some View {
        VStack(spacing: 10) {
            Text("9:41").font(.system(size: 34, weight: .semibold, design: .rounded)).foregroundStyle(colors.ink.opacity(0.85))
            HStack(spacing: 12) {
                RoundedRectangle(cornerRadius: 9).fill(colors.accent).frame(width: 34, height: 34)
                    .overlay(Image(systemName: "book.closed.fill").font(.system(size: 15)).foregroundStyle(colors.buttonText))
                VStack(alignment: .leading, spacing: 3) {
                    Text("高等数学 · 仙Ⅱ-205").font(.system(size: 12, weight: .semibold)).foregroundStyle(colors.ink)
                    Text("第 1–2 节 · 08:00 上课").font(.system(size: 10)).foregroundStyle(colors.secondary)
                }
                Spacer(minLength: 0)
                Text("12:08").font(.system(size: 17, weight: .semibold, design: .rounded).monospacedDigit()).foregroundStyle(colors.accent)
            }
            .padding(12)
            .background(colors.surface, in: RoundedRectangle(cornerRadius: 18))
            .overlay(RoundedRectangle(cornerRadius: 18).strokeBorder(colors.line, lineWidth: 1))
            .shadow(color: .black.opacity(scheme == .dark ? 0.1 : 0.05), radius: 12, x: 0, y: 7)
        }
        .padding(.horizontal, 26).padding(.vertical, 14)
        .frame(maxWidth: .infinity)
        .background(colors.soft.opacity(0.6), in: RoundedRectangle(cornerRadius: 24))
        .accessibilityHidden(true)
    }
}

/// The sheet the Live Activity switch opens while signed out.
struct LiveActivitySignInSheet: View {
    var onSignedIn: () -> Void
    @Environment(\.dismiss) private var dismiss
    @Environment(\.colorScheme) private var scheme
    private var colors: OnboardingColors { OnboardingColors(scheme: scheme) }

    var body: some View {
        NavigationStack {
            ScrollView {
                LiveActivitySignInContent().padding(24).frame(maxWidth: 570).frame(maxWidth: .infinity)
            }
            .background(colors.background.ignoresSafeArea())
            .safeAreaInset(edge: .bottom, spacing: 0) {
                VStack(spacing: 10) {
                    AccountSignInButton { onSignedIn(); dismiss() }
                    AccountConsentNote()
                }
                .padding(.horizontal, 24).padding(.vertical, 15)
                .frame(maxWidth: 570).frame(maxWidth: .infinity)
                .background(colors.background)
            }
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("暂不") { dismiss() } }
            }
        }
        .tint(colors.accent)
    }
}

// MARK: - Settings

/// The first row of Settings: sign in, or who is signed in and what is left.
struct AccountSettingsSection: View {
    @ObservedObject private var account = AccountService.shared

    var body: some View {
        Section {
            NavigationLink { AccountView() } label: {
                HStack(spacing: 14) {
                    if let summary = account.account {
                        AccountAvatarView(url: account.avatarURL, name: summary.name, size: 52)
                        VStack(alignment: .leading, spacing: 3) {
                            Text(summary.displayName).font(.headline)
                            Text(summary.entitlement.summary).font(.subheadline).foregroundStyle(.secondary)
                        }
                    } else {
                        Image(systemName: "person.crop.circle.fill").font(.system(size: 46)).foregroundStyle(.secondary)
                            .frame(width: 52, height: 52).accessibilityHidden(true)
                        VStack(alignment: .leading, spacing: 3) {
                            Text("通过 Apple 登录").font(.headline)
                            Text("登录后可使用实时活动，新用户免费 30 天").font(.subheadline).foregroundStyle(.secondary)
                        }
                    }
                }
                .padding(.vertical, 4)
            }
        }
        .task { await account.refresh() }
    }
}

struct AccountView: View {
    @ObservedObject private var account = AccountService.shared
    @State private var name = ""
    @State private var photo: PhotosPickerItem?
    @State private var busy = false
    @State private var message: String?
    @State private var confirmSignOut = false
    @State private var confirmDelete = false
    @FocusState private var editingName: Bool

    var body: some View {
        Form {
            if let summary = account.account {
                profile(summary)
                entitlement(summary.entitlement)
                Section {
                    LabeledContent("账户码") {
                        Text(summary.code).font(.body.monospaced()).textSelection(.enabled)
                    }
                    NavigationLink("账户说明") { PrivacyDocumentView(liveActivities: false, account: true) }
                } footer: {
                    Text("需要补偿或反馈问题时，把账户码告诉我们即可查到你的记录。")
                }
                Section {
                    Button("退出登录") { confirmSignOut = true }
                        .confirmationDialog("退出登录？", isPresented: $confirmSignOut, titleVisibility: .visible) {
                            Button("退出登录", role: .destructive) { Task { await account.signOut() } }
                        } message: { Text("退出后这台设备不再收到实时活动提醒，使用日和订阅保留在账户里。") }
                    Button("删除账户", role: .destructive) { confirmDelete = true }
                        .confirmationDialog("删除账户？", isPresented: $confirmDelete, titleVisibility: .visible) {
                            Button("删除账户", role: .destructive) { run { try await account.deleteAccount() } }
                        } message: { Text("账户、昵称、头像和剩余使用日会被永久删除，无法恢复。App Store 订阅不会自动取消，请在系统设置中取消。") }
                }
            } else {
                Section {
                    LiveActivitySignInContent().listRowInsets(EdgeInsets(top: 16, leading: 16, bottom: 16, trailing: 16))
                }
                Section {
                    AccountSignInButton()
                    AccountConsentNote()
                }
            }
            if let message {
                Section { Text(message).foregroundStyle(.red) }
            }
        }
        .navigationTitle("账户")
        .appInlineNavigationTitle()
        .disabled(busy)
        .onAppear { name = account.account?.name ?? "" }
        .onChange(of: account.account?.name) { _, value in if !editingName { name = value ?? "" } }
        .onChange(of: photo) { _, item in
            guard let item else { return }
            photo = nil
            run {
                guard let data = try await item.loadTransferable(type: Data.self), let jpeg = AvatarImage.jpeg(from: data) else {
                    throw ScheduleServiceError.server("无法读取这张图片，请换一张。")
                }
                try await account.setAvatar(jpeg)
            }
        }
        .task { await account.refresh() }
    }

    private func profile(_ summary: AccountSummary) -> some View {
        Section {
            HStack(spacing: 16) {
                PhotosPicker(selection: $photo, matching: .images) {
                    AccountAvatarView(url: account.avatarURL, name: name, size: 72)
                        .overlay(alignment: .bottomTrailing) {
                            Image(systemName: "camera.circle.fill").font(.system(size: 22))
                                .symbolRenderingMode(.multicolor).background(Circle().fill(.background))
                        }
                }
                .buttonStyle(.plain)
                .accessibilityLabel("更换头像")
                VStack(alignment: .leading, spacing: 6) {
                    TextField("填写昵称", text: $name)
                        .font(.title3.weight(.semibold))
                        .focused($editingName)
                        .submitLabel(.done)
                        .onSubmit(saveName)
                    Text("关注你课表的人会看到昵称和头像").font(.caption).foregroundStyle(.secondary)
                }
            }
            .padding(.vertical, 6)
            if summary.avatar != nil {
                Button("移除头像", role: .destructive) { run { try await account.clearAvatar() } }
            }
        }
        .onChange(of: editingName) { _, editing in if !editing { saveName() } }
    }

    private func entitlement(_ value: AccountEntitlement) -> some View {
        Section {
            LabeledContent("实时活动", value: value.summary)
            if value.source == "credit" || value.source == "free" {
                LabeledContent("今天", value: value.chargedToday ? "已计 1 个使用日" : "尚未使用")
            }
        } header: {
            Text("使用日与订阅")
        } footer: {
            Text(value.enforced
                 ? "当天真正收到提醒才扣 1 个使用日，同一天多台设备只算一次；订阅期间不扣使用日。"
                 : "实时活动目前免费，不扣使用日。开始收费后，当天真正收到提醒才扣 1 个使用日。")
        }
    }

    private func saveName() {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed != account.account?.name else { return }
        run { try await account.setName(trimmed) }
    }

    private func run(_ action: @escaping () async throws -> Void) {
        busy = true
        Task {
            defer { busy = false }
            do { try await action(); message = nil }
            catch { message = error.localizedDescription }
        }
    }
}
