import PhotosUI
import SwiftUI
import UniformTypeIdentifiers

struct ImageImportView: View {
    let onCreated: () -> Void
    @EnvironmentObject private var store: AppStore
    @State private var configuration: ImageImportService.Configuration?
    @State private var photo: PhotosPickerItem?
    @State private var image: Data?
    @State private var preview: PlatformImage?
    @State private var showFiles = false
    @State private var uploadConsent = false
    @State private var busy = false
    @State private var error: String?
    @State private var result: ImageImportResult?
    @State private var draft: ManualScheduleDraft?

    var body: some View {
        Group {
            if let draft, let result {
                ManualScheduleWizard(school: nil, requiresCourses: true, onCreated: onCreated,
                    initialDraft: draft, recognitionWarnings: result.reviewWarnings)
            } else {
                Form {
                    Section {
                        Text("选择一张清晰、完整的课表截图，识别后核对学期、节次和课程，再创建课表。")
                        if configuration?.enabled == false {
                            Label("图片导入暂未开放，可以使用手动导入。", systemImage: "info.circle")
                        }
                        if let error { Text(error).foregroundStyle(.red) }
                        if configuration == nil {
                            Button("检查服务状态") { Task { await loadConfiguration() } }.disabled(busy)
                        }
                    }
                    Section("课表图片") {
                        if let preview {
                            Image(platformImage: preview).resizable().scaledToFit().frame(maxHeight: 320)
                        }
                        PhotosPicker(selection: $photo, matching: .images) {
                            Label("从相册选择", systemImage: "photo")
                        }
                        Button { showFiles = true } label: { Label("从文件选择", systemImage: "folder") }
                    }
                    .disabled(busy || configuration?.enabled != true)
                    Section {
                        Toggle("同意上传此图片用于识别", isOn: $uploadConsent)
                        Button {
                            Task { await recognize() }
                        } label: {
                            HStack {
                                if busy { ProgressView() }
                                Text(busy ? "正在处理…" : "识别课表")
                            }
                        }
                        .disabled(busy || image == nil || !uploadConsent || configuration?.enabled != true)
                    } footer: {
                        Text("图片会发送至你以为课表服务端，再交由服务端配置的 AI 服务（OpenAI 或兼容服务）处理。请先裁掉姓名、学号等无关信息。你以为课表服务端不保存图片及识别课程，只保留匿名调用统计 90 天；AI 服务的数据保留规则由服务提供方决定。")
                    }
                    .disabled(busy)
                }
                .appListBackground()
                .appSoftTopScrollEdge()
                .navigationTitle("图片导入")
                .appInlineNavigationTitle()
            }
        }
        .task { if configuration == nil { await loadConfiguration() } }
        .onChange(of: photo) { _, item in
            guard let item else { return }
            Task {
                busy = true; error = nil
                defer { busy = false }
                do {
                    guard let data = try await item.loadTransferable(type: Data.self) else { throw ScheduleServiceError.invalidResponse }
                    try await select(data)
                } catch { self.error = error.localizedDescription }
            }
        }
        .fileImporter(isPresented: $showFiles, allowedContentTypes: [.image]) { selection in
            Task {
                busy = true; error = nil
                defer { busy = false }
                do {
                    let url = try selection.get()
                    let access = url.startAccessingSecurityScopedResource()
                    defer { if access { url.stopAccessingSecurityScopedResource() } }
                    let size = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
                    guard size <= 32 * 1024 * 1024 else { throw ScheduleServiceError.server("图片过大，请裁剪到课表区域。") }
                    try await select(Data(contentsOf: url, options: .mappedIfSafe))
                } catch { self.error = error.localizedDescription }
            }
        }
    }

    private func loadConfiguration() async {
        busy = true; error = nil
        defer { busy = false }
        do { configuration = try await ImageImportService.configuration() }
        catch { self.error = error.localizedDescription }
    }

    private func select(_ data: Data) async throws {
        let prepared = try await Task.detached { try ImageImportService.prepare(data) }.value
        image = prepared; preview = PlatformImage(data: prepared); uploadConsent = false
    }

    private func recognize() async {
        guard let image, uploadConsent else { return }
        busy = true; error = nil
        defer { busy = false }
        do {
            let result = try await ImageImportService.recognize(image)
            var draft = try result.draft()
            draft.name = store.uniqueTableName(draft.name)
            self.result = result; self.draft = draft
        } catch { self.error = error.localizedDescription }
    }
}
