import { readFileSync } from "node:fs";
import vm from "node:vm";
import assert from "node:assert/strict";

const swift = readFileSync(new URL("../NapTable/Import/XjtuExtractor.swift", import.meta.url), "utf8");
const script = swift.slice(swift.indexOf('#"""') + 4, swift.lastIndexOf('"""#'));
const fixture = JSON.parse(readFileSync(new URL("fixtures/xjtu-timetable.json", import.meta.url), "utf8"));
const semesterPath = "/jwapp/sys/wdkb/modules/jshkcb/dqxnxq.do";
const timetablePath = "/jwapp/sys/wdkb/modules/xskcb/xskcb.do";
const term = "2026-2027-1";

function run(options = {}) {
  const requests = [];
  class XMLHttpRequest {
    open(method, url, async) {
      assert.equal(method, "POST");
      assert.equal(async, false);
      this.url = url;
      this.headers = {};
    }
    setRequestHeader(name, value) { this.headers[name] = value; }
    send(body) {
      requests.push({ url: this.url, body, headers: this.headers });
      const response = options.responses?.[this.url];
      this.status = response?.status ?? 200;
      const payload = this.url === semesterPath
        ? (options.semester ?? { code: "0", datas: { dqxnxq: { rows: [{ DM: term }] } } })
        : (options.payload ?? fixture);
      this.responseText = response?.text ?? JSON.stringify(payload);
    }
  }
  const location = options.location ?? {
    protocol: "https:", hostname: "ehall.xjtu.edu.cn", pathname: "/jwapp/sys/wdkb/*default/index.do",
  };
  const value = vm.runInNewContext(
    `try {\n${script}\n} catch (error) { "NAP_ERROR:" + error.message; }`,
    { XMLHttpRequest, location }, { timeout: 1000 });
  return { value, requests };
}

function decode(options) {
  const result = run(options);
  assert.ok(!result.value.startsWith("NAP_ERROR:"), result.value);
  return JSON.parse(result.value);
}
function failure(options, pattern) {
  const result = run(options);
  assert.match(result.value, /^NAP_ERROR:/);
  assert.match(result.value, pattern);
  return result;
}
function payload(rows) {
  return { code: "0", datas: { xskcb: { totalSize: rows.length, rows, extParams: { code: 1 } } } };
}
const row = fixture.datas.xskcb.rows[0];

// 上游真实响应的匿名字段子集：同课程多时段、非连续周、换教室、ISTK=1。
const result = run();
const output = JSON.parse(result.value);
assert.equal(output.name, term);
assert.equal(output.courses.length, 18);
assert.equal(new Set(output.courses.map(course => course.class_number)).size, 9);
assert.deepEqual(result.requests.map(request => request.url), [semesterPath, timetablePath]);
assert.equal(result.requests[0].body, "");
assert.equal(result.requests[1].body, "XNXQDM=" + term);
for (const request of result.requests) {
  assert.equal(request.headers["X-Requested-With"], "XMLHttpRequest");
  assert.match(request.headers["Content-Type"], /^application\/x-www-form-urlencoded/);
}
fixture.datas.xskcb.rows.forEach((source, index) => {
  const course = output.courses[index];
  assert.equal(course.name, source.KCM);
  assert.equal(course.teacher, source.SKJS);
  assert.equal(course.classroom, source.JASMC);
  assert.equal(course.info, source.XXXQDM_DISPLAY);
  assert.deepEqual([course.week_time, course.start_time, course.time_count],
    [Number(source.SKXQ), Number(source.KSJC), Number(source.JSJC) - Number(source.KSJC)]);
  assert.deepEqual(course.weeks, Array.from(source.SKZC)
    .flatMap((bit, index) => bit === "1" ? [index + 1] : []));
});
assert.equal(output.courses.filter(course => course.weeks.join(",") === "1,2,5").length, 2);
assert.ok(output.courses.some(course => course.time_count === 7));
assert.ok(fixture.datas.xskcb.rows.some(source => source.ISTK === 1));

const duplicates = decode({ payload: payload([row, row, { ...row, JXBID: "another-class" }]) });
assert.equal(duplicates.courses.length, 2);
assert.deepEqual(decode({ payload: payload([{ ...row, SKZC: "101000", ZCMC: "1-6周" }]) }).courses[0].weeks, [1, 3]);
const fallback = decode({ payload: payload([{ ...row, SKZC: null, ZCMC: "2～8周（单），10-14周(双周)、16周" }]) });
assert.deepEqual(fallback.courses[0].weeks, [3, 5, 7, 10, 12, 14, 16]);
assert.equal(decode({ payload: payload([{ ...row, SKZC: "000000" }, row]) }).courses.length, 1);
assert.equal(decode({ payload: payload([{ ...row, SKJS: null, XM: "学生姓名", SKJSCH: "其他字段" }]) }).courses[0].teacher, "");
assert.equal(decode({ payload: payload([{ ...row, KSJC: "3", JSJC: "3" }]) }).courses[0].time_count, 0);
assert.equal(decode({ semester: { datas: { renamedModule: { rows: [{ XNXQDM: term }] } } } }).name, term);
const spring = "2026-2027-2";
assert.equal(decode({ semester: { datas: { current: { rows: [{ DM: spring }] } } },
  payload: payload([{ ...row, XNXQDM: spring }]) }).name, spring);

for (const location of [
  { protocol: "https:", hostname: "login.xjtu.edu.cn", pathname: "/login" },
  { protocol: "https:", hostname: "ehall.xjtu.edu.cn.evil.test", pathname: "/jwapp/sys/wdkb/index.do" },
  { protocol: "http:", hostname: "ehall.xjtu.edu.cn", pathname: "/jwapp/sys/wdkb/index.do" },
  { protocol: "https:", hostname: "ehall.xjtu.edu.cn", pathname: "/portal/html/select_role.html" },
]) assert.equal(failure({ location }, /请选择|选择学生角色/).requests.length, 0);
for (const path of [semesterPath, timetablePath]) {
  for (const response of [
    { status: 401, pattern: /登录已失效/ },
    { status: 403, pattern: /访问权限/ },
    { status: 500, pattern: /HTTP 500/ },
    { text: "<html>统一身份认证 请输入密码</html>", pattern: /登录已失效/ },
    { text: "not json", pattern: /有效 JSON/ },
    { text: "null", pattern: /响应格式/ },
    { text: '{"code":"-1","msg":"session"}', pattern: /查询失败/ },
  ]) {
    const result = failure({ responses: { [path]: response } }, response.pattern);
    assert.equal(result.requests.length, path === semesterPath ? 1 : 2);
  }
}
failure({ semester: { datas: {} } }, /无法确定/);
failure({ payload: { datas: {} } }, /课程列表/);
failure({ payload: payload([]) }, /没有可导入/);
failure({ payload: { datas: { xskcb: { rows: [row], totalSize: 2 } } } }, /不完整/);
failure({ payload: { datas: { xskcb: { rows: [row], extParams: { code: 0 } } } } }, /查询失败/);
for (const [changes, pattern] of [
  [{ SKXQ: "8" }, /星期无效/],
  [{ KSJC: "3", JSJC: "1" }, /节次范围/],
  [{ KSJC: "1", JSJC: "99999" }, /节次范围/],
  [{ SKXQ: "1.5" }, /星期无效/],
  [{ KCM: "" }, /课程名称/],
  [{ XNXQDM: "2025-2026-1" }, /学期不一致/],
  [{ SKZC: "0".repeat(40) + "1", ZCMC: "1周" }, /40 周范围/],
  [{ SKZC: null, ZCMC: "1-41周" }, /超过 40 周/],
  [{ SKZC: null, ZCMC: "未知周次" }, /无法识别/],
  [{ SKZC: null, ZCMC: null }, /缺少有效周次/],
]) failure({ payload: payload([row, { ...row, ...changes }]) }, pattern);
failure({ payload: payload([row, null]) }, /记录格式/);
console.log("XJTU extractor checks passed: 18 real-structure meetings, weeks, slots, metadata, request flow and failures");
