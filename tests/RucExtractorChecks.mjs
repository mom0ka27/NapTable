// 用一个最小 DOM 验证人大本科与研究生课表的星期、节次、周次和学期名。
import { readFileSync } from "node:fs";
import vm from "node:vm";
import assert from "node:assert/strict";

const swift = readFileSync(new URL("../NapTable/Import/RucExtractor.swift", import.meta.url), "utf8");
const script = swift.slice(swift.indexOf('#"""') + 4, swift.lastIndexOf('"""#'));

class Node {
  constructor(tag, text = "", attrs = {}, children = []) {
    this.tagName = tag.toUpperCase();
    this.nodeType = 1;
    this._text = text;
    this.attrs = attrs;
    this.childNodes = children;
    this.style = { display: attrs.style === "display:none" ? "none" : "" };
    this.value = attrs.value || "";
    this.selectedOptions = [];
  }
  get children() { return this.childNodes.filter((node) => node.nodeType === 1); }
  get rows() { return this.tagName === "TABLE" ? this.children.filter((node) => node.tagName === "TR") : undefined; }
  get cells() { return (this.tagName === "TR" || this.tagName === "TABLE") ? this.children.filter((node) => ["TD", "TH"].includes(node.tagName)) : undefined; }
  get textContent() { return this._text + this.childNodes.map((node) => node.textContent).join(""); }
  getAttribute(name) { return this.attrs[name] ?? null; }
  getClientRects() { return this.style.display === "none" || this.attrs.hidden != null ? [] : [{}]; }
  walk() { return this.children.flatMap((child) => [child, ...child.walk()]); }
  matches(selector) {
    const base = selector.trim();
    if (base === "*") return true;
    if (base.startsWith("#")) return this.attrs.id === base.slice(1);
    if (base.startsWith(".")) return base.split(".").slice(1).every((name) => (this.attrs.class || "").split(/\s+/).includes(name));
    const tagAttr = base.match(/^([a-zA-Z]+)?((?:\[[^\]]+\])*)$/);
    if (!tagAttr) return false;
    if (tagAttr[1] && this.tagName !== tagAttr[1].toUpperCase()) return false;
    for (const attr of tagAttr[2].matchAll(/\[([^\]=*]+)(?:([*]?=)['"]?([^\]'"]+)['"]?)?\]/g)) {
      const key = attr[1];
      const value = this.attrs[key];
      if (value == null) return false;
      if (attr[2] === "=" && value !== attr[3]) return false;
      if (attr[2] === "*=" && !value.includes(attr[3])) return false;
    }
    return true;
  }
  querySelectorAll(selector) {
    if (selector.includes(",")) {
      const parts = selector.split(",").map((part) => part.trim());
      return this.walk().filter((node) => parts.some((part) => node.matches(part)));
    }
    const parts = selector.split(/\s+/).filter(Boolean);
    let current = [this];
    for (const part of parts) {
      current = current.flatMap((node) => node.walk().filter((candidate) => candidate.matches(part)));
    }
    return [...new Set(current)];
  }
  querySelector(selector) { return this.querySelectorAll(selector)[0] || null; }
}

const leaf = (text, attrs = {}) => new Node("div", text, attrs);
const card = new Node("div", "", {}, [
  leaf("高等数学", { style: "color: rgb(0, 192, 239)" }),
  leaf("张三"),
  leaf("立德407/1-2节/1-4周"),
  leaf("英语", { style: "color: rgb(0, 192, 239)" }),
  leaf("教一1406/3-4节/1-6周双周"),
]);
const table = new Node("table", "", {}, [
  new Node("tr", "", {}, [new Node("th", "星期"), new Node("td", "", {}, [card])]),
]);
const semester = new Node("input", "", { value: "2026-2027学年 第1学期" });
const document = new Node("document", "", {}, [table, semester]);
document.body = document;

const value = vm.runInNewContext(script, {
  document,
  encodeURIComponent,
  JSON,
  Map,
  Set,
  Array,
  Number,
  String,
  Math,
  Object,
  RegExp,
});
const result = JSON.parse(decodeURIComponent(value));
assert.equal(result.name, "2026-2027学年秋季学期");
assert.equal(result.courses.length, 2);
assert.deepEqual(result.courses[0].weeks, [1, 2, 3, 4]);
assert.equal(result.courses[0].week_time, 1);
assert.equal(result.courses[0].start_time, 1);
assert.equal(result.courses[0].time_count, 1);
assert.equal(result.courses[1].classroom, "教一1406");
assert.deepEqual(result.courses[1].weeks, [2, 4, 6]);

const extract = (nodes) => {
  const doc = new Node("document", "", {}, nodes);
  doc.body = doc;
  return JSON.parse(decodeURIComponent(vm.runInNewContext(script, { document: doc })));
};
const undergraduateCell = (name, timing, attrs = {}, inline = false) => new Node("td", "", attrs, [
  new Node("div", "", {}, [
    leaf(name, { style: "color: rgb(0, 192, 239)" }),
    inline ? new Node("div", "", {}, [new Node("span", timing)]) : leaf(timing),
  ]),
]);

// 一整周：单节、单周、不连续周与行内标签不能让整列课程消失。
const weekTable = new Node("table", "", {}, [
  new Node("tr", "", {}, [new Node("th", "节次"),
    ...["一", "二", "三", "四", "五", "六", "日"].map((day) => new Node("th", `星期${day}`))]),
  new Node("tr", "", {}, [new Node("th", "第一节"),
    undergraduateCell("周一课程", "立德101/1-2节/1-16周"),
    undergraduateCell("周二课程", "立德102/3节/1-16周"),
    undergraduateCell("周三课程", "立德103/5-6节/1,3,5-8周"),
    undergraduateCell("周四课程", "立德104/7-8节/1-16周单周"),
    undergraduateCell("周五课程", "立德105/9-10节/2-16周双周"),
    undergraduateCell("周六课程", "立德106 / 1-2节 / 第2周", {}, true),
    undergraduateCell("周日课程", "立德107/3-4节/1-16周"),
  ]),
]);
const weekResult = extract([weekTable]);
assert.equal(weekResult.courses.length, 7);
assert.deepEqual(weekResult.courses.map((course) => course.week_time), [1, 2, 3, 4, 5, 6, 7]);
assert.equal(weekResult.courses[1].time_count, 0);
assert.deepEqual(weekResult.courses[2].weeks, [1, 3, 5, 6, 7, 8]);
assert.deepEqual(weekResult.courses[5].weeks, [2]);
assert.equal(weekResult.courses[5].classroom, "立德106");

// 两个左侧表头、rowspan 和 colspan 共同决定真实星期列，不能直接用 cells 的索引。
const spanTable = new Node("table", "", {}, [
  new Node("tr", "", {}, [new Node("th", "时段", { colspan: "2" }),
    ...["一", "二", "三", "四", "五", "六", "日"].map((day) => new Node("th", `周${day}`))]),
  new Node("tr", "", {}, [new Node("th", "上午", { rowspan: "2" }), new Node("th", "第一节"),
    undergraduateCell("周一连堂", "立德101/1-2节/1-16周", { rowspan: "2" }),
    ...Array.from({ length: 6 }, () => new Node("td"))]),
  new Node("tr", "", {}, [new Node("th", "第二节"),
    undergraduateCell("周二第二节", "立德102/2-3节/1-16周"),
    undergraduateCell("周三第二节", "立德103/2-3节/1-16周"),
    ...Array.from({ length: 4 }, () => new Node("td"))]),
]);
const spanResult = extract([spanTable]);
assert.deepEqual(spanResult.courses.map((course) => [course.name, course.week_time]), [
  ["周一连堂", 1], ["周二第二节", 2], ["周三第二节", 3],
]);

// 整张表只有单节课程时也能发现课表；同一课名后连续给出多个地点/时间。
const multiSlotCell = new Node("td", "", {}, [
  leaf("体育"), leaf("体育场／1节／1-16周"),
]);
multiSlotCell.childNodes.push(leaf("体育馆/1节/1-16周"));
const singleSlotResult = extract([new Node("table", "", {}, [
  new Node("tr", "", {}, [new Node("th", "第一节"), multiSlotCell]),
])]);
assert.equal(singleSlotResult.courses.length, 2);
assert.deepEqual(singleSlotResult.courses.map((course) => course.classroom), ["体育场", "体育馆"]);
assert.ok(singleSlotResult.courses.every((course) => course.name === "体育" && course.time_count === 0));

const separatorResult = extract([new Node("table", "", {}, [
  new Node("tr", "", {}, [new Node("th", "节次"),
    undergraduateCell("分隔符课程", "至善楼/1～2节/1至8周（单周）"),
  ]),
])]);
assert.equal(separatorResult.courses[0].classroom, "至善楼");
assert.deepEqual(separatorResult.courses[0].weeks, [1, 3, 5, 7]);

// 按人大公开 student.course.list.js 的组件字段构造匿名课程数据。
// 实际页面的星期日可能位于最前；cellData.column.property 才是课程的星期。
// 无教室时 item.zc 从节次开始，不能因为少了“教室/”就卡在重试。
const componentItem = (name, timing, js = "", lsname = "王老师") => ({
  kcname: name, zc: timing, js, lsname,
});
const componentCell = (weekday, items) => {
  const cell = new Node("div", "", { class: "cell xsb-hover" });
  cell.__vue__ = { cellData: { column: { property: `xq${weekday}` }, row: { [`xq${weekday}`]: items } } };
  return cell;
};
const saturdayItem = componentItem("周六课", "1-2节/1-16周", "", "周老师");
const componentResult = extract([
  componentCell(7, [componentItem("周日课", "立德101/1-2节/1-16周")]),
  componentCell(1, [componentItem("周一课", "立德102/1-2节/1-16周")]),
  componentCell(2, [componentItem("周二课", "立德103/3-4节/1-16周")]),
  componentCell(3, [componentItem("周三课", "立德104/5-6节/1-16周")]),
  componentCell(4, [componentItem("周四课", "立德105/7-8节/1-16周")]),
  componentCell(5, [componentItem("周五课", "立德106/9-10节/1-16周")]),
  componentCell(6, [saturdayItem, { ksjms: true, id: "exam-marker" }]),
  componentCell(6, [saturdayItem]), // 合并行的数据会在多个单元格中重复出现。
  semester,
]);
assert.equal(componentResult.courses.length, 7);
assert.deepEqual(componentResult.courses.map((course) => course.week_time), [7, 1, 2, 3, 4, 5, 6]);
const saturdayCourse = componentResult.courses.find((course) => course.name === "周六课");
assert.equal(saturdayCourse.week_time, 6);
assert.equal(saturdayCourse.classroom, "");
assert.equal(saturdayCourse.teacher, "周老师");
assert.deepEqual(saturdayCourse.weeks, Array.from({ length: 16 }, (_, index) => index + 1));
assert.equal(componentResult.name, "2026-2027学年秋季学期");

const noRoomDOM = extract([new Node("table", "", {}, [new Node("tr", "", {}, [
  new Node("th", "节次"), undergraduateCell("未指定教室", "3-4节/1-16周"),
])])]);
assert.equal(noRoomDOM.courses[0].classroom, "");
assert.equal(noRoomDOM.courses[0].start_time, 3);

// 不认识的上课时间明确报错，不应返回一份缺课的导入结果。
assert.throws(() => extract([new Node("table", "", {}, [
  new Node("tr", "", {}, [new Node("th", "节次"),
    undergraduateCell("能识别的课程", "立德101/1-2节/1-16周"),
    undergraduateCell("格式变化的课程", "立德102/3-4节/待确认周次"),
  ]),
])]), /无法识别的上课安排/);

// 研究生网格：课程代码映射、跨两节合并、选中学期和地点字段。
const gradCard = new Node("div", "", { class: "arrage kb_item" }, [
  leaf("1-4周"), leaf("ABC123-课程简称"), leaf("李老师"), leaf("立德407"),
]);
const gradCell = new Node("td", "", { xq: "2", jc: "3", rowspan: "2" }, [gradCard]);
const gradTable = new Node("table", "", { id: "jsTbl_01" }, [new Node("tr", "", {}, [gradCell])]);
const nameTable = new Node("table", "", {}, [
  new Node("tr", "", {}, [new Node("th", "课程代码"), new Node("th", "课程名称")]),
  new Node("tr", "", {}, [new Node("td", "ABC123"), new Node("td", "研究生英语")]),
]);
const termSelect = new Node("select", "", { id: "query_xnxq" }, [new Node("option", "2026-2027学年 第1学期")]);
termSelect.selectedOptions = termSelect.children;
const graduateDocument = new Node("document", "", {}, [gradTable, nameTable, termSelect]);
graduateDocument.body = graduateDocument;
const graduateValue = vm.runInNewContext(script, {
  document: graduateDocument,
  encodeURIComponent, JSON, Map, Set, Array, Number, String, Math, Object, RegExp,
});
const graduateResult = JSON.parse(decodeURIComponent(graduateValue));
assert.equal(graduateResult.name, "2026-2027学年秋季学期");
assert.equal(graduateResult.courses.length, 1);
assert.equal(graduateResult.courses[0].name, "研究生英语");
assert.equal(graduateResult.courses[0].week_time, 2);
assert.equal(graduateResult.courses[0].start_time, 3);
assert.equal(graduateResult.courses[0].time_count, 1);
assert.deepEqual(graduateResult.courses[0].weeks, [1, 2, 3, 4]);

// 研究生星期来自 xq 属性，连堂节次、单双周与同源 iframe 都需要保留。
const graduateWeekDocument = new Node("document", "", {}, [new Node("table", "", { id: "jsTbl_01" }, [
  new Node("tr", "", {}, Array.from({ length: 7 }, (_, index) => new Node("td", "", {
    xq: String(index + 1), jc: "3", rowspan: "2",
  }, [new Node("div", "", { class: "arrage kb_item" }, [
    leaf(index % 2 ? "2-8周双周" : "1-7周单周"),
    leaf(`ABC${index + 1}-研究生课程${index + 1}`), leaf("李老师"), leaf("立德407"),
  ])]))),
])]);
graduateWeekDocument.body = graduateWeekDocument;
const frame = new Node("iframe");
frame.contentDocument = graduateWeekDocument;
const graduateWeekResult = extract([frame]);
assert.deepEqual(graduateWeekResult.courses.map((course) => course.week_time), [1, 2, 3, 4, 5, 6, 7]);
assert.deepEqual(graduateWeekResult.courses[1].weeks, [2, 4, 6, 8]);
assert.ok(graduateWeekResult.courses.every((course) => course.start_time === 3 && course.time_count === 1));

const loginDocument = new Node("document", "", {}, [new Node("input", "", { type: "password" })]);
loginDocument.body = loginDocument;
assert.throws(
  () => vm.runInNewContext(script, { document: loginDocument, encodeURIComponent, JSON, Map, Set, Array, Number, String, Math, Object, RegExp }),
  (error) => error.name === "NapTableNotReady" && /请先登录中国人民大学教务系统/.test(error.message)
);

const emptyDocument = new Node("document");
emptyDocument.body = emptyDocument;
assert.throws(
  () => vm.runInNewContext(script, { document: emptyDocument }),
  (error) => error.name === "NapTableNotReady" && /尚未读取到/.test(error.message)
);

// 验证 App 实际注入的 try/catch，页面未就绪与格式异常必须走不同结果通道。
const importer = readFileSync(new URL("../NapTable/Import/WebImporterView.swift", import.meta.url), "utf8");
const pageStateScript = importer.match(/let rucPageStateScript = """([\s\S]*?)"""/)[1];
const pageState = (doc, pathname, qz, app) => JSON.parse(JSON.stringify(vm.runInNewContext(pageStateScript, {
  document: doc, location: { pathname }, Qz: qz, window: { app },
  getComputedStyle: (element) => ({ visibility: element.attrs.visibility || "visible" }),
})));
assert.deepEqual(pageState(loginDocument, "/cas/login", undefined, undefined), { login: true, ready: false });
assert.deepEqual(pageState(emptyDocument, "/Njw2017/index.html", { loginUser: { userType: "student" } }, undefined), { login: false, ready: false });
const portalApp = { $router: {}, $store: {} };
assert.deepEqual(pageState(emptyDocument, "/Njw2017/index.html", { loginUser: { userType: "student" } }, portalApp), { login: false, ready: true });
const hiddenPasswordDocument = new Node("document", "", {}, [new Node("input", "", { type: "password", style: "display:none" })]);
assert.deepEqual(pageState(hiddenPasswordDocument, "/Njw2017/index.html", { loginUser: { userType: "student" } }, portalApp), { login: false, ready: true });
const navigationScript = importer.match(/let rucTimetableNavigationScript = """([\s\S]*?)"""/)[1];
const routerPaths = [];
const homeLocation = { hash: "#/" };
assert.equal(vm.runInNewContext(navigationScript, {
  window: { app: { $router: { replace: (path) => routerPaths.push(path) } } }, location: homeLocation,
}), true);
assert.deepEqual(routerPaths, ["/student/student-course-list/"]);
assert.equal(homeLocation.hash, "#/");
const fallbackLocation = { hash: "#/" };
assert.equal(vm.runInNewContext(navigationScript, { window: {}, location: fallbackLocation }), true);
assert.equal(fallbackLocation.hash, "/student/student-course-list/");
const wrapper = importer.match(/let script = """\s*(try \{\s*\\\(extract\)[\s\S]*?)\s*"""/)[1].replace("\\(extract)", script);
assert.ok(vm.runInNewContext(wrapper, { document: loginDocument }).startsWith("NAP_WAIT:"));
assert.ok(vm.runInNewContext(wrapper, { document: emptyDocument }).startsWith("NAP_WAIT:"));
assert.deepEqual(JSON.parse(decodeURIComponent(vm.runInNewContext(wrapper, { document }))), result);
// 页面已经显示课表时，隐藏的登录/改密码表单不能把课表拦在等待登录。
const loggedInResult = extract([table, semester, new Node("input", "", { type: "password", style: "display:none" })]);
assert.deepEqual(loggedInResult, result);
const badDocument = new Node("document", "", {}, [new Node("table", "", {}, [
  new Node("tr", "", {}, [new Node("th", "节次"),
    undergraduateCell("未知格式", "立德102/3-4节/待确认周次"),
  ]),
])]);
badDocument.body = badDocument;
const badValue = vm.runInNewContext(wrapper, { document: badDocument });
assert.ok(badValue.startsWith("NAP_ERROR:"));
assert.match(badValue, /无法识别的上课安排/);
// 周六表头格式不认识时必须报出具体错误，不能静默丢掉周六或无限重试。
assert.throws(() => extract([new Node("table", "", {}, [
  new Node("tr", "", {}, [new Node("th", "节次"),
    ...["周一", "周二", "周三", "周四", "周五", "周末", "周日"].map((label) => new Node("th", label))]),
  new Node("tr", "", {}, [new Node("th", "节次"),
    ...Array.from({ length: 5 }, () => new Node("td")),
    undergraduateCell("周六缺失课程", "立德106/1-2节/1-16周"), new Node("td"),
  ]),
])]), (error) => error.name !== "NapTableNotReady" && /周六缺失课程.*星期/.test(error.message));
console.log("RUC extractor checks passed");
