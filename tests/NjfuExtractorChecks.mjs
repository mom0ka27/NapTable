// 在 node 里跑南京林业大学课表提取脚本：从 Swift 源文件里取出脚本，用假的
// XMLHttpRequest 返回强智教务 xskb_list.do 的课表页，用一个极简 DOMParser
// 代替 WKWebView 的 DOM（只实现脚本用到的那几个接口）。
import { readFileSync } from "node:fs";
import vm from "node:vm";
import assert from "node:assert/strict";

const swift = readFileSync(new URL("../NapTable/Import/NjfuExtractor.swift", import.meta.url), "utf8");
const body = swift.slice(swift.indexOf('#"""') + 4, swift.lastIndexOf('"""#'));
const script = body.split("\n").map((line) => line.replace(/^    /, "")).join("\n");

// MARK: 极简 DOM

const VOID = new Set(["br", "input", "meta", "img", "hr", "link"]);
const decode = (s) => s.replace(/&nbsp;/g, " ").replace(/&lt;/g, "<").replace(/&gt;/g, ">").replace(/&amp;/g, "&");
class Text { constructor(t) { this.nodeType = 3; this.textContent = decode(t); } }
class Element {
  constructor(tag, attrs) { this.nodeType = 1; this.tagName = tag.toUpperCase(); this.attrs = attrs; this.childNodes = []; }
  get children() { return this.childNodes.filter((n) => n.nodeType === 1); }
  get textContent() { return this.childNodes.map((n) => n.textContent).join(""); }
  getAttribute(k) { return k in this.attrs ? this.attrs[k] : null; }
  hasAttribute(k) { return k in this.attrs; }
  *walk() { for (const n of this.children) { yield n; yield* n.walk(); } }
  getElementsByTagName(t) { return [...this.walk()].filter((n) => n.tagName === t.toUpperCase()); }
  getElementById(id) { return [...this.walk()].find((n) => n.attrs.id === id) || null; }
}
class DOMParser {
  parseFromString(html) {
    const root = new Element("#document", {});
    const stack = [root];
    const re = /<!--[\s\S]*?-->|<(\/?)([a-zA-Z]+)([^>]*)>|([^<]+)/g;
    let m;
    while ((m = re.exec(html))) {
      const top = stack[stack.length - 1];
      if (m[4] != null) { top.childNodes.push(new Text(m[4])); continue; }
      if (!m[2]) continue;
      const tag = m[2].toLowerCase();
      if (m[1]) {
        const i = stack.map((n) => n.tagName).lastIndexOf(tag.toUpperCase());
        if (i > 0) stack.length = i;
        continue;
      }
      const attrs = {};
      for (const a of m[3].matchAll(/([\w:-]+)(?:\s*=\s*(?:"([^"]*)"|'([^']*)'|([^\s>]+)))?/g)) {
        attrs[a[1].toLowerCase()] = decode(a[2] ?? a[3] ?? a[4] ?? "");
      }
      const el = new Element(tag, attrs);
      top.childNodes.push(el);
      if (!VOID.has(tag) && !m[3].trim().endsWith("/")) stack.push(el);
    }
    return root;
  }
}

function run(page, host = "jwxt.njfu.edu.cn", status = 200) {
  const requests = [];
  class XMLHttpRequest {
    open(method, url, async) { this.method = method; this.url = url; this.async = async; }
    send() {
      assert.equal(this.async, false, "教务请求必须是同步的，脚本的返回值才是完成值");
      requests.push({ method: this.method, url: this.url });
      this.status = status;
      this.responseText = page;
    }
  }
  // 与 WebImporterView 一致：包在 try 里，取脚本的完成值。
  const wrapped = `try {\n${script}\n} catch (error) {\n"NAP_ERROR:" + (error && error.message ? error.message : String(error));\n}`;
  const value = vm.runInNewContext(wrapped, { XMLHttpRequest, DOMParser, location: { host }, JSON, Date, Math, Set, Array, Object, String, Number, parseInt, isNaN });
  return { value, requests };
}

// MARK: 强智课表页

const course = (name, teacher, timing, room, extra = "") =>
  `${name}<br/>${extra}<font title='老师'>${teacher}</font><br/><font title='周次(节次)'>${timing}</font><br/><font title='教室'>${room}</font><br/>`;
const cell = (full, brief = "") =>
  `<td valign="top" align="center"><div class="kbcontent1">${brief}</div><div class="kbcontent" style="display: none;">${full}</div></td>`;
const empty = cell("&nbsp;", "&nbsp;");
const row = (label, cells) => `<tr><th>${label}</th>${cells.join("")}</tr>`;

const page = `<!DOCTYPE html><html><head><title>学期理论课表</title></head><body>
<form><select id="xnxq01id" name="xnxq01id">
<option value="2026-2027-1" selected="selected">2026-2027-1</option>
<option value="2025-2026-2">2025-2026-2</option>
</select></form>
<table id="timetable" class="Nsb_r_list">
<tr><th>&nbsp;</th><th>星期一</th><th>星期二</th><th>星期三</th><th>星期四</th><th>星期五</th><th>星期六</th><th>星期日</th></tr>
${row("第一大节", [
  cell(course("高等数学A(一)", "张三", "1-16(周)[01-02节]", "逸夫楼301")
    + "---------------------<br>"
    + course("军事理论", "李四", "1-8,10-16(周)[01-02节]", "图书馆报告厅", "<font name='xsks' style='display:none'>32</font>")),
  empty, empty, empty, empty, empty, empty,
])}
${row("第二大节", [
  empty,
  cell(course("大学物理", "王五", "1-15(单周)[03-04节]", "理科楼B203")),
  empty,
  // 同一门课在一格里出现两次只保留一条。
  cell(course("体育", "赵六", "2,4,6(周)[03-04节]", "田径场") + "-----<br>" + course("体育", "赵六", "2,4,6(周)[03-04节]", "田径场")),
  empty, empty, empty,
])}
${row("第三大节", [empty, empty, empty, empty, empty, empty, empty])}
${row("第四大节", [empty, empty, empty, empty, empty, empty, empty])}
${row("第五大节", [
  empty, empty, empty, empty,
  cell(course("形势与政策", "钱七", "2-16(双周)[09-10-11节]", "")),
  empty,
  // 周次里没写节次时按所在大节兜底。
  cell(course("选修课", "孙八", "3-10(周)", "木工馆")),
])}
<tr><td colspan="7">备注：实践课程 创新创业训练 1-16周</td></tr>
</table></body></html>`;

{
  const { value, requests } = run(page);
  assert.equal(typeof value, "string");
  assert.ok(!value.startsWith("NAP_ERROR"), value);
  const out = JSON.parse(value);
  assert.equal(out.name, "2026-2027学年第1学期");
  assert.equal(requests.length, 1);
  assert.equal(requests[0].method, "GET");
  assert.match(requests[0].url, /^\/jsxsd\/xskb\/xskb_list\.do\?_t=\d+$/);
  assert.equal(out.courses.length, 6, "重复的体育只保留一条");
  const [math, military, physics, pe, policy, elective] = out.courses;
  assert.deepEqual(math, { name: "高等数学A(一)", teacher: "张三", classroom: "逸夫楼301",
    weeks: Array.from({ length: 16 }, (_, i) => i + 1), week_time: 1, start_time: 1, time_count: 1, info: "1-16(周)[01-02节]" });
  assert.equal(military.name, "军事理论", "分隔线后的课程、隐藏学时字段不当课程名");
  assert.deepEqual(military.weeks, [1, 2, 3, 4, 5, 6, 7, 8, 10, 11, 12, 13, 14, 15, 16]);
  assert.equal(military.week_time, 1);
  assert.deepEqual(physics.weeks, [1, 3, 5, 7, 9, 11, 13, 15]);
  assert.equal(physics.week_time, 2);
  assert.equal(physics.start_time, 3);
  assert.deepEqual(pe.weeks, [2, 4, 6]);
  assert.equal(pe.week_time, 4);
  assert.deepEqual(policy.weeks, [2, 4, 6, 8, 10, 12, 14, 16]);
  assert.equal(policy.start_time, 9);
  assert.equal(policy.time_count, 2);
  assert.equal(policy.classroom, "", "缺失地点不产生占位文字");
  assert.equal(elective.week_time, 7);
  assert.equal(elective.start_time, 9, "没写节次时按第五大节兜底");
  assert.equal(elective.time_count, 2);
}

{
  // 没有学期下拉框时，从页面文字里找学期。
  const bare = page.replace(/<select[\s\S]*?<\/select>/, "<span>2025-2026-2 学期理论课表</span>");
  assert.equal(JSON.parse(run(bare).value).name, "2025-2026学年第2学期");
}

// 登录失效：课表地址返回跳回统一认证的脚本页。
const redirect = "<script>location.href='https://uia.njfu.edu.cn/authserver/login?service=http%3A%2F%2Fjwxt.njfu.edu.cn%2Fjsxsd%2Fxskb%2Fxskb_list.do'</script>";
assert.match(run(redirect).value, /^NAP_ERROR:登录已失效/);
assert.match(run("", undefined, 500).value, /^NAP_ERROR:.*HTTP 500/);
assert.match(run("<html><body>系统维护中</body></html>").value, /^NAP_ERROR:.*没有返回课表/);
// 还停在统一认证页时不发请求，提示先登录。
{
  const { value, requests } = run(page, "uia.njfu.edu.cn");
  assert.match(value, /^NAP_ERROR:请先登录/);
  assert.equal(requests.length, 0);
}

console.log("NJFU extractor checks passed");
