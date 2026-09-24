// 在 node 里跑中山大学课表提取脚本：从 Swift 源文件里取出脚本，
// 用假的 XMLHttpRequest 返回 sysukcb 解析过的那几种教务响应。
import { readFileSync } from "node:fs";
import vm from "node:vm";
import assert from "node:assert/strict";

const swift = readFileSync(new URL("../NapTable/Import/SysuExtractor.swift", import.meta.url), "utf8");
const body = swift.slice(swift.indexOf('#"""') + 4, swift.lastIndexOf('"""#'));
const script = body.split("\n").map((line) => line.replace(/^    /, "")).join("\n");

function run(routes, origin = "https://jwxt.sysu.edu.cn") {
  const requests = [];
  class XMLHttpRequest {
    open(method, url, async) { this.method = method; this.url = url; this.async = async; this.headers = {}; }
    setRequestHeader(k, v) { this.headers[k] = v; }
    send(body) {
      assert.equal(this.async, false, "教务请求必须是同步的，脚本的返回值才是完成值");
      requests.push({ method: this.method, url: this.url, headers: this.headers, body });
      const path = new URL(this.url).pathname;
      const hit = routes[path];
      if (!hit) { this.status = 404; this.responseText = ""; return; }
      const [status, payload] = typeof hit === "function" ? hit(body) : hit;
      this.status = status;
      this.responseText = typeof payload === "string" ? payload : JSON.stringify(payload);
    }
  }
  // 与 WebImporterView 一致：包在 try 里，取脚本的完成值。
  const wrapped = `try {\n${script}\n} catch (error) {\n"NAP_ERROR:" + (error && error.message ? error.message : String(error));\n}`;
  const value = vm.runInNewContext(wrapped, { XMLHttpRequest, location: { origin }, JSON, Date, Math, Set, Array, Object, String, Number, parseInt, isNaN });
  return { value, requests };
}

const item = (o) => ({ classesId: "C1", startWeek: 1, ...o });
const routes = {
  "/jwxt/base-info/acadyearterm/showNewAcadlist": [200, { code: 200, data: { acadYearSemester: "2026-1" } }],
  "/jwxt/timetable-search/stuTimeTabPrint/studentQuery": (body) => {
    assert.deepEqual(JSON.parse(body), { acadYear: "2026-1", submitFlag: "1", nothroughCourseFlag: "1" });
    return [200, { code: 200, data: { timetable: {
      "1": [
        item({ courseName: "本(专必)医科数学/", teachingStaffName: "徐旺/", classPlace: "南校园-第五教学楼(逸夫楼)-逸301(185座)/", week: "1", startClassTimes: 1, endClassTimes: 2, timeDetail: "1-16周" }),
        item({ courseName: "医科数学", teachingStaffName: "徐旺", classPlace: "逸301", week: "1", startClassTimes: 1, endClassTimes: 2, timeDetail: "1-16周" }),
      ],
      "2": [item({ classesId: "C2", courseName: "大学物理", week: 3, startClassTimes: "5", endClassTimes: "6", timeDetail: "1-15周(单)" })],
      "3": [item({ classesId: "C3", courseName: "体育", week: 5, startClassTimes: 7, endClassTimes: 7, timeDetail: "2,4,6周/" })],
      "4": [item({ classesId: "C4", courseName: "实验", week: 2, startClassTimes: 3, endClassTimes: 4, timeDetail: "", startWeek: 9 })],
      "5": null,
      "6": [{ courseName: "  " }],
    } } }];
  },
};

{
  const { value, requests } = run(routes);
  assert.equal(typeof value, "string");
  assert.ok(!value.startsWith("NAP_ERROR"), value);
  const out = JSON.parse(value);
  assert.equal(out.name, "2026-2027学年第1学期");
  assert.equal(out.courses.length, 4, "重复的同一节课只保留一条，空名跳过");
  const [math, physics, pe, lab] = out.courses;
  assert.deepEqual(math, { name: "医科数学", teacher: "徐旺", classroom: "逸301",
    weeks: Array.from({ length: 16 }, (_, i) => i + 1), week_time: 1, start_time: 1, time_count: 1, info: "1-16周" });
  assert.equal(physics.name, "大学物理", "无分类前缀的课程名不变");
  assert.equal(physics.classroom, "", "缺失地点不产生占位文字");
  assert.deepEqual(physics.weeks, [1, 3, 5, 7, 9, 11, 13, 15]);
  assert.equal(physics.week_time, 3);
  assert.equal(physics.start_time, 5);
  assert.equal(physics.time_count, 1);
  assert.deepEqual(pe.weeks, [2, 4, 6]);
  assert.equal(pe.time_count, 0);
  assert.deepEqual(lab.weeks, [9], "没有周次说明时只算起始周");
  assert.equal(requests[1].method, "POST");
  assert.equal(requests[1].headers.menuId, "jwxsd_xskbcx");
  assert.ok(requests.every((r) => /[?&]_t=\d+$/.test(r.url)));
}

{
  const { value } = run({ ...routes, "/jwxt/base-info/acadyearterm/showNewAcadlist": [200, { code: 200, data: { acadYearSemester: "2025-2" } }],
    "/jwxt/timetable-search/stuTimeTabPrint/studentQuery": [200, { code: 200, data: { timetable: {} } }] });
  const out = JSON.parse(value);
  assert.equal(out.name, "2025-2026学年第2学期");
  assert.deepEqual(out.courses, []);
}

// 登录失效：接口被重定向回 CAS 登录页（HTML），或直接返回 401。
assert.match(run({ "/jwxt/base-info/acadyearterm/showNewAcadlist": [200, "<html>cas.sysu.edu.cn</html>"] }).value, /^NAP_ERROR:.*登录/);
assert.match(run({ "/jwxt/base-info/acadyearterm/showNewAcadlist": [401, ""] }).value, /^NAP_ERROR:登录已失效/);
assert.match(run({ "/jwxt/base-info/acadyearterm/showNewAcadlist": [200, { code: 500, message: "系统繁忙" }] }).value, /^NAP_ERROR:系统繁忙$/);
// 还停在 CAS 登录页时不发请求，提示先登录。
assert.match(run(routes, "https://cas.sysu.edu.cn").value, /^NAP_ERROR:请先登录/);

console.log("SYSU extractor checks passed");
