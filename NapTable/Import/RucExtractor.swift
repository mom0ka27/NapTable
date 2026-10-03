import Foundation

extension SchoolCatalog {
    /// 中国人民大学本科、研究生课表解析脚本。
    ///
    /// 参考 ruc-schedule-extension 的 DOM 解析规则：本科课表使用
    /// 优先读取本科页面课程组件的 cellData，兼容 `地点/节次/周次` 文本；
    /// 研究生课表使用 `#jsTbl_01` 的
    /// `td[xq][jc]` 网格。研究生页面的课表有时在同源 iframe 中，脚本会
    /// 一并检查可访问的 iframe 文档。
    static let rucExtractJS = #"""
    (() => {
      const clean = (value) => String(value == null ? "" : value)
        .replace(/\u00a0/g, " ").replace(/\s+/g, " ").trim();
      const tagOf = (node) => String(node && node.tagName || "").toUpperCase();

      const waitForPage = (message) => {
        const error = new Error(message);
        error.name = "NapTableNotReady";
        throw error;
      };

      const documents = () => {
        const result = [document];
        const visit = (doc) => {
          Array.from(doc.querySelectorAll("iframe")).forEach((frame) => {
            try {
              const child = frame.contentDocument;
              if (child && !result.includes(child)) {
                result.push(child);
                visit(child);
              }
            } catch (_) {}
          });
        };
        visit(document);
        return result;
      };

      const parseWeeks = (value) => {
        let raw = clean(value).replace(/[（]/g, "(").replace(/[）]/g, ")");
        if (!/\d/.test(raw) || !raw.includes("周")) return [];
        const odd = /单/.test(raw);
        const even = !odd && /双/.test(raw);
        raw = raw.slice(raw.search(/\d/))
          .replace(/第/g, "").replace(/周/g, "")
          .replace(/[单双]/g, "")
          .replace(/[\[\]【】(){}]/g, "")
          .replace(/[–—－~～至]/g, "-")
          .replace(/[，、;；/]/g, ",");
        const result = new Set();
        raw.split(",").filter(Boolean).forEach((part) => {
          const numbers = part.match(/\d+/g) || [];
          if (!numbers.length) return;
          const start = Number(numbers[0]);
          const end = Number(numbers[1] || numbers[0]);
          if (!Number.isFinite(start) || !Number.isFinite(end) || start < 1 || end < start) return;
          for (let week = start; week <= Math.min(end, 60); week++) {
            if (odd && week % 2 === 0) continue;
            if (even && week % 2 === 1) continue;
            result.add(week);
          }
        });
        return Array.from(result).sort((a, b) => a - b);
      };

      const normalizeTerm = (value) => {
        const raw = clean(value);
        const match = raw.match(/(20\d{2}-20\d{2})学年\s*(?:第\s*([一二12])\s*学期|([春秋])季学期)/);
        if (!match) return raw;
        const second = match[2] || "";
        const season = match[3] || (second === "1" || second === "一" ? "秋" : "春");
        return `${match[1]}学年${season}季学期`;
      };

      const semesterFrom = (doc) => {
        const candidates = [];
        doc.querySelectorAll("input, select option, [id*='xnxq'], [id*='学期']").forEach((node) => {
          candidates.push(node.value || node.textContent || "");
        });
        candidates.push(doc.body ? doc.body.textContent : "");
        for (const candidate of candidates) {
          const value = clean(candidate);
          const match = value.match(/20\d{2}-20\d{2}学年\s*(?:第\s*[一二12]\s*学期|[春秋]季学期)/);
          if (match) return normalizeTerm(match[0]);
          const coded = value.match(/20\d{2}-20\d{2}-[12](?!\d)/);
          if (coded) return `${coded[0].slice(0, 9)}学年第${coded[0].slice(-1)}学期`;
        }
        return "";
      };

      const parseUndergraduateSlot = (value) => {
        const raw = clean(value).replace(/／/g, "/");
        const match = raw.match(/^(?:(.*?)\/\s*)?(\d+)\s*(?:[-–—－~～至]\s*(\d+)\s*)?节\s*\/\s*(.+)$/);
        if (!match) return null;
        const start = Number(match[2]);
        const end = Number(match[3] || match[2]);
        const weekText = clean(match[4]).replace(/[–—－~～至]/g, "-");
        if (!start || end < start || !weekText.includes("周")) return null;
        if (/单/.test(weekText) && /双/.test(weekText)) return null;
        const numbers = weekText.replace(/\s/g, "").replace(/[第周单双()（）\[\]【】]/g, "")
          .replace(/[，、;；]/g, ",");
        if (!/^\d+(?:-\d+)?(?:,\d+(?:-\d+)?)*$/.test(numbers)) return null;
        if (numbers.split(",").some((part) => {
          const [first, last = first] = part.split("-").map(Number);
          return first < 1 || last < first || last > 60;
        })) return null;
        const weeks = parseWeeks(weekText);
        if (!weeks.length) return null;
        return {
          classroom: clean(match[1]),
          start_time: start,
          time_count: end - start,
          weeks,
        };
      };

      const parseUndergraduateCell = (cell) => {
        const result = [];
        let currentName = "";
        let pending = [];
        let previousName = "";
        for (const div of cell.querySelectorAll("div")) {
          // 行内 span/a 不改变这一行的含义；只跳过包含其他 div 行的容器。
          if (div.querySelector("div")) continue;
          const value = clean(div.textContent);
          if (!value) continue;
          const slot = parseUndergraduateSlot(value);
          if (slot) {
            const name = currentName || pending[0] || previousName;
            if (!name) throw new Error(`人大课表中有无法识别课程名称的上课安排：${value}。请反馈该行文字后重试`);
            result.push({ name, ...slot });
            previousName = name;
            currentName = "";
            pending = [];
            continue;
          }
          if (/节\s*[/／]/.test(value)) {
            throw new Error(`人大课表中有无法识别的上课安排：${value}。请反馈该行文字后重试`);
          }
          const style = String(div.getAttribute("style") || "").replace(/\s/g, "");
          if (/rgb\(0,192,239\)|#00c0ef/i.test(style)) {
            currentName = value;
            pending = [];
          } else {
            pending.push(value);
          }
        }
        return result;
      };

      const parseUndergraduateComponents = (doc) => {
        const map = new Map();
        const seen = new Set();
        // 人大当前 Vue 课表的每个课程单元格都有 cellData.row 和 column.property。
        // 用 xq1...xq7 确定星期，避免星期日移到最前或合并行造成列号错位。
        for (const node of doc.querySelectorAll(".cell.xsb-hover")) {
          const component = node.__vue__;
          const data = component && component.cellData;
          const day = data && data.column && String(data.column.property || "").match(/^xq([1-7])$/);
          if (!day || !data.row || !Array.isArray(data.row[data.column.property])) continue;
          const weekday = Number(day[1]);
          for (const item of data.row[data.column.property]) {
            if (!item || item.ksjms) continue;
            const name = clean(item.kcname);
            const slot = parseUndergraduateSlot(item.zc);
            if (!name || !slot) {
              throw new Error(`人大课表中有无法识别的课程安排：${name} ${clean(item.zc)}。请反馈该行文字后重试`);
            }
            const classroom = slot.classroom || (clean(item.js) === "null" ? "" : clean(item.js));
            const identity = [name, weekday, slot.start_time, slot.time_count, classroom, slot.weeks.join(",")].join("|");
            if (seen.has(identity)) continue;
            seen.add(identity);
            if (!map.has(name)) map.set(name, []);
            map.get(name).push({ ...slot, classroom, teacher: clean(item.lsname), week_time: weekday });
          }
        }
        return Array.from(map, ([name, slots]) => ({ name, slots }));
      };

      const parseUndergraduate = (doc) => {
        const componentCourses = parseUndergraduateComponents(doc);
        if (componentCourses.length) return componentCourses;
        const table = Array.from(doc.querySelectorAll("table"))
          .find((candidate) => /\d\s*节\s*[/／]/.test(candidate.textContent || ""));
        if (!table) return [];
        // 先还原 HTML 网格：rowspan 会让后续行的 cells 少一项，colspan 会占多列。
        // 使用 rows/cells 只读取本表的单元格，避免把嵌套表格的列算进星期。
        const rows = Array.from(table.rows || []);
        const occupiedUntil = [];
        const grid = rows.map((row, rowIndex) => {
          let column = 0;
          return Array.from(row.cells || []).filter((cell) => !cell.style || cell.style.display !== "none").map((cell) => {
            const width = Math.max(1, Number(cell.getAttribute("colspan")) || 1);
            const rawHeight = Number(cell.getAttribute("rowspan") || "1");
            const height = rawHeight === 0 ? rows.length - rowIndex : Math.max(1, rawHeight);
            while (Array.from({ length: width }, (_, offset) => occupiedUntil[column + offset] > rowIndex).some(Boolean)) column++;
            const startColumn = column;
            for (let offset = 0; offset < width; offset++) occupiedUntil[column + offset] = rowIndex + height;
            column += width;
            return { cell, column: startColumn, width };
          });
        });
        const weekdayColumns = new Map();
        for (const row of grid) {
          for (const { cell, column, width } of row) {
            const label = clean(cell.textContent).match(/^(?:星期|周|礼拜)([一二三四五六日天1-7])$/);
            if (!label || width !== 1) continue;
            const weekday = /^[1-7]$/.test(label[1]) ? Number(label[1]) : "一二三四五六日".indexOf(label[1].replace("天", "日")) + 1;
            weekdayColumns.set(column, weekday);
          }
        }
        const map = new Map();
        const seen = new Set();
        for (const row of grid) {
          for (const { cell, column } of row) {
            const items = parseUndergraduateCell(cell);
            if (!items.length) continue;
            const weekday = weekdayColumns.size ? weekdayColumns.get(column) : column;
            if (!(weekday >= 1 && weekday <= 7)) {
              throw new Error(`人大课表中无法识别「${items[0].name}」所在列的星期。请反馈课表表头后重试`);
            }
            const raw = clean(cell.textContent);
            if (!raw) continue;
            const duplicateKey = `${weekday}|${raw.replace(/\s+/g, "")}`;
            if (seen.has(duplicateKey)) continue;
            seen.add(duplicateKey);
            for (const item of items) {
              const slot = {
                week_time: weekday,
                start_time: item.start_time,
                time_count: item.time_count,
                weeks: item.weeks,
                classroom: item.classroom,
              };
              const key = item.name;
              if (!map.has(key)) map.set(key, []);
              const identity = [slot.week_time, slot.start_time, slot.time_count, slot.classroom, slot.weeks.join(",")].join("|");
              if (!map.get(key).some((existing) => existing.identity === identity)) {
                map.get(key).push({ ...slot, identity });
              }
            }
          }
        }
        if (!map.size) throw new Error("已找到人大本科课表，但未能识别课程内容。请反馈课表页面文字后重试");
        return Array.from(map, ([name, slots]) => ({
          name,
          slots: slots.map(({ identity, ...slot }) => slot),
        }));
      };

      const graduateCourseNames = (doc) => {
        const names = new Map();
        const table = Array.from(doc.querySelectorAll("table")).find((candidate) => {
          const value = candidate.textContent || "";
          return value.includes("课程代码") && value.includes("课程名称");
        });
        if (!table) return names;
        const rows = Array.from(table.rows || []);
        const header = rows.find((row) => (row.textContent || "").includes("课程代码"));
        if (!header) return names;
        const labels = Array.from(header.cells || []).map((cell) => clean(cell.textContent));
        const codeIndex = labels.indexOf("课程代码");
        const nameIndex = labels.indexOf("课程名称");
        if (codeIndex < 0 || nameIndex < 0) return names;
        rows.forEach((row) => {
          const cells = Array.from(row.cells || []);
          if (cells.length <= Math.max(codeIndex, nameIndex)) return;
          const code = clean(cells[codeIndex].textContent);
          const name = clean(cells[nameIndex].textContent);
          if (code && code !== "课程代码" && name) names.set(code, name);
        });
        return names;
      };

      const graduateEndTimes = (table) => {
        const result = new Map();
        for (const row of Array.from(table.rows || [])) {
          const cells = Array.from(row.cells || []);
          if (cells.length < 2) continue;
          const section = clean(cells[0].textContent).match(/第\s*(\d+)\s*节/);
          const time = clean(cells[1].textContent).match(/\d{2}:\d{2}\s*[~～-]\s*(\d{2}:\d{2})/);
          if (section && time) result.set(Number(section[1]), time[1]);
        }
        return result;
      };

      const parseGraduate = (doc) => {
        const table = doc.querySelector("#jsTbl_01") || Array.from(doc.querySelectorAll("table"))
          .find((candidate) => candidate.querySelector("td[xq][jc] .kb_item"));
        if (!table) return [];
        const names = graduateCourseNames(doc);
        const endTimes = graduateEndTimes(table);
        const map = new Map();
        const seen = new Set();
        for (const cell of table.querySelectorAll("td[xq][jc]")) {
          if (cell.style && cell.style.display === "none") continue;
          const weekday = Number(cell.getAttribute("xq"));
          const startSection = Number(cell.getAttribute("jc"));
          const span = Number(cell.getAttribute("rowspan") || "1");
          const endSection = startSection + Math.max(span, 1) - 1;
          if (!weekday || !startSection) continue;
          for (const card of cell.querySelectorAll(".arrage.kb_item")) {
            const lines = Array.from(card.children || []).map((item) => clean(item.textContent)).filter(Boolean);
            const weekLine = lines.find((line) => /\d/.test(line) && line.includes("周"));
            const weeks = parseWeeks(weekLine);
            const courseLineIndex = lines.findIndex((line) => /^[A-Za-z0-9]+-/.test(line) && !/^\d+(?:-\d+)?周/.test(line));
            if (!weeks.length || courseLineIndex < 0) continue;
            const courseLine = lines[courseLineIndex];
            const codeMatch = courseLine.match(/^([A-Za-z0-9]+)-/);
            const code = codeMatch ? codeMatch[1] : "";
            const name = names.get(code) || clean(courseLine.replace(/^[^-]+-/, "").replace(/[（(][^（）()]*[）)]\s*$/, ""));
            if (!name) continue;
            const teacher = clean(lines[courseLineIndex + 1] || "");
            const classroom = clean(lines[courseLineIndex + 2] || "");
            const endTime = endTimes.get(endSection) || null;
            const slot = { week_time: weekday, start_time: startSection, time_count: endSection - startSection, weeks, classroom, teacher, endTime };
            const key = [name, weekday, startSection, endSection, weeks.join(","), classroom].join("|");
            if (seen.has(key)) continue;
            seen.add(key);
            if (!map.has(name)) map.set(name, []);
            const adjacent = map.get(name).find((existing) => existing.week_time === slot.week_time && existing.classroom === slot.classroom && existing.weeks.join(",") === slot.weeks.join(",") && slot.start_time <= existing.start_time + existing.time_count + 1 && existing.start_time <= slot.start_time + slot.time_count + 1);
            if (adjacent) {
              const last = Math.max(adjacent.start_time + adjacent.time_count, slot.start_time + slot.time_count);
              adjacent.start_time = Math.min(adjacent.start_time, slot.start_time);
              adjacent.time_count = last - adjacent.start_time;
              adjacent.endTime = endTimes.get(adjacent.start_time + adjacent.time_count) || adjacent.endTime;
            } else {
              map.get(name).push(slot);
            }
          }
        }
        return Array.from(map, ([name, slots]) => ({ name, slots }));
      };

      const flatten = (groups) => groups.flatMap((course) => course.slots.map((slot) => ({
        name: course.name,
        classroom: slot.classroom || "",
        class_number: null,
        teacher: slot.teacher || null,
        test_time: null,
        test_location: null,
        link: null,
        weeks: slot.weeks,
        week_time: slot.week_time,
        start_time: slot.start_time,
        time_count: slot.time_count,
        import_type: 1,
        info: slot.endTime ? `结束时间 ${slot.endTime}` : null,
        data: null,
      })));

      const docs = documents();
      const loginDocument = docs.find((doc) => {
        const password = Array.from(doc.querySelectorAll("input[type='password']"));
        if (password.length) return true;
        const body = clean(doc.body ? doc.body.textContent : "");
        return /统一身份认证|登录密码|账号登录|用户登录/.test(body) && !/学生课程表|课表查看/.test(body);
      });
      let groups = [];
      let term = "";
      for (const doc of docs) {
        const undergraduate = parseUndergraduate(doc);
        if (undergraduate.length) {
          groups = undergraduate;
          term = semesterFrom(doc);
          break;
        }
        const graduate = parseGraduate(doc);
        if (graduate.length) {
          groups = graduate;
          const select = doc.querySelector("#query_xnxq");
          const selected = select && select.selectedOptions && select.selectedOptions.length
            ? select.selectedOptions[0].textContent : "";
          term = normalizeTerm(selected || semesterFrom(doc));
          break;
        }
      }
      const courses = flatten(groups);
      if (!courses.length) {
        if (loginDocument) waitForPage("请先登录中国人民大学教务系统，再进入课表页面");
        waitForPage("尚未读取到人大课程，请完成登录并进入课表页面");
      }
      return encodeURIComponent(JSON.stringify({ name: term, courses }));
    })();
    """#
}
