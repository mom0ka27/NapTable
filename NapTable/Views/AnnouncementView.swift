import SwiftUI

struct AnnouncementView: View {
    let item: AppAnnouncement
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openURL) private var openURL
    @Environment(\.colorScheme) private var colorScheme
    @State private var linkFailed = false
    private var accent: Color { item.kind == .update ? Color(red: 0.34, green: 0.40, blue: 0.85) : Color(red: 0.16, green: 0.55, blue: 0.49) }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 28) {
                hero
                AnnouncementMarkdown(text: item.body)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(24)
                    .background(.background, in: RoundedRectangle(cornerRadius: 24))
                    .overlay { RoundedRectangle(cornerRadius: 24).strokeBorder(accent.opacity(0.10)) }
                Label("NapTable · 让校园时间井然有序", systemImage: "leaf")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity)
            }
            .padding(24)
            .frame(maxWidth: 640)
            .frame(maxWidth: .infinity)
        }
        .background(accent.opacity(colorScheme == .dark ? 0.06 : 0.035))
        .background(.background)
        .navigationTitle(item.label)
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button("关闭", systemImage: "xmark") { dismiss() }
            }
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            VStack(spacing: 12) {
                if let url = item.actionLink {
                    Button {
                        openURL(url) { accepted in linkFailed = !accepted }
                    } label: {
                        HStack(spacing: 10) {
                            Text(item.buttonTitle)
                            Image(systemName: "arrow.up.right")
                        }
                        .font(.headline)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 9)
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(accent)
                    .controlSize(.large)
                    Button("稍后再说") { dismiss() }
                        .font(.subheadline).foregroundStyle(.secondary)
                        .buttonStyle(.plain)
                } else {
                    Button { dismiss() } label: {
                        Text("知道了")
                            .font(.headline)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 9)
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(accent)
                    .controlSize(.large)
                }
            }
            .padding(.horizontal, 24).padding(.vertical, 16)
            .frame(maxWidth: 640)
            .frame(maxWidth: .infinity)
            .background(.regularMaterial)
        }
        .alert("暂时无法打开链接", isPresented: $linkFailed) {
            Button("知道了", role: .cancel) { }
        } message: { Text("请稍后重试，或从设置中的“更新与通知”再次查看。") }
    }

    private var hero: some View {
        VStack(alignment: .leading, spacing: 22) {
            HStack {
                Image(systemName: item.icon)
                    .font(.system(size: 29, weight: .medium))
                    .foregroundStyle(accent)
                    .frame(width: 64, height: 64)
                    .background(.background.opacity(0.8), in: RoundedRectangle(cornerRadius: 20))
                Spacer()
                Text(item.kind == .update ? "WHAT’S NEW" : "A NOTE FOR YOU")
                    .font(.system(.caption2, design: .monospaced, weight: .medium))
                    .tracking(1.7).foregroundStyle(accent)
            }
            VStack(alignment: .leading, spacing: 12) {
                Text(item.title)
                    .font(.system(.largeTitle, design: .rounded, weight: .bold))
                    .fixedSize(horizontal: false, vertical: true)
                if !item.subtitle.isEmpty {
                    Text(item.subtitle).font(.subheadline).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            if item.kind == .update {
                HStack(spacing: 10) {
                    Text("v\(AnnouncementStore.currentVersion)").foregroundStyle(.secondary)
                    Image(systemName: "arrow.right").foregroundStyle(accent)
                    Text("v\(item.version)").fontWeight(.semibold).foregroundStyle(accent)
                }
                .font(.system(.caption, design: .rounded))
                .padding(.horizontal, 14).padding(.vertical, 9)
                .background(.background.opacity(0.75), in: Capsule())
                .accessibilityElement(children: .combine)
            }
        }
        .padding(26)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background {
            ZStack(alignment: .topTrailing) {
                LinearGradient(colors: [accent.opacity(0.18), accent.opacity(0.04)], startPoint: .topLeading, endPoint: .bottomTrailing)
                Circle().stroke(accent.opacity(0.08), lineWidth: 28)
                    .frame(width: 190, height: 190).offset(x: 65, y: -75)
                Circle().stroke(accent.opacity(0.10), lineWidth: 1)
                    .frame(width: 255, height: 255).offset(x: 95, y: -110)
            }
            .clipShape(RoundedRectangle(cornerRadius: 28))
            .accessibilityHidden(true)
        }
    }
}

/// A deliberately small Markdown vocabulary shared with the publication editor.
/// HTML remains text; links can only open HTTPS destinations.
private struct AnnouncementMarkdown: View {
    let text: String
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            ForEach(Array(text.components(separatedBy: .newlines).enumerated()), id: \.offset) { _, line in
                if line.trimmingCharacters(in: .whitespaces).isEmpty {
                    Color.clear.frame(height: 4).accessibilityHidden(true)
                } else if line.hasPrefix("### ") {
                    inline(String(line.dropFirst(4))).font(.headline).padding(.top, 4)
                } else if line.hasPrefix("## ") {
                    inline(String(line.dropFirst(3))).font(.title3.bold()).padding(.top, 6)
                } else if line.hasPrefix("# ") {
                    inline(String(line.dropFirst(2))).font(.title2.bold()).padding(.top, 8)
                } else if line.hasPrefix("- ") || line.hasPrefix("* ") {
                    HStack(alignment: .firstTextBaseline, spacing: 12) {
                        Text("•").foregroundStyle(.secondary)
                        inline(String(line.dropFirst(2)))
                    }
                } else if line.hasPrefix("> ") {
                    inline(String(line.dropFirst(2)))
                        .foregroundStyle(.secondary)
                        .padding(.leading, 14)
                        .overlay(alignment: .leading) { Capsule().fill(.secondary.opacity(0.3)).frame(width: 3) }
                } else {
                    inline(line)
                }
            }
        }
        .font(.body).lineSpacing(5)
        .textSelection(.enabled)
    }
    private func inline(_ text: String) -> Text {
        var attributed = (try? AttributedString(markdown: text, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace))) ?? AttributedString(text)
        for run in attributed.runs {
            if let url = run.link, AppAnnouncement.safeLink(url.absoluteString) == nil {
                attributed[run.range].link = nil
            }
        }
        return Text(attributed)
    }
}

struct AnnouncementCenterView: View {
    @ObservedObject private var announcements = AnnouncementStore.shared
    @State private var selected: AppAnnouncement?
    var body: some View {
        List {
            Section {
                Label("当前版本 v\(AnnouncementStore.currentVersion)", systemImage: "app.badge.checkmark")
                    .foregroundStyle(.secondary)
            }
            if announcements.isLoading && announcements.messages.isEmpty {
                ProgressView("正在获取更新与通知…")
            } else if let error = announcements.errorMessage {
                ContentUnavailableView {
                    Label("暂时无法连接", systemImage: "wifi.exclamationmark")
                } description: { Text(error) } actions: {
                    Button("重试") { Task { await announcements.refresh(force: true) } }
                }
            } else if announcements.applicable.isEmpty {
                ContentUnavailableView("暂无更新与通知", systemImage: "checkmark.seal", description: Text("目前没有适用于此版本的新消息。"))
            } else {
                ForEach(announcements.applicable) { item in
                    Button { selected = item } label: {
                        HStack(spacing: 14) {
                            Image(systemName: item.icon).font(.title2).frame(width: 32)
                            VStack(alignment: .leading, spacing: 5) {
                                Text(item.label).font(.caption).foregroundStyle(.secondary)
                                Text(item.title).font(.headline).foregroundStyle(.primary)
                                if !item.subtitle.isEmpty { Text(item.subtitle).font(.caption).foregroundStyle(.secondary).lineLimit(2) }
                            }
                            Spacer(minLength: 0)
                            Image(systemName: "chevron.right").font(.caption).foregroundStyle(.tertiary)
                        }.padding(.vertical, 8)
                    }.buttonStyle(.plain)
                }
            }
        }
        .navigationTitle("更新与通知")
        .task { await announcements.refresh(force: true) }
        .refreshable { await announcements.refresh(force: true) }
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button("刷新", systemImage: "arrow.clockwise") { Task { await announcements.refresh(force: true) } }
                    .disabled(announcements.isLoading)
            }
        }
        .sheet(item: $selected) { item in
            NavigationStack { AnnouncementView(item: item) }
                #if os(macOS)
                .frame(minWidth: 520, minHeight: 680)
                #else
                .presentationDetents([.large])
                .presentationDragIndicator(.visible)
                #endif
                .onAppear { AnnouncementPolicy.markSeen(item, source: announcements.source) }
        }
    }
}
