import Foundation

extension SchoolCatalog {
    /// 南京审计大学教务导入。页面地址、字段顺序及时间文本格式参照 NauCourse
    /// 的 JwcClient / MyCourseScheduleTable（XFY9326，GPL-3.0-or-later）。
    /// 在已登录的教务网页内重新实现读取，不接触账号密码。
    /// 来源：https://github.com/XFY9326/NauCourse
    static let nauExtractJS = #"""
    (() => {
      if (location.hostname.toLowerCase() !== "jwc.nau.edu.cn") {
        throw new Error("请先登录南京审计大学统一认证，进入教务系统后再点「重新解析」");
      }

      const xhr = new XMLHttpRequest();
      xhr.open("GET", "/Students/MyCourseScheduleTable.aspx?_t=" + Date.now(), false);
      xhr.send(null);
      if (xhr.status === 401 || xhr.status === 403) throw new Error("登录已失效，请重新登录教务系统");
      if (xhr.status !== 200) throw new Error("教务课表页面返回 HTTP " + xhr.status);
      const html = xhr.responseText || "";
      const doc = new DOMParser().parseFromString(html, "text/html");
      if (doc.querySelector('input[type="password"]') || /用户登录|统一身份认证登录/.test(doc.title || "")
          || /(?:location|location.href)\s*=\s*["'][^"']*(?:login|sso)/i.test(html)) {
        throw new Error("登录已失效，请重新登录教务系统");
      }
      const table = doc.getElementById("content");
      if (!table) throw new Error("没有找到本学期课表，请确认已进入学生教务系统；也可能是页面结构已变化");

      // DOM textContent 不为 <br> 留空格；这里保留字段间隔，与页面显示一致。
      const text = (node) => {
        const walk = (n) => {
          if (n.nodeType === 3) return n.textContent;
          if (n.tagName === "BR") return " ";
          return Array.from(n.childNodes || []).map(walk).join(" ");
        };
        return node ? walk(node).replace(/\s+/g, " ").trim() : "";
      };
      const term = text(doc.querySelector(".tdTitle"));
      const academic = term.match(/(20\d{2})\s*[-—–]\s*(20\d{2})\s*学年\s*第\s*([一二12])\s*学期/);
      if (!academic) throw new Error("无法识别课表的学年学期，请确认已打开「本学期课表」");
      const semester = { "一": 1, "二": 2, "1": 1, "2": 2 }[academic[3]];
      const name = academic[1] + "-" + academic[2] + "学年第" + semester + "学期";

      const fail = (name) => { throw new Error("无法完整解析「" + name + "」的上课时间，请核对教务课表后反馈页面格式"); };
      // 严格展开数字段，防止格式变化时悄悄漏掉课程。单双周对所在周次表达式生效。
      const numbers = (raw, limit) => {
        const set = new Set();
        for (const part of raw.split(/[,，、]/)) {
          const match = part.match(/^(\d+)(?:[-—–~～](\d+))?$/);
          if (!match) return [];
          const start = Number(match[1]), end = Number(match[2] || match[1]);
          if (start < 1 || end < start || end > limit) return [];
          for (let n = start; n <= end; n++) set.add(n);
        }
        return Array.from(set).sort((a, b) => a - b);
      };
      const weeksOf = (raw) => {
        const parity = /单/.test(raw) ? 1 : /双/.test(raw) ? 0 : null;
        const clean = raw.replace(/[第周之单双()（）\s]/g, "");
        return numbers(clean, 30).filter((week) => parity === null || week % 2 === parity);
      };
      const days = { "一": 1, "二": 2, "三": 3, "四": 4, "五": 5, "六": 6, "日": 7, "天": 7 };
      const courses = [];
      const seen = new Set();
      const add = (course) => {
        const key = JSON.stringify(course);
        if (!seen.has(key)) { seen.add(key); courses.push(course); }
      };
      const rows = Array.from(table.getElementsByTagName("tr"));
      rows.forEach((tr, index) => {
        const cells = Array.from(tr.children).filter((c) => c.tagName === "TD");
        // 第一行为列名；空课表可能只有表头，或者一行 colspan 的空数据提示。
        if (index === 0) return;
        if (cells.length === 0) return;
        if (cells.length === 1 && /^(?:暂无|没有|无).*?(?:课程|数据|记录)/.test(text(cells[0]))) return;
        if (cells.length < 9) throw new Error("教务课表列数不完整，页面结构可能已变化");
        const courseName = text(cells[2]);
        if (!courseName) throw new Error("教务课表缺少课程名称，无法完整导入");
        const base = {
          name: courseName, class_number: text(cells[1]), teacher: text(cells[7]), import_type: 1,
          info: [text(cells[3]) && "教学班：" + text(cells[3]),
                 text(cells[4]) && "学分：" + text(cells[4]),
                 text(cells[5]), text(cells[6])].filter(Boolean).join("；"),
        };
        const timing = text(cells[8]);
        if (!timing || /^(?:未安排|未排课|待定|无)$/.test(timing)) {
          add({ ...base, classroom: "", weeks: [], week_time: 0, start_time: 0, time_count: 0 });
          return;
        }
        const segments = timing.split(/上课地点\s*[:：]/);
        if (segments.length < 2 || segments[0].trim()) fail(courseName);
        segments.slice(1).forEach((segment) => {
          const parts = segment.split(/上课时间\s*[:：]/);
          if (parts.length !== 2) fail(courseName);
          const classroom = parts[0].trim();
          const value = parts[1].replace(/\s+/g, "").replace(/[;；]+$/, "");
          // 常见格式：第1-16周 星期 1 第 1,2节；1-16之单周 星期 3 第 3-4节。
          const match = value.match(/^(.+?周(?:[（(]?[单双](?:周)?[）)]?)?)(?:星期|周)([1-7一二三四五六日天])第?([\d,，、\-—–~～]+)节$/);
          if (!match) fail(courseName);
          const weeks = weeksOf(match[1]);
          const weekday = days[match[2]] || Number(match[2]);
          const slots = numbers(match[3], 30);
          if (!weeks.length || !slots.length) fail(courseName);
          // 1,2,5,6 节拆成两段，不能把 3、4 节的空档也占上。
          let start = slots[0], end = start;
          const emit = () => add({ ...base, classroom, weeks, week_time: weekday,
            start_time: start, time_count: end - start });
          slots.slice(1).forEach((slot) => {
            if (slot === end + 1) end = slot;
            else { emit(); start = end = slot; }
          });
          emit();
        });
      });
      return JSON.stringify({ name, courses });
    })();
    """#
}
