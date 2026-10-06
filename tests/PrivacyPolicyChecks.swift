import Foundation

@main
struct PrivacyPolicyChecks {
    static func main() {
        let documents = [(PrivacyPolicy.basicTitle, PrivacyPolicy.basicClauses),
                         (PrivacyPolicy.liveTitle, PrivacyPolicy.liveClauses)]
        for (document, clauses) in documents {
            precondition(!clauses.isEmpty, "\(document) has no clauses")
            for clause in clauses {
                let title = clause.title.trimmingCharacters(in: .whitespacesAndNewlines)
                let body = clause.body.trimmingCharacters(in: .whitespacesAndNewlines)
                precondition(!title.isEmpty, "\(document): every clause needs a heading")
                precondition(!body.isEmpty, "\(document) / \(clause.title): body must not be empty")
                // 正文里再夹空行，页面上就又多出一段没有标题的正文。
                precondition(!clause.body.contains("\n\n"), "\(document) / \(clause.title): split it into another clause")
                // 中文品牌名两侧不留空格（英文名时代留下的排版）。
                precondition(!clause.body.contains("你以为课表 ") && !clause.body.contains(" 你以为课表"),
                             "\(document) / \(clause.title): no spaces around the Chinese app name")
            }
            precondition(Set(clauses.map(\.title)).count == clauses.count, "\(document): duplicate headings")
        }
        precondition(PrivacyPolicy.version >= 1)
        precondition(PrivacyPolicy.updatedAt.range(of: #"^\d{4}\.\d{2}\.\d{2}$"#, options: .regularExpression) != nil,
                     "updatedAt is shown as yyyy.MM.dd in the document header")
        print("PASS: \(PrivacyPolicy.basicClauses.count) basic and \(PrivacyPolicy.liveClauses.count) live clauses, "
              + "each with heading and body; version \(PrivacyPolicy.version) · \(PrivacyPolicy.updatedAt)")
    }
}
