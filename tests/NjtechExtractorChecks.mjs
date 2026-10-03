// 在 Node 中运行南京工业大学教务提取脚本，用匿名接口响应覆盖正方课表的主要字段。
import { readFileSync } from "node:fs";
import vm from "node:vm";
import assert from "node:assert/strict";

const swift = readFileSync(new URL("../NapTable/Import/NjtechExtractor.swift", import.meta.url), "utf8");
const script = swift.slice(swift.indexOf('#"""') + 4, swift.lastIndexOf('"""#'));

function select(value, label) {
  return { value, selectedOptions: [{ textContent: label }], textContent: label };
}

function run(body, { hostname = "jwgl.njtech.edu.cn", status = 200, xnm = "2025", xqm = "3" } = {}) {
  const requests = [];
  const fields = {
    "#xnm": select(xnm, "2025-2026学年"),
    "#xqm": select(xqm, xqm === "12" ? "第二学期" : "第一学期"),
    "#xsdm": select("", ""),
    "#kclbdm": select("", ""),
    "#kclxdm": select("", ""),
  };
  class XMLHttpRequest {
    open(method, url, async) {
      assert.equal(async, false, "课表接口必须同步请求，脚本的返回值才是完成值");
      this.method = method;
      this.url = url;
    }
    setRequestHeader(key, value) { this[key] = value; }
    send(requestBody) {
      requests.push({ method: this.method, url: this.url, body: requestBody });
      this.status = status;
      this.responseText = typeof body === "string" ? body : JSON.stringify(body);
    }
  }
  const wrapped = `try {\n${script}\n} catch (error) {\n"NAP_ERROR:" + (error && error.message ? error.message : String(error));\n}`;
  const value = vm.runInNewContext(wrapped, {
    XMLHttpRequest,
    JSON,
    URLSearchParams,
    encodeURIComponent,
    parseInt,
    Array,
    Set,
    Math,
    String,
    Number,
    document: { querySelector: (selector) => fields[selector] || null },
    location: { hostname },
  });
  return { value, requests };
}

const response = {
  kbList: [
    { kch_id: "MATH-1", kcmc: "高等数学", xm: "张老师", cdmc: "厚学楼101", xqj: "1", jcs: "1-2", zcd: "1-16周" },
    { kch_id: "ENG-1", kcmc: "大学英语", xm: "李老师", cdmc: "明德楼202", xqj: 3, jcs: "3-4", zcd: "1-16周(单)" },
  ],
  sjkList: [
    { kch_id: "LAB-1", kcmc: "化学实验", xm: "王老师", cdmc: "实验楼A203", xqj: 5, jcs: "5-8节", zcd: "2-16周(双)" },
  ],
  jxhjkcList: [
    { kch_id: "PRACTICE-1", kcmc: "认识实习", xm: "赵老师", cdmc: "校外", xqj: "星期日", jcs: "9", zcd: "第3，5、7周" },
  ],
};

const parsed = run(response);
assert.equal(parsed.requests.length, 1);
assert.equal(parsed.requests[0].method, "POST");
assert.equal(parsed.requests[0].url, "/kbcx/xskbcx_cxXsgrkb.html");
assert.match(parsed.requests[0].body, /gnmkdm=N2151/);
assert.match(parsed.requests[0].body, /xnm=2025/);
assert.match(parsed.requests[0].body, /xqm=3/);

const result = JSON.parse(parsed.value);
assert.equal(result.name, "2025-2026学年第1学期");
assert.equal(result.courses.length, 4);
assert.deepEqual(result.courses[0].weeks, Array.from({ length: 16 }, (_, i) => i + 1));
assert.deepEqual([result.courses[0].week_time, result.courses[0].start_time, result.courses[0].time_count], [1, 1, 1]);
assert.deepEqual(result.courses[1].weeks, [1, 3, 5, 7, 9, 11, 13, 15]);
assert.deepEqual(result.courses[2].weeks, [2, 4, 6, 8, 10, 12, 14, 16]);
assert.deepEqual([result.courses[3].week_time, result.courses[3].start_time, result.courses[3].time_count], [7, 9, 0]);
assert.equal(result.courses[2].classroom, "实验楼A203");

const spring = JSON.parse(run({ kbList: [response.kbList[0]] }, { xqm: "12" }).value);
assert.equal(spring.name, "2025-2026学年第2学期");

const duplicate = JSON.parse(run({ kbList: [response.kbList[0], response.kbList[0]] }).value);
assert.equal(duplicate.courses.length, 1);

assert.match(run("<html>用户登录</html>").value, /^NAP_ERROR:登录已失效/);
assert.match(run(response, { status: 503 }).value, /^NAP_ERROR:教务课表接口返回 HTTP 503/);
assert.match(run(response, { hostname: "example.com" }).value, /^NAP_ERROR:请先登录/);
assert.deepEqual(JSON.parse(run({ kbList: [] }).value).courses, []);

console.log("NJTECH extractor checks passed");
