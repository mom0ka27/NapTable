// 依据 NauCourse 文档化的教务格式构造匿名页面，执行 App 使用的完整脚本。
import { readFileSync } from "node:fs";
import vm from "node:vm";
import assert from "node:assert/strict";

const swift = readFileSync(new URL("../NapTable/Import/NauExtractor.swift", import.meta.url), "utf8");
const script = swift.slice(swift.indexOf('#"""') + 4, swift.lastIndexOf('"""#'));

// 与 NJFU 检查使用相同的极简 DOM；仅实现提取器需要的浏览器接口。
const VOID = new Set(["br", "input", "meta", "img", "hr", "link"]);
const decode = (s) => s.replace(/&nbsp;/g, " ").replace(/&lt;/g, "<").replace(/&gt;/g, ">").replace(/&amp;/g, "&");
class Text { constructor(t) { this.nodeType = 3; this.textContent = decode(t); } }
class Element {
  constructor(tag, attrs) { this.nodeType = 1; this.tagName = tag.toUpperCase(); this.attrs = attrs; this.childNodes = []; }
  get children() { return this.childNodes.filter((n) => n.nodeType === 1); }
  get textContent() { return this.childNodes.map((n) => n.textContent).join(""); }
  get title() { return this.getElementsByTagName("title")[0]?.textContent || ""; }
  querySelector(selector) {
    if (selector === '.tdTitle') return [...this.walk()].find(n => (n.attrs.class || '').split(/\s+/).includes('tdTitle')) || null;
    if (selector === 'input[type="password"]') return this.getElementsByTagName('input').find(n => n.attrs.type === 'password') || null;
    throw new Error('Unsupported test selector: ' + selector);
  }
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

function run(page, { hostname = "jwc.nau.edu.cn", status = 200 } = {}) {
  const requests = [];
  class XMLHttpRequest {
    open(method, url, async) { assert.equal(async, false); requests.push({ method, url }); }
    send() { this.status = status; this.responseText = page; }
  }
  const value = vm.runInNewContext(`try { ${script} } catch (e) { "NAP_ERROR:" + e.message }`,
    { XMLHttpRequest, DOMParser, location: { hostname } });
  return { value, requests };
}
const row = (name, timing, id = "AUD101", teacher = "张老师") =>
  `<tr>${[1, id, name, '审计学01班', '3.0', '审计学', '必修', teacher, timing].map(v => `<td>${v}</td>`).join('')}</tr>`;
const timing = (weeks, day, slots, room = "致明楼101") =>
  `上课地点：${room}<br>上课时间：${weeks} 星期 ${day} 第 ${slots}节`;
const page = (rows, term = "2026-2027学年第一学期") =>
  `<html><head><title>本学期课表</title></head><body><div class="tdTitle">${term}</div>
  <table id="content"><tr>${['序号', '课程号', '课程名', '教学班', '学分', '课程类别', '课程性质', '教师', '上课时间'].map(t => `<td>${t}</td>`).join('')}</tr>${rows}</table></body></html>`;
const odd = timing('2-9之单周', '3', '3-4');
const parsed = run(page(
  row('审计学', timing('第1-4,6周', '1', '1,2,5,6') + '<br>' + timing('2-8之双周', '5', '9-11', '敏达楼202'))
  + row('统计学', odd + '<br>' + odd, 'STAT201')
  + row('体育', timing('第3周', '日', '7', ''), 'PE101')
  + row('毕业论文', '', 'THESIS')
));
assert.equal(parsed.requests.length, 1);
assert.equal(parsed.requests[0].method, 'GET');
assert.match(parsed.requests[0].url, /^\/Students\/MyCourseScheduleTable\.aspx\?_t=\d+$/);
const result = JSON.parse(parsed.value);
assert.equal(result.name, '2026-2027学年第1学期');
assert.equal(result.courses.length, 6);
const [first, split, otherRoom, single, sunday, free] = result.courses;
assert.deepEqual(first.weeks, [1, 2, 3, 4, 6]);
assert.deepEqual([first.start_time, first.time_count, split.start_time, split.time_count], [1, 1, 5, 1]);
assert.equal(first.teacher, '张老师');
assert.equal(first.class_number, 'AUD101');
assert.match(first.info, /学分：3.0/);
assert.equal(otherRoom.classroom, '敏达楼202');
assert.deepEqual(otherRoom.weeks, [2, 4, 6, 8]);
assert.equal(otherRoom.time_count, 2);
assert.deepEqual(single.weeks, [3, 5, 7, 9]);
assert.deepEqual([sunday.week_time, sunday.start_time, sunday.time_count], [7, 7, 0]);
assert.deepEqual([free.week_time, free.start_time, free.time_count, free.weeks], [0, 0, 0, []]);

// 同课程换地点、教师、持续节数时不能被当作重复记录去掉。
assert.equal(JSON.parse(run(page(row('统计学', odd, 'STAT201', '李老师')
  + row('统计学', odd, 'STAT201', '王老师'))).value).courses.length, 2);
for (const [weeks, expected] of [['1-6周', [1,2,3,4,5,6]], ['1-6周(双)', [2,4,6]], ['第1，3、5周', [1,3,5]]]) {
  const r = JSON.parse(run(page(row('课程', timing(weeks, '二', '2')))).value);
  assert.deepEqual(r.courses[0].weeks, expected);
}
assert.equal(JSON.parse(run(page('', '2026—2027学年第二学期')).value).name, '2026-2027学年第2学期');
assert.deepEqual(JSON.parse(run(page('')).value).courses, []);
assert.deepEqual(JSON.parse(run(page('<tr><td colspan="9">暂无课程记录</td></tr>')).value).courses, []);
assert.match(run('<title>统一身份认证登录</title>').value, /^NAP_ERROR:登录已失效/);
assert.match(run('<input type="password">').value, /^NAP_ERROR:登录已失效/);
assert.match(run("<script>location.href='/login.aspx';</script>").value, /^NAP_ERROR:登录已失效/);
assert.match(run('<html>系统维护</html>').value, /^NAP_ERROR:没有找到/);
assert.match(run(page(''), { status: 503 }).value, /^NAP_ERROR:.*503/);
assert.match(run(page(''), { status: 401 }).value, /^NAP_ERROR:登录已失效/);
const wrongHost = run(page(''), { hostname: 'sso.nau.edu.cn' });
assert.match(wrongHost.value, /^NAP_ERROR:请先登录/);
assert.equal(wrongHost.requests.length, 0);
assert.match(run(page('', '本学期')).value, /^NAP_ERROR:无法识别/);
assert.match(run(page('<tr><td>坏行</td></tr>')).value, /^NAP_ERROR:教务课表列数不完整/);
for (const invalid of [timing('第31周', 1, '1-2'), timing('第1周', 1, '4-2'), '上课地点：教室 上课时间：未知时间', '未知时间']) {
  assert.match(run(page(row('坏课程', invalid))).value, /^NAP_ERROR:无法完整解析/);
}
console.log('NAU extractor checks passed');
