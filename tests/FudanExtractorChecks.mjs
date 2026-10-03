import { readFileSync } from "node:fs";
import vm from "node:vm";
import assert from "node:assert/strict";

const swift = readFileSync(new URL("../NapTable/Import/FudanExtractor.swift", import.meta.url), "utf8");
const script = swift.slice(swift.indexOf('#"""') + 4, swift.lastIndexOf('"""#'));

function run(body) {
  const requests = [];
  class XMLHttpRequest {
    open(method, url, async) { assert.equal(async, false); this.method = method; this.url = url; }
    setRequestHeader() {}
    send() {
      requests.push(this.url);
      this.status = 200;
      this.responseText = JSON.stringify(body);
    }
  }
  const option = { value: "505", textContent: "2026-2027学年1学期" };
  const context = {
    XMLHttpRequest, JSON, Number, String, Array, Set, Math, Date,
    encodeURIComponent, decodeURIComponent,
    location: { hostname: "fdjwgl.fudan.edu.cn", href: "https://fdjwgl.fudan.edu.cn/student/for-std/course-table" },
    document: { querySelector: (selector) => selector.includes("allSemesters") ? option : null,
      documentElement: { innerHTML: "" } },
  };
  const wrapped = `try {\n${script}\n} catch (error) { "NAP_ERROR:" + error.message; }`;
  return { value: vm.runInNewContext(wrapped, context), requests };
}

const payload = {
  studentTableVms: [{ activities: [
    { courseName: "高等数学", lessonId: 101, lessonCode: "MATH", teachers: ["张老师"], room: "邯郸校区", weekIndexes: [1, 2, 3, 4], weekday: 1, startUnit: 1, endUnit: 2 },
    { courseName: "大学英语", lessonId: 102, lessonCode: "ENG", teachers: ["李老师", "王老师"], room: "光华楼", weekIndexes: [1, 3, 5], weekday: 3, startUnit: 3, endUnit: 4 },
    { courseName: "重复记录", lessonId: 103, teachers: [], room: "", weekIndexes: [1], weekday: 2, startUnit: 5, endUnit: 5 },
    { courseName: "重复记录", lessonId: 103, teachers: [], room: "", weekIndexes: [1], weekday: 2, startUnit: 5, endUnit: 5 },
  ] }],
};

const result = run(payload);
assert.equal(typeof result.value, "string");
assert.ok(!result.value.startsWith("NAP_ERROR"), result.value);
const output = JSON.parse(result.value);
assert.equal(output.courses.length, 3);
assert.equal(result.requests[0], "/student/for-std/course-table/semester/505/print-data");
assert.deepEqual(output.courses[0].weeks, [1, 2, 3, 4]);
assert.deepEqual([output.courses[0].week_time, output.courses[0].start_time, output.courses[0].time_count], [1, 1, 1]);
assert.equal(output.courses[1].teacher, "李老师、王老师");

console.log("FUDAN extractor checks passed");
