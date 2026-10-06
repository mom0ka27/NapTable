import SwiftUI

struct AnnouncementView: View {
    let item: AppAnnouncement
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openURL) private var openURL
    @Environment(\.colorScheme) private var colorScheme
    @State private var linkFailed = false
    private var accent: Color { item.kind == .update ? Color(red: 0.34, green: 0.40, blue: 0.85) : Color(red: 0.16, green: 0.55, blue: 0.49) }

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    hero
                    AnnouncementMarkdown(text: item.body)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(20)
                        .background(.background, in: RoundedRectangle(cornerRadius: 22))
                        .overlay { RoundedRectangle(cornerRadius: 22).strokeBorder(accent.opacity(0.10)) }
                }
                .padding(.horizontal, 20)
                .padding(.top, 12)
                .padding(.bottom, 24)
                .frame(maxWidth: 640)
                .frame(maxWidth: .infinity)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)

            // The footer owns its height instead of overlaying the scroll view.
            // Long content scrolls above it without compressing either region.
            actions
                .fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, 20)
                .padding(.top, 12)
                .padding(.bottom, 8)
                .frame(maxWidth: 640)
                .frame(maxWidth: .infinity)
                .background(.regularMaterial)
                .overlay(alignment: .top) { Divider().opacity(0.5) }
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
        .alert("暂时无法打开链接", isPresented: $linkFailed) {
            Button("知道了", role: .cancel) { }
        } message: { Text("请稍后重试，或从设置中的“更新与通知”再次查看。") }
    }

    private var actions: some View {
        VStack(spacing: 4) {
            Button {
                if let url = item.actionLink {
                    openURL(url) { accepted in linkFailed = !accepted }
                } else {
                    dismiss()
                }
            } label: {
                HStack(spacing: 8) {
                    Text(item.actionLink == nil ? "知道了" : item.buttonTitle)
                    if item.actionLink != nil { Image(systemName: "arrow.up.right") }
                }
                .font(.headline)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, 16)
                .padding(.vertical, 14)
                .frame(maxWidth: .infinity, minHeight: 50)
                .foregroundStyle(Color.white)
                .background(accent, in: RoundedRectangle(cornerRadius: 16))
                .contentShape(RoundedRectangle(cornerRadius: 16))
            }
            .buttonStyle(.plain)

            if item.actionLink != nil {
                Button { dismiss() } label: {
                    Text("稍后再说")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, minHeight: 44)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
    }

    private var hero: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 12) {
                Image(systemName: item.icon)
                    .font(.system(size: 22, weight: .medium))
                    .foregroundStyle(accent)
                    .frame(width: 44, height: 44)
                    .background(.background.opacity(0.8), in: RoundedRectangle(cornerRadius: 14))
                if item.kind == .update {
                    ViewThatFits(in: .horizontal) {
                        versionLabel
                        Text("新版本 v\(item.version)")
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .font(.system(.subheadline, design: .rounded))
                    .foregroundStyle(accent)
                    .accessibilityElement(children: .combine)
                } else {
                    Text("来自 NapTable 的消息")
                        .font(.subheadline)
                        .foregroundStyle(accent)
                }
            }
            VStack(alignment: .leading, spacing: 10) {
                Text(item.title)
                    .font(.system(.title2, design: .rounded, weight: .bold))
                    .fixedSize(horizontal: false, vertical: true)
                if !item.subtitle.isEmpty {
                    Text(item.subtitle)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .padding(20)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background {
            ZStack(alignment: .topTrailing) {
                LinearGradient(colors: [accent.opacity(0.16), accent.opacity(0.04)], startPoint: .topLeading, endPoint: .bottomTrailing)
                Circle().stroke(accent.opacity(0.07), lineWidth: 20)
                    .frame(width: 150, height: 150).offset(x: 55, y: -65)
            }
            .clipShape(RoundedRectangle(cornerRadius: 22))
            .accessibilityHidden(true)
        }
    }

    private var versionLabel: some View {
        HStack(spacing: 8) {
            Text("v\(AnnouncementStore.currentVersion)").foregroundStyle(.secondary)
            Image(systemName: "arrow.right")
            Text("v\(item.version)").fontWeight(.semibold)
        }
        .fixedSize()
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
    }
    private func inline(_ text: String) -> some View {
        var attributed = (try? AttributedString(markdown: text, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace))) ?? AttributedString(text)
        for run in attributed.runs {
            if let url = run.link, AppAnnouncement.safeLink(url.absoluteString) == nil {
                attributed[run.range].link = nil
            }
        }
        return Text(attributed)
            .fixedSize(horizontal: false, vertical: true)
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
