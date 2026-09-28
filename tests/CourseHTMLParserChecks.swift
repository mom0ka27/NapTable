import Foundation

@main
struct CourseHTMLParserChecks {
    static func main() {
        // MARK: 教室名里的「单」「双」和全角括号

        // 教室名以 单/双 开头不是单双周；只有紧邻区间的限定词才算。
        let 单片机 = MeetingParser.parse("周三 第1-2节 1-16周 单片机实验室")
        precondition(单片机?.weeks == Array(1...16))
        precondition(单片机?.classroom == "单片机实验室")
        let 双创 = MeetingParser.parse("周三 第1-2节 1-16周 双创楼B203")
        precondition(双创?.weeks == Array(1...16) && 双创?.classroom == "双创楼B203")
        let 限定 = MeetingParser.parse("周三 第1-2节 1-16周 单周 单片机实验室")
        precondition(限定?.weeks == Array(stride(from: 1, through: 16, by: 2)))
        precondition(限定?.classroom == "单片机实验室")
        let 括号 = MeetingParser.parse("周三 第1-2节 1-16周（单）")
        precondition(括号?.weeks == Array(stride(from: 1, through: 16, by: 2)))
        // 「1-8周,10-16周(单)」里的 1-8 周不能被后面的 (单) 带走。
        let 分段 = MeetingParser.parseWeeksWithParentheses("周一 第1-2节 1-8周,10-16周(单)")
        precondition(分段 == Array(1...8) + [11, 13, 15])
        let 分段宽松 = MeetingParser.parseWeeks("1-8周,10-16周(单)")
        precondition(分段宽松 == Array(1...8) + [11, 13, 15])
        // 两段都带限定词时各归各的。
        precondition(MeetingParser.parseWeeks("1-8周(单),9-16周(双)") == [1, 3, 5, 7] + [10, 12, 14, 16])
        let 全角分段 = MeetingParser.parseWeeks("1-8周（单）,9-16周（双）")
        precondition(全角分段 == [1, 3, 5, 7] + [10, 12, 14, 16])

        // MARK: LightHTML

        // 文本按文档顺序拼，不能先拼父节点的文字再拼子元素。
        let inline = LightHTML.parse("<table><tr><td>周三 第1-2节 <span>1-16周</span> 仙Ⅱ-304</td></tr></table>")
        let cell = inline.root.descendants(withTag: "td")[0]
        precondition(cell.trimmedText == "周三 第1-2节 1-16周 仙Ⅱ-304", cell.trimmedText)

        // 标签名后面跟换行、制表符也要切开。
        let newline = LightHTML.parse("<td\nclass=\"x\">a</td><td\tclass='y'>b</td>")
        precondition(newline.root.descendants(withTag: "td").map(\.className) == ["x", "y"])

        // 隐式闭合：没写 </td> </tr> </li> </option> </p> 的也要成为兄弟节点。
        let implicit = LightHTML.parse("<table><tr><td>1<td>2<tr><td>3</table>")
        let rows = implicit.root.descendants(withTag: "tr")
        precondition(rows.count == 2 && rows[0].elementChildren.map(\.trimmedText) == ["1", "2"])
        precondition(rows[1].elementChildren.map(\.trimmedText) == ["3"])
        let list = LightHTML.parse("<ul><li>a<li>b</ul><select><option>x<option>y</select><p>p1<p>p2")
        precondition(list.root.descendants(withTag: "li").map(\.trimmedText) == ["a", "b"])
        precondition(list.root.descendants(withTag: "option").map(\.trimmedText) == ["x", "y"])
        precondition(list.root.descendants(withTag: "p").map(\.trimmedText) == ["p1", "p2"])
        // 嵌套表格里的单元格不会把外层的单元格关掉。
        let nested = LightHTML.parse("<table><tr><td>outer<table><tr><td>inner</td></tr></table></td><td>next</td></tr></table>")
        let outerRow = nested.root.descendants(withTag: "tr")[0]
        precondition(outerRow.elementChildren.filter { $0.tag == "td" }.count == 2)

        // 很深的嵌套不能把递归撑爆。
        let deep = LightHTML.parse(String(repeating: "<div>", count: 100_000) + "底" + String(repeating: "</div>", count: 100_000))
        precondition(deep.root.trimmedText == "底")

        // 实体只解一遍，顺序固定。
        precondition(LightHTML.decodeEntities("&amp;lt;") == "&lt;")
        precondition(LightHTML.decodeEntities("a&nbsp;b &lt;c&gt; &#20013;&#x6587; &unknown; &") == "a b <c> 中文 &unknown; &")

        // 选课页：单元格里文字和行内元素混排时整格当一条上课信息读。
        let selection = """
        <div class="course-head"></div><div class="course-head"><table><tr><td>序号</td><td>课程名</td><td>教师</td><td>时间地点</td></tr></table></div>
        <table><tbody class="course-body"></tbody><tbody class="course-body">
        <tr><td>1</td><td>高等数学</td><td>张三</td><td>周三 第1-2节 <span>1-16周</span> 仙Ⅱ-304</td></tr>
        <tr><td>2</td><td>线性代数</td><td>李四</td><td><div>周一 第3-4节 1-8周</div><div>周四 第3-4节 9-16周(双) 仙Ⅰ-101</div></td></tr>
        </tbody></table>
        """
        let parsed = CourseHTMLParser.parseSelectionCourses(fromHTML: selection)
        precondition(parsed.count == 3, "\(parsed.map(\.name))")
        precondition(parsed[0].name == "高等数学" && parsed[0].weekTime == 3 && parsed[0].weeks == Array(1...16))
        precondition(parsed[0].classroom == "仙Ⅱ-304")
        precondition(parsed[2].weeks == [10, 12, 14, 16] && parsed[2].classroom == "仙Ⅰ-101")

        // 旧教务页：没写 </td> 的单元格靠隐式闭合分开，<br> 分隔两次上课。
        let legacy = CourseHTMLParser.parseLegacyJWCourses(fromHTML: """
        <table><tr class="TABLE_TR_01"><td>1<td>大学物理<td>x<td
        >王五<td>周一 第1-2节 1-16周 仙Ⅰ-101<br>周三 第3-4节 单周 双创楼201</tr></table>
        """)
        precondition(legacy.count == 2 && legacy.allSatisfy { $0.name == "大学物理" && $0.teacher == "王五" })
        precondition(legacy[0].classroom == "仙Ⅰ-101" && legacy[0].weeks == Array(1...16))
        precondition(legacy[1].weeks == WeekSeries.single(from: 1, to: SchoolDefaults.defaultWeekCount))
        precondition(legacy[1].classroom == "双创楼201", legacy[1].classroom ?? "")

        print("CourseHTMLParserChecks passed")
    }
}
