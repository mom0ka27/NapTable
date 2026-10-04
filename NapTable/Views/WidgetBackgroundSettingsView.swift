import PhotosUI
import SwiftUI

struct WidgetBackgroundSettingsScreen: View {
    @ObservedObject var settings: NativeWidgetSettings
    @ObservedObject private var purchases = PurchaseManager.shared
    @State private var pending: PendingBackground?
    @State private var message: String?

    var body: some View {
        Form {
            if purchases.allowsProFeatures {
                Section {
                    Toggle("显示背景图片", isOn: Binding(
                        get: { settings.background.enabled },
                        set: { enabled in
                            var value = settings.background
                            value.enabled = enabled
                            update(value)
                        }
                    ))
                } footer: {
                    Text("今日课程和两日课表共用此背景，按小组件尺寸居中裁切。浅色与深色只设置一张时共用；关闭后保留图片和调整记录。")
                }
                WidgetBackgroundSection(settings: settings, dark: false, pending: $pending)
                WidgetBackgroundSection(settings: settings, dark: true, pending: $pending)
                Section {} footer: {
                    Text("适用于主屏幕小组件；锁屏小组件保持系统背景，染色模式和待机显示由系统决定背景效果。")
                }
            } else {
                Section {
                    Label("小组件背景图片是专业版功能", systemImage: "lock.fill")
                        .foregroundStyle(.secondary)
                    NavigationLink("查看专业版权益") { SubscriptionView() }
                } footer: {
                    Text("可为浅色和深色模式分别选择图片，并调整位置、大小与不透明度。")
                }
            }
        }
        .appListBackground()
        .navigationTitle("小组件背景图片")
        .appInlineNavigationTitle()
        .appSoftTopScrollEdge()
        .onChange(of: purchases.allowsProFeatures) { _, allowed in
            if !allowed { pending = nil }
        }
        .navigationDestination(item: $pending) { item in
            BackgroundCropEditor(
                image: item.image,
                initialPlacement: item.placement,
                opacity: Binding(
                    get: { .init(light: settings.background.lightOpacity, dark: settings.background.darkOpacity) },
                    set: { opacity in
                        var value = settings.background
                        value.lightOpacity = opacity.light
                        value.darkOpacity = opacity.dark
                        update(value)
                    }
                ),
                initialPreviewDark: item.dark,
                locksPreviewAppearance: ScheduleWidgetBackgroundStore.shared.hasImage(dark: !item.dark),
                commitsOnAppear: item.isNew,
                widgetPreview: true,
                onCommit: { data, placement in
                    guard purchases.allowsProFeatures else { return }
                    try settings.setBackground(cropped: data, source: item.source, placement: placement, dark: item.dark)
                }
            )
        }
        .alert("背景图片", isPresented: Binding(get: { message != nil }, set: { if !$0 { message = nil } })) {
            Button("知道了", role: .cancel) { message = nil }
        } message: { Text(message ?? "") }
    }

    private func update(_ value: ScheduleWidgetBackgroundStore.Settings) {
        guard purchases.allowsProFeatures else { return }
        do { try settings.setBackgroundSettings(value) }
        catch { message = "背景设置未能保存，请重试。" }
    }
}

private struct WidgetBackgroundSection: View {
    @ObservedObject var settings: NativeWidgetSettings
    let dark: Bool
    @Binding var pending: PendingBackground?
    @State private var selection: PhotosPickerItem?
    @State private var busy = false
    @State private var message: String?
    @State private var confirmingRemoval = false

    private var store: ScheduleWidgetBackgroundStore { .shared }
    private var name: String { dark ? "深色模式" : "浅色模式" }
    private var otherName: String { dark ? "浅色模式" : "深色模式" }

    var body: some View {
        let hasOwn = store.hasImage(dark: dark)
        let followsOther = !hasOwn && store.hasImage(dark: !dark)
        Section {
            if hasOwn, let data = store.imageURL(dark: dark).flatMap({ try? Data(contentsOf: $0) }),
               let image = BackgroundCropEditor.decode(data) {
                Image(decorative: image, scale: 1)
                    .resizable().scaledToFill()
                    .frame(height: 100).frame(maxWidth: .infinity)
                    .clipped()
                    .clipShape(RoundedRectangle(cornerRadius: 12))
            } else if followsOther {
                LabeledContent("当前", value: "跟随\(otherName)的图片")
            }
            PhotosPicker(selection: $selection, matching: .images) {
                Label(busy ? "正在读取图片…" : (hasOwn ? "更换图片" : "选择背景图片"), systemImage: "photo.on.rectangle")
            }
            .disabled(busy)
            if hasOwn {
                Button { edit() } label: { Label("调整位置和大小", systemImage: "crop") }
                    .disabled(busy)
                Button("移除背景图片", role: .destructive) { confirmingRemoval = true }
                    .disabled(busy)
                    .confirmationDialog("移除\(name)的背景图片？", isPresented: $confirmingRemoval, titleVisibility: .visible) {
                        Button("移除", role: .destructive) {
                            do { try settings.removeBackground(dark: dark) }
                            catch { message = "图片未能移除，请重试。" }
                        }
                        Button("取消", role: .cancel) {}
                    } message: {
                        Text(store.hasImage(dark: !dark) ? "移除后改用\(otherName)的图片。" : "原图与调整记录将一并删除。")
                    }
            }
        } header: { Text(name) }
        .onChange(of: selection) { _, item in
            guard let item else { return }
            busy = true
            Task { @MainActor in
                defer { busy = false; selection = nil }
                do {
                    guard let data = try await item.loadTransferable(type: Data.self),
                          let image = BackgroundCropEditor.decode(data),
                          let source = BackgroundCropEditor.jpegData(image) else { throw CocoaError(.fileReadCorruptFile) }
                    pending = PendingBackground(image: image, source: source, placement: .init(), dark: dark, isNew: true)
                } catch { message = "无法读取该图片，请更换后重试。" }
            }
        }
        .alert("背景图片", isPresented: Binding(get: { message != nil }, set: { if !$0 { message = nil } })) {
            Button("知道了", role: .cancel) { message = nil }
        } message: { Text(message ?? "") }
    }

    private func edit() {
        guard let data = store.sourceData(dark: dark), let image = BackgroundCropEditor.decode(data) else {
            message = "无法读取原图，请重新选择图片。"
            return
        }
        let placement = dark ? settings.background.darkPlacement : settings.background.lightPlacement
        pending = PendingBackground(image: image, source: data,
            placement: .init(scale: placement.scale, offsetX: placement.offsetX, offsetY: placement.offsetY), dark: dark)
    }
}
