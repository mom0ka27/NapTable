import { readFileSync } from "node:fs";
import vm from "node:vm";
import assert from "node:assert/strict";

const swift = readFileSync(new URL("../NapTable/Import/ShanghaitechExtractor.swift", import.meta.url), "utf8");
const script = swift.slice(swift.indexOf('#"""') + 4, swift.lastIndexOf('"""#'))
  .split("\n").map((line) => line.replace(/^    /, "")).join("\n");
const importer = readFileSync(new URL("../NapTable/Import/WebImporterView.swift", import.meta.url), "utf8");
const wrapper = importer.match(/let script = """\s*(try \{\s*\\\(extract\)[\s\S]*?)\s*"""/)[1].replace("\\(extract)", script);
const origin = "https://graduate.shanghaitech.edu.cn";
const modulePath = "/gsapp/sys/wdkbappshtech/";
const row = {
  KCDM: "TEST1001", KCMC: "示例课程", BJDM: "CLASS-01", BJMC: "示例教学班",
  ZCMC: "1-3,5周", XQ: "4", KSJCDM: "2", JSJCDM: "4",
  JGJSXM: "示例教师", JASMC: "教学楼 101", JCFADM: "01",
};

function run(payload, options = {}) {
  const requests = [];
  const select = options.noTerm ? null : {
    value: options.termCode ?? "school-term-20261", selectedIndex: 0,
    options: [{ textContent: options.termLabel ?? "2026-2027学年第一学期" }],
  };
  class XMLHttpRequest {
    open(method, url, async) { Object.assign(this, { method, url, async }); }
    setRequestHeader(key, value) { (this.headers ||= {})[key] = value; }
    send(body) {
      assert.equal(this.async, false);
      requests.push({ method: this.method, url: this.url, headers: this.headers, body });
      if (options.networkFailure) throw new Error("private network information");
      this.status = options.status ?? 200;
      this.responseURL = options.responseURL ?? this.url;
      this.responseText = typeof payload === "string" ? payload : JSON.stringify(payload);
      if (options.changeTerm) select.value = "different-term";
    }
  }
  const courseDocument = { getElementById: (id) => id === "query_xnxq" ? select : null };
  const courseWindow = { XMLHttpRequest, location: { origin, pathname: modulePath + "*default/index.do" } };
  if (options.unreadyFrame) courseWindow.location = { origin: "null", pathname: "blank" };
  const frame = {
    src: options.frameURL ?? origin + modulePath + "*default/index.do",
    contentWindow: courseWindow, contentDocument: options.noFrameDocument ? null : courseDocument,
  };
  const location = {
    origin: options.origin ?? origin,
    pathname: options.direct ? modulePath + "*default/index.do" : "/gsapp/sys/yjsemaphome/portal/index.do",
  };
  location.href = location.origin + location.pathname;
  const document = options.direct ? courseDocument : { getElementById: (id) =>
    id === "iframeContent_wdkbappshtechxskcb" && !options.noFrame ? frame : null };
  const value = vm.runInNewContext(wrapper, { document, window: courseWindow, location, URL, XMLHttpRequest });
  return { value, requests };
}

const payload = { jgList: [
  row, { ...row },
  { ...row, ZCMC: "9,14周", XQ: "6", KSJCDM: 10, JSJCDM: 13, JGJSXM: "另一位教师", JASMC: "教学楼 202" },
  { ...row, ZCMC: "4周", XQ: 7, KSJCDM: 1, JSJCDM: 1, JGJSXM: "", JASMC: "" },
] };
for (const direct of [false, true]) {
  const { value, requests } = run(payload, { direct });
  assert.ok(!value.startsWith("NAP_"), value);
  const result = JSON.parse(value);
  assert.equal(result.name, "上海科技大学研究生课表 2026-2027学年第一学期");
  assert.equal(result.termID, undefined, "学校内部学期代码不能当作服务端 termID");
  assert.equal(requests.length, 1);
  assert.equal(requests[0].method, "POST");
  assert.equal(requests[0].url, origin + modulePath + "xskbBy/loadPkjg.do");
  assert.equal(requests[0].body, "XNXQDM=school-term-20261&ZC=", "必须使用选择器原始学期代码，查询全学期");
  assert.equal(requests[0].headers["X-Requested-With"], "XMLHttpRequest");
  assert.equal(result.courses.length, 4);
  assert.deepEqual(result.courses[0], {
    name: "示例课程", classroom: "教学楼 101", class_number: "TEST1001", teacher: "示例教师",
    weeks: [1, 2, 3, 5], week_time: 4, start_time: 2, time_count: 2, import_type: 1, info: "示例教学班",
  });
  assert.deepEqual(result.courses[1], result.courses[0], "学校返回的重复记录仍交给导入预览处理");
  assert.deepEqual(result.courses[2].weeks, [9, 14]);
  assert.equal(result.courses[2].week_time, 6);
  assert.equal(result.courses[2].start_time, 10);
  assert.equal(result.courses[2].time_count, 3);
  assert.equal(result.courses[2].teacher, "另一位教师");
  assert.equal(result.courses[2].classroom, "教学楼 202");
  assert.equal(result.courses[3].week_time, 7);
  assert.equal(result.courses[3].time_count, 0);
}

for (const [pattern, expected] of [
  ["1-16周", Array.from({ length: 16 }, (_, i) => i + 1)],
  ["1-3,5-8周", [1, 2, 3, 5, 6, 7, 8]],
  ["第1～3周，5周、7－9周", [1, 2, 3, 5, 7, 8, 9]],
  ["1-3,5-9周(单)", [1, 3, 5, 7, 9]],
  ["2-8周（双）", [2, 4, 6, 8]],
  ["1-3单,6-10双", [1, 3, 6, 8, 10]],
]) {
  assert.deepEqual(JSON.parse(run({ jgList: [{ ...row, ZCMC: pattern }] }).value).courses[0].weeks, expected);
}
assert.equal(JSON.parse(run({ jgList: [] }).value).courses.length, 0);
assert.match(run(payload, { termCode: "term/a&b" }).requests[0].body, /^XNXQDM=term%2Fa%26b&ZC=$/);
assert.match(JSON.parse(run(payload, { termLabel: "2026-2027学年第二学期" }).value).name, /第二学期/);

for (const options of [
  { noFrame: true }, { noTerm: true }, { noFrameDocument: true }, { unreadyFrame: true },
  { frameURL: "https://evil.example/gsapp/sys/wdkbappshtech/" },
  { frameURL: origin + "/gsapp/unrelated/" }, { origin: "https://ids.shanghaitech.edu.cn" },
  { origin: "https://graduate.shanghaitech.edu.cn.evil.example" },
]) {
  const result = run(payload, options);
  assert.match(result.value, /^NAP_WAIT:/);
  assert.equal(result.requests.length, 0, "页面未就绪或域名不匹配时不得请求课表接口");
}
for (const status of [401, 403]) assert.match(run(payload, { status }).value, /^NAP_ERROR:登录已失效/);
assert.match(run(payload, { status: 503 }).value, /^NAP_ERROR:上海科技大学课表接口返回 HTTP 503/);
assert.match(run("<html>login</html>").value, /^NAP_ERROR:登录已失效/);
assert.match(run(payload, { responseURL: "https://ids.shanghaitech.edu.cn/login" }).value, /^NAP_ERROR:登录已失效/);
assert.match(run({ code: 401 }).value, /^NAP_ERROR:登录已失效/);
assert.match(run("invalid-json private data").value, /^NAP_ERROR:.*数据格式已变化/);
assert.match(run({}).value, /^NAP_ERROR:.*缺少排课结果/);
assert.match(run(payload, { networkFailure: true }).value, /^NAP_ERROR:无法连接/);
assert.match(run(payload, { changeTerm: true }).value, /^NAP_ERROR:读取期间学期已切换/);
assert.match(run(payload, { termLabel: "" }).value, /^NAP_ERROR:无法读取课表学期名称/);
for (const bad of [
  null, { ...row, KCMC: "" }, { ...row, XQ: 8 }, { ...row, XQ: "3abc" },
  { ...row, KSJCDM: 0 }, { ...row, JSJCDM: 1 }, { ...row, JSJCDM: 65 },
  ...["", "待定", "5-1周", "0周", "41周", "1-3,未知周"].map((ZCMC) => ({ ...row, ZCMC })),
]) {
  assert.match(run({ jgList: [row, bad] }).value, /^NAP_ERROR:部分排课数据不完整/,
    "不完整响应必须停止整次导入，不能静默遗漏课程");
}

console.log("ShanghaiTech extractor checks passed: iframe/direct module, selected term, full-semester POST, weeks, weekends, variable periods, validation and login failures");
