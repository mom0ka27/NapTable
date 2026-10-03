import Foundation

extension SchoolCatalog {
    /// 上海科技大学本科生课表提取器。
    ///
    /// 本科教务系统（EAMS）在统一认证完成后把「我的课表」渲染成 HTML 表格。
    /// 这里只读取当前 WebView 中的已登录页面，不提交账号、密码或 Cookie；
    /// 表格结构在不同版本中有两种常见形态，因此同时支持带表头的明细表和
    /// 按星期/节次排列的课表网格。
    static let shanghaitechUndergraduateExtractJS = #"""
    (() => {
      const ORIGIN = "https://eams.shanghaitech.edu.cn";
      const text = (value) => String(value == null ? "" : value)
        .replace(/\u00a0/g, " ").replace(/\s+/g, " ").trim();
      const wait = (message) => {
        const error = new Error(message);
        error.name = "NapTableNotReady";
        throw error;
      };
      if (location.origin !== ORIGIN || !location.pathname.toLowerCase().startsWith("/eams/")) {
        wait("请先登录上海科技大学本科教务系统并进入「我的课表」");
      }

      const bodyText = text(document.body && document.body.innerText);
      if (/统一身份认证|请输入密码|请输入学号|登录/.test(bodyText)
          && !/我的课表|课表查询|课程表/.test(bodyText)) {
        wait("请先完成上海科技大学统一身份认证登录");
      }

      const normal = (value) => text(value).replace(/[：:]/g, ":");
      const rawText = (value) => String(value == null ? "" : value).replace(/\u00a0/g, " ").trim();
      const dayNumber = (value) => {
        const s = text(value);
        const match = s.match(/(?:星期|周)\s*([一二三四五六日天1-7])/);
        if (!match) return 0;
        return { 一: 1, 二: 2, 三: 3, 四: 4, 五: 5, 六: 6, 日: 7, 天: 7 }[match[1]] || Number(match[1]) || 0;
      };
      const periods = (value) => {
        const s = normal(value);
        const match = s.match(/(?:第\s*)?(\d{1,2})\s*(?:[-~至到－—–]|、)\s*(\d{1,2})\s*节/)
          || s.match(/(?:第\s*)?(\d{1,2})\s*节/);
        if (!match) return null;
        const start = Number(match[1]);
        const end = Number(match[2] || match[1]);
        return start > 0 && end >= start && end <= 32 ? { start, end } : null;
      };
      const weeks = (value) => {
        let source = normal(value);
        // A table cell often contains the weekday, period and room together.
        // Keep only the explicit week expressions before expanding them.
        const expressions = [];
        const expressionPattern = /(\d+(?:[-~－—–至到]\d+)?(?:[,，、]\d+(?:[-~－—–至到]\d+)?)*(?:\s*[单双])?)\s*周(?:\s*[（(]([单双])[）)])?/g;
        let expression;
        while ((expression = expressionPattern.exec(source)) !== null) {
          expressions.push(expression[1] + (expression[2] ? "(" + expression[2] + ")" : ""));
        }
        let s = (expressions.length ? expressions.join(",") : source)
          .replace(/[第周]/g, "").replace(/[～~－—–至到]/g, "-")
          .replace(/[（]/g, "(").replace(/[）]/g, ")").replace(/\s/g, "");
        if (!s) return [];
        const globalParity = s.match(/\(([单双])\)$/);
        if (globalParity) s = s.slice(0, globalParity.index);
        const result = new Set();
        for (const part of s.split(/[,，、;；]/)) {
          if (!part) continue;
          const match = part.match(/^(\d+)(?:-(\d+))?(?:\(?([单双])\)?)?$/);
          if (!match) continue;
          const start = Number(match[1]);
          const end = Number(match[2] || match[1]);
          if (start < 1 || end < start || end > 40) continue;
          const parity = match[3] || (globalParity && globalParity[1]);
          for (let week = start; week <= end; week++) {
            if (parity === "单" && week % 2 === 0) continue;
            if (parity === "双" && week % 2 === 1) continue;
            result.add(week);
          }
        }
        return Array.from(result).sort((a, b) => a - b);
      };
      const semester = () => {
        const selectors = [
          "select[name*=xnxq]", "select[id*=xnxq]", "select[name*=term]",
          "select[id*=term]", "select[name*=semester]", "select[id*=semester]"
        ];
        for (const selector of selectors) {
          const select = document.querySelector(selector);
          const option = select && select.options && select.options[select.selectedIndex];
          const label = text(option && option.textContent) || text(select && select.value);
          if (label && /学年|学期|semester|term/i.test(label)) return label;
        }
        const match = bodyText.match(/\d{4}\s*[-—－]\s*\d{4}\s*学年[^\n]{0,20}(?:学期|semester)/i);
        return match ? text(match[0]) : "上海科技大学本科生课表";
      };
      const makeCourse = (name, classroom, code, teacher, info, schedule, fallbackDay) => {
        const value = normal(schedule);
        const day = dayNumber(value) || fallbackDay;
        const period = periods(value);
        const parsedWeeks = weeks(value);
        if (!name || !day || !period || !parsedWeeks.length) return null;
        let room = text(classroom);
        if (!room) {
          const roomMatch = value.match(/(?:节|周)\s*([^,，;；]+)$/);
          room = roomMatch ? text(roomMatch[1]) : "";
        }
        return {
          name: text(name), classroom: room, class_number: text(code), teacher: text(teacher),
          weeks: parsedWeeks, week_time: day, start_time: period.start,
          time_count: period.end - period.start, import_type: 1, info: text(info)
        };
      };

      const courses = [];
      const addFromDetailTable = (table) => {
        const rows = Array.from(table.querySelectorAll("tr"));
        if (rows.length < 2) return false;
        const header = Array.from(rows[0].querySelectorAll("th,td")).map((cell) => text(cell.innerText));
        const find = (patterns) => header.findIndex((value) => patterns.some((pattern) => pattern.test(value)));
        const nameIndex = find([/课程名称|课程名|course\s*name/i]);
        const scheduleIndex = find([/上课时间|时间地点|上课安排|周次|schedule|time/i]);
        if (nameIndex < 0 || scheduleIndex < 0) return false;
        const codeIndex = find([/课程代码|课程号|课程序号|course\s*(?:code|no)/i]);
        const teacherIndex = find([/教师|任课|授课教师|teacher/i]);
        const roomIndex = find([/地点|教室|上课地点|room|location/i]);
        const infoIndex = find([/备注|说明|note|remark/i]);
        const dayIndex = find([/星期|上课日|week\s*day/i]);
        const periodIndex = find([/节次|上课节|period/i]);
        for (const row of rows.slice(1)) {
          const cells = Array.from(row.querySelectorAll("th,td")).map((cell) => rawText(cell.innerText));
          if (cells.length <= Math.max(nameIndex, scheduleIndex)) continue;
          const name = cells[nameIndex];
          const scheduleParts = [cells[scheduleIndex]];
          if (dayIndex >= 0 && dayIndex !== scheduleIndex) scheduleParts.push(cells[dayIndex]);
          if (periodIndex >= 0 && periodIndex !== scheduleIndex) scheduleParts.push(cells[periodIndex]);
          const schedule = scheduleParts.filter(Boolean).join(" ");
          if (!name || !/(?:周|星期|节)/.test(schedule)) continue;
          const chunks = schedule.split(/\n+|[;；]/).map(text).filter(Boolean);
          let added = false;
          for (const chunk of chunks) {
            const course = makeCourse(name, roomIndex >= 0 ? cells[roomIndex] : "",
              codeIndex >= 0 ? cells[codeIndex] : "", teacherIndex >= 0 ? cells[teacherIndex] : "",
              infoIndex >= 0 ? cells[infoIndex] : "", chunk, 0);
            if (course) { courses.push(course); added = true; }
          }
          if (!added) {
            const course = makeCourse(name, roomIndex >= 0 ? cells[roomIndex] : "",
              codeIndex >= 0 ? cells[codeIndex] : "", teacherIndex >= 0 ? cells[teacherIndex] : "",
              infoIndex >= 0 ? cells[infoIndex] : "", schedule, 0);
            if (course) courses.push(course);
          }
        }
        return courses.length > 0;
      };

      const addFromGrid = (table) => {
        const rows = Array.from(table.querySelectorAll("tr"));
        let added = false;
        rows.forEach((row, rowIndex) => {
          const cells = Array.from(row.querySelectorAll("th,td"));
          if (cells.length < 2) return;
          cells.forEach((cell, columnIndex) => {
            const value = rawText(cell.innerText);
            if (!/(?:周|星期|节)/.test(value)) return;
            const fallbackDay = columnIndex >= 1 && columnIndex <= 7 ? columnIndex : 0;
            const fallbackPeriod = rowIndex > 0 ? rowIndex : 0;
            const period = periods(value) || (fallbackPeriod > 0 ? { start: fallbackPeriod, end: fallbackPeriod } : null);
            const day = dayNumber(value) || fallbackDay;
            const parsedWeeks = weeks(value);
            if (!day || !period || !parsedWeeks.length) return;
            const lines = value.split(/\n+/).map(text).filter(Boolean);
            const first = lines.find((line) => !/(?:周|星期|节|教室|地点|\d{1,2}:\d{2})/.test(line)) || lines[0];
            const teacher = lines.find((line) => /教师|老师/.test(line)) || "";
            const room = lines.find((line) => /(?:教室|地点)/.test(line)) || lines[lines.length - 1] || "";
            courses.push({ name: text(first), classroom: room, class_number: "", teacher: teacher,
              weeks: parsedWeeks, week_time: day, start_time: period.start,
              time_count: period.end - period.start, import_type: 1, info: "" });
            added = true;
          });
        });
        return added;
      };

      const tables = Array.from(document.querySelectorAll("table"));
      for (const table of tables) {
        if (addFromDetailTable(table)) break;
      }
      if (!courses.length) for (const table of tables) if (addFromGrid(table)) break;
      if (!courses.length) wait("已登录本科教务系统，请进入「学习管理」→「我的课表」并选择学期");
      return JSON.stringify({ name: semester(), courses: courses });
    })();
    """#
}
