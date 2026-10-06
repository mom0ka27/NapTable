import Foundation

@main
struct AnnouncementChecks {
    @MainActor static func main() throws {
        let suite = "naptable.announcement.tests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        func item(_ changes: [String: Any] = [:]) throws -> AppAnnouncement {
            var value: [String: Any] = ["id": "release", "kind": "update", "platform": "ios", "enabled": true,
                "title": "新版本", "subtitle": "", "body": "## 更新\n- **新功能**", "version": "1.10", "minVersion": "", "maxVersion": "",
                "actionTitle": "", "actionURL": "https://apps.apple.com/app/id123", "startsAt": NSNull(), "endsAt": NSNull()]
            value.merge(changes) { _, new in new }
            return try JSONDecoder().decode(AppAnnouncement.self, from: JSONSerialization.data(withJSONObject: value))
        }
        let release = try item()
        precondition(release.applies(to: "1.9", platform: "ios", now: now))
        precondition(!release.applies(to: "1.10.0", platform: "ios", now: now))
        precondition(!release.applies(to: "2.0", platform: "ios", now: now))
        precondition(!release.applies(to: "1.9", platform: "macos", now: now))
        for invalid in ["", "1..2", "v1.2", "1.2b", "１２", "1.2.3.4.5"] { precondition(AppAnnouncement.versionParts(invalid) == nil) }
        let ranged = try item(["minVersion": "1.8", "maxVersion": "1.9"])
        precondition(ranged.applies(to: "1.9.0", platform: "ios", now: now))
        precondition(!ranged.applies(to: "1.7", platform: "ios", now: now))
        precondition(!ranged.applies(to: "1.9.1", platform: "ios", now: now))
        let timed = try item(["startsAt": now.timeIntervalSince1970, "endsAt": now.timeIntervalSince1970 + 10])
        precondition(timed.applies(to: "1.9", platform: "ios", now: now))
        precondition(!timed.applies(to: "1.9", platform: "ios", now: now.addingTimeInterval(-1)))
        precondition(!timed.applies(to: "1.9", platform: "ios", now: now.addingTimeInterval(10)))
        let draft = try item(["enabled": false])
        precondition(!draft.applies(to: "1.9", platform: "ios", now: now))
        for link in ["javascript:alert(1)", "http://example.com", "file:///etc/passwd", "https://user:pass@example.com"] {
            precondition(AppAnnouncement.safeLink(link) == nil)
        }
        let notice = try item(["id": "notice", "kind": "notice", "version": "", "actionURL": "", "platform": "all"])
        precondition(notice.applies(to: "100.0", platform: "macos", now: now))
        let older = try item(["id": "older", "version": "1.9.1"])
        let messages = [older, release, notice]
        func pending() -> AppAnnouncement? {
            AnnouncementPolicy.pending(messages, currentVersion: "1.8", platform: "ios", source: "server", now: now, defaults: defaults)
        }
        precondition(pending()?.id == notice.id, "Notices take priority over releases")
        AnnouncementPolicy.markSeen(notice, source: "server", now: now, defaults: defaults)
        precondition(pending()?.id == release.id, "Only the highest update is selected")
        AnnouncementPolicy.markSeen(release, source: "server", now: now, defaults: defaults)
        precondition(pending() == nil, "Never fall back to an obsolete update after viewing the latest")
        let reopened = UserDefaults(suiteName: suite)!
        precondition(AnnouncementPolicy.hasSeen(release, source: "server", defaults: reopened))
        precondition(!AnnouncementPolicy.hasSeen(release, source: "another", defaults: reopened))
        let edited = try item(["body": "修正说明"])
        precondition(AnnouncementPolicy.hasSeen(edited, source: "server", defaults: defaults))
        let upgraded = try item(["version": "1.11"])
        precondition(!AnnouncementPolicy.hasSeen(upgraded, source: "server", defaults: defaults))
        precondition(AnnouncementPolicy.canPresent(now: now, defaults: defaults))
        AnnouncementPolicy.markAutomatic(now: now, defaults: defaults)
        for kind in [AppAnnouncement.Kind.notice, .update] {
            precondition(!AnnouncementPolicy.canPresent(kind: kind, now: now.addingTimeInterval(299), defaults: defaults))
            precondition(AnnouncementPolicy.canPresent(kind: kind, now: now.addingTimeInterval(300), defaults: defaults),
                         "An earlier automatic reminder must not suppress either kind of new publication for a day")
        }
        precondition(!AnnouncementPolicy.canPresent(now: now.addingTimeInterval(86399), defaults: defaults))
        precondition(AnnouncementPolicy.canPresent(now: now.addingTimeInterval(86400), defaults: defaults))
        print("PASS: numeric version bounds, platform, publication window, safe links, priority, latest-only updates, persistent history and shared cooldown")
    }
}
