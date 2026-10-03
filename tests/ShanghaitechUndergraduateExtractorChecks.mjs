import { readFileSync } from "node:fs";
import vm from "node:vm";
import assert from "node:assert/strict";

const swift = readFileSync(new URL("../NapTable/Import/ShanghaitechUndergraduateExtractor.swift", import.meta.url), "utf8");
const script = swift.slice(swift.indexOf('#"""') + 4, swift.lastIndexOf('"""#'))
  .split("\n").map((line) => line.replace(/^    /, "")).join("\n");
const importer = readFileSync(new URL("../NapTable/Import/WebImporterView.swift", import.meta.url), "utf8");
const wrapper = importer.match(/let script = """\s*(try \{\s*\\\(extract\)[\s\S]*?)\s*"""/)[1].replace("\\(extract)", script);
const origin = "https://eams.shanghaitech.edu.cn";

class Element {
  constructor(text = "", children = [], tag = "td") {
    this.innerText = text;
    this.textContent = text;
    this.children = children;
    this.tagName = tag.toUpperCase();
    this.options = undefined;
    this.selectedIndex = undefined;
  }
  querySelectorAll(selector) {
    if (selector === "tr") return this.children.filter((child) => child.tagName === "TR");
    if (selector === "th,td") return this.children.filter((child) => ["TH", "TD"].includes(child.tagName));
    if (selector === "th") return this.children.filter((child) => child.tagName === "TH");
    if (selector === "td") return this.children.filter((child) => child.tagName === "TD");
    return [];
  }
}

function row(values, header = false) {
  return new Element("", values.map((value) => new Element(value, [], header ? "th" : "td")), "tr");
}

function run(table, options = {}) {
  const location = { origin: options.origin ?? origin, pathname: options.pathname ?? "/eams/student/course-table.action" };
  location.href = location.origin + location.pathname;
  const body = new Element(options.body ?? "2026-2027学年第一学期 我的课表");
  const document = {
    body,
    querySelectorAll: (selector) => selector === "table" ? [table] : [],
    querySelector: () => null,
  };
  const value = vm.runInNewContext(wrapper, { document, location });
  return value;
}

const detail = new Element("", [
  row(["课程代码", "课程名称", "教师", "上课时间", "上课地点", "备注"], true),
  row(["CS101", "程序设计", "张老师", "1-3周 周一 1-2节; 4-6周 周三 3-4节", "教学中心101", "必修"]),
  row(["MA201", "高等数学", "李老师", "2-8周（双） 星期六 第10-13节", "教学中心202", ""]),
]);
const detailResult = JSON.parse(run(detail));
assert.equal(detailResult.name, "2026-2027学年第一学期");
assert.equal(detailResult.courses.length, 3);
assert.deepEqual(detailResult.courses[0], {
  name: "程序设计", classroom: "教学中心101", class_number: "CS101", teacher: "张老师",
  weeks: [1, 2, 3], week_time: 1, start_time: 1, time_count: 1, import_type: 1, info: "必修",
});
assert.deepEqual(detailResult.courses[1].weeks, [4, 5, 6]);
assert.equal(detailResult.courses[1].week_time, 3);
assert.equal(detailResult.courses[2].week_time, 6);
assert.equal(detailResult.courses[2].start_time, 10);
assert.equal(detailResult.courses[2].time_count, 3);

const splitColumns = new Element("", [
  row(["课程名称", "周次", "星期", "节次", "教师", "地点"], true),
  row(["线性代数", "1-16周", "星期二", "3-4节", "王老师", "教学中心303"]),
]);
const splitResult = JSON.parse(run(splitColumns));
assert.equal(splitResult.courses.length, 1);
assert.equal(splitResult.courses[0].name, "线性代数");
assert.equal(splitResult.courses[0].week_time, 2);
assert.equal(splitResult.courses[0].start_time, 3);
assert.deepEqual(splitResult.courses[0].weeks, Array.from({ length: 16 }, (_, i) => i + 1));

const grid = new Element("", [
  row(["节次/周次", "星期一", "星期二", "星期三", "星期四", "星期五", "星期六", "星期日"], true),
  row(["1", "程序设计\n周一 1-2节 1-16周\n教学中心101", "", "", "", "", "", ""]),
]);
const gridResult = JSON.parse(run(grid));
assert.equal(gridResult.courses.length, 1);
assert.equal(gridResult.courses[0].name, "程序设计");
assert.equal(gridResult.courses[0].week_time, 1);
assert.deepEqual(gridResult.courses[0].weeks, Array.from({ length: 16 }, (_, i) => i + 1));

for (const options of [
  { origin: "https://ids.shanghaitech.edu.cn" },
  { pathname: "/authserver/login" },
  { body: "统一身份认证 请输入密码" },
]) {
  assert.match(run(detail, options), /^NAP_WAIT:/);
}
assert.match(run(new Element("", [row(["课程名称", "上课时间"], true)]) , { body: "本科教务系统首页" }), /^NAP_WAIT:/);
assert.match(run(detail, { origin: "https://eams.shanghaitech.edu.cn.evil.example" }), /^NAP_WAIT:/);

console.log("ShanghaiTech undergraduate extractor checks passed: EAMS detail/grid tables, semester, split sessions, weekends, odd/even weeks and page readiness");
