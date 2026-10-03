// 在 Node 中验证浙江大学 ZDBK 课表提取脚本。
import { readFileSync } from "node:fs";
import vm from "node:vm";
import assert from "node:assert/strict";

const swift = readFileSync(new URL("../NapTable/Import/ZjuExtractor.swift", import.meta.url), "utf8");
const body = swift.slice(swift.indexOf('#"""') + 4, swift.lastIndexOf('"""#'));
const script = body.split("\n").map((line) => line.replace(/^    /, "")).join("\n");

function run(payload, { term = "3", year = "2025", status = 200, origin = "https://zdbk.zju.edu.cn", page = null, clock = "2025-10-01T00:00:00Z" } = {}) {
  const requests = [];
  const fields = {
    "#xnm": { value: year, selectedOptions: [{ value: year, textContent: "2025-2026学年" }] },
    "#xqm": { value: term, selectedOptions: [{ value: term, textContent: term === "12" ? "第二学期" : "第一学期" }] },
  };
  class XMLHttpRequest {
    open(method, url, async) { this.method = method; this.url = url; this.async = async; }
    setRequestHeader(key, value) { (this.headers ||= {})[key] = value; }
    send(body) {
      assert.equal(this.async, false, "教务课表请求必须同步执行");
      requests.push({ method: this.method, url: this.url, headers: this.headers, body });
      this.status = status;
      this.responseText = typeof payload === "string" ? payload : JSON.stringify(payload);
    }
  }
  const wrapped = `try {\n${script}\n} catch (error) {\n"NAP_ERROR:" + (error && error.message ? error.message : String(error));\n}`;
  const RealDate = Date;
  class FixedDate extends RealDate {
    constructor(...args) { super(args.length ? args[0] : clock); }
  }
  const value = vm.runInNewContext(wrapped, {
    XMLHttpRequest,
    document: { querySelector: (selector) => page == null ? (fields[selector] || null) : null,
      body: page == null ? undefined : { innerText: typeof page === "string" ? page : JSON.stringify(page) } },
    location: { origin, pathname: "/jwglxt/kbcx/xskbcx_cxXsKb.html" },
    JSON, Date: FixedDate, Math, Set, Array, Object, String, Number, parseInt, isNaN, encodeURIComponent,
  });
  return { value, requests };
}

const payload = {
  kbList: [
    { kch_id: "MATH-1", kcb: "高等数学<br>教学班<br>张老师<br>紫金港西1-101zwf", xqj: "1", djj: "1", skcd: "2", dsz: "2", zc: "1-16周" },
    { kch_id: "ENG-1", kcb: "大学英语<br>教学班<br>李老师<br>紫金港东2-202zwf", xqj: 3, djj: 3, skcd: 2, dsz: "1", zc: "1-15周(单)" },
    { kch_id: "DROP", kcb: "退选<br>x<br>x<br>xzwf", sfyjskc: "1", xqj: 1, djj: 1, skcd: 1 },
  ],
};

{
  const result = run(payload);
  assert.equal(result.requests.length, 1);
  assert.equal(result.requests[0].method, "POST");
  assert.match(result.requests[0].url, /\/jwglxt\/kbcx\/xskbcx_cxXsKb\.html\?gnmkdm=N2151&xnm=2025&xqm=3&kzlx=ck$/);
  assert.equal(result.requests[0].body, "gnmkdm=N2151&xnm=2025&xqm=3&kzlx=ck");
  assert.ok(!result.value.startsWith("NAP_ERROR"), result.value);
  const output = JSON.parse(result.value);
  assert.equal(output.name, "2025-2026学年第1学期");
  assert.equal(output.courses.length, 2);
  assert.deepEqual(output.courses[0].weeks, Array.from({ length: 16 }, (_, i) => i + 1));
  assert.deepEqual(output.courses[1].weeks, [1, 3, 5, 7, 9, 11, 13, 15]);
  assert.deepEqual([output.courses[0].week_time, output.courses[0].start_time, output.courses[0].time_count], [1, 1, 1]);
  assert.equal(output.courses[0].classroom, "紫金港西1-101");
}

assert.equal(JSON.parse(run({ kbList: [] }, { term: "12" }).value).name, "2025-2026学年第1学期");
{
  // 目标地址有时直接返回 JSON，页面没有 xnm/xqm 下拉框；应直接使用页面的 kbList。
  const page = { xnxqdm: "2025-2026-2", kbList: payload.kbList.slice(0, 1) };
  const result = run(page, { page, year: "", term: "" });
  assert.equal(result.requests.length, 1, "应始终通过当前学期 POST 查询课表");
  const output = JSON.parse(result.value);
  assert.equal(output.name, "2025-2026学年第1学期");
  assert.equal(output.courses.length, 1);
}
{
  // 页面 JSON 只用于学期参数；课程始终来自当前学期 POST。
  const page = { xnxqdm: "2025-2026-2", kbList: payload.kbList.concat([{ kch_id: "OLD", xnxqdm: "2024-2025-1" }]) };
  const result = run(payload, { page, year: "", term: "" });
  assert.equal(result.requests.length, 1);
  assert.equal(JSON.parse(result.value).courses.length, 2);
}
{
  const mixed = { kbList: [payload.kbList[0], { ...payload.kbList[1], xnmmc: "2024-2025", xqmmc: "秋冬" }] };
  assert.equal(JSON.parse(run(mixed).value).courses.length, 1, "接口带历史记录时只保留当前学期");
}
assert.match(run("<html>用户登录</html>").value, /^NAP_ERROR:登录已失效/);
assert.match(run(payload, { status: 503 }).value, /^NAP_ERROR:浙大教务课表接口返回 HTTP 503/);
assert.match(run(payload, { origin: "https://zjuam.zju.edu.cn" }).value, /^NAP_ERROR:请先登录/);

console.log("ZJU extractor checks passed");
