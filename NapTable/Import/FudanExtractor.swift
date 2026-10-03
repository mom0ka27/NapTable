import Foundation

extension SchoolCatalog {
    /// 复旦大学本科生新版教务系统课表提取脚本。
    ///
    /// 课表页本身只展示学期选择器，实际课程由
    /// `/student/for-std/course-table/semester/{id}/print-data` 返回。这个
    /// 接口的 `studentTableVms[0].activities` 字段是 DanXi 当前使用的格式。
    static let fudanExtractJS = #"""
    (() => {
      const host = (location.hostname || "").toLowerCase();
      if (host && !(host === "fudan.edu.cn" || host.endsWith(".fudan.edu.cn"))) {
        throw new Error("请先登录复旦大学教务系统，并进入个人课表页面");
      }

      const text = (value) => String(value == null ? "" : value)
        .replace(/\u00a0/g, " ").replace(/\s+/g, " ").trim();

      const jsonText = (value) => {
        try {
          const source = String(value || "").trim();
          if (!source || (source[0] !== "{" && source[0] !== "[")) return null;
          return JSON.parse(source);
        } catch (_) { return null; }
      };

      const requestJSON = (url) => {
        const xhr = new XMLHttpRequest();
        xhr.open("GET", url, false);
        xhr.setRequestHeader("Accept", "application/json, text/plain, */*");
        xhr.send(null);
        if (xhr.status === 401 || xhr.status === 403) {
          throw new Error("登录已失效，请重新登录复旦大学教务系统");
        }
        if (xhr.status !== 200) {
          throw new Error("复旦教务课表接口返回 HTTP " + xhr.status);
        }
        const value = jsonText(xhr.responseText);
        if (!value) throw new Error("复旦教务课表接口没有返回有效 JSON");
        return value;
      };

      const semesterFromPage = () => {
        if (typeof document === "undefined") return null;
        const selectors = [
          "#allSemesters option[selected]", "#allSemesters option",
          "select#semester option[selected]", "select#semester option",
        ];
        for (const selector of selectors) {
          const option = document.querySelector(selector);
          if (option && option.value) {
            return { id: String(option.value), name: text(option.textContent || option.innerText) };
          }
        }

        // DanXi 兼容的复旦页面会在脚本中注入：
        // var semesters = JSON.parse('[{"id":505,"name":"..."}]');
        const html = document.documentElement && document.documentElement.innerHTML || "";
        const match = html.match(/var\s+semesters\s*=\s*JSON\.parse\((['"])([\s\S]*?)\1\)\s*;/);
        if (!match) return null;
        try {
          const escaped = match[2].replace(/\\'/g, "'").replace(/\\"/g, '"').replace(/\\\\/g, "\\");
          const list = JSON.parse(escaped);
          const item = Array.isArray(list) && list[0];
          return item && item.id != null ? { id: String(item.id), name: text(item.name) } : null;
        } catch (_) { return null; }
      };

      const parseWeeks = (value) => {
        if (Array.isArray(value)) {
          return value.map((item) => Number(item)).filter((week) => week >= 1 && week <= 40);
        }
        const result = new Set();
        text(value).replace(/[～~]/g, "-").split(/[,，、;；]/).forEach((part) => {
          const numbers = part.match(/\d+/g) || [];
          if (!numbers.length) return;
          const start = Number(numbers[0]);
          const end = Number(numbers[1] || numbers[0]);
          const odd = /单/.test(part);
          const even = !odd && /双/.test(part);
          for (let week = Math.max(1, start); week <= Math.min(40, end); week++) {
            if (odd && week % 2 === 0) continue;
            if (even && week % 2 === 1) continue;
            result.add(week);
          }
        });
        return Array.from(result).sort((a, b) => a - b);
      };

      const parseActivities = (root, semesterName) => {
        const vm = root && root.studentTableVms && root.studentTableVms[0];
        const activities = vm && Array.isArray(vm.activities) ? vm.activities : [];
        const courses = [];
        const seen = new Set();
        activities.forEach((activity) => {
          if (!activity || typeof activity !== "object") return;
          const name = text(activity.courseName || activity.name);
          const day = Number(activity.weekday);
          const start = Number(activity.startUnit);
          const end = Number(activity.endUnit || start);
          const weeks = parseWeeks(activity.weekIndexes);
          if (!name || day < 1 || day > 7 || start < 1 || end < start || !weeks.length) return;
          const teachers = Array.isArray(activity.teachers)
            ? activity.teachers.map(text).filter(Boolean).join("、")
            : text(activity.teacher || activity.teacherName);
          const course = {
            name: name,
            classroom: text(activity.room),
            class_number: text(activity.lessonCode || activity.lessonId),
            teacher: teachers,
            weeks: weeks,
            week_time: day,
            start_time: start,
            time_count: end - start,
            import_type: 1,
            info: "",
          };
          const key = [course.name, course.classroom, course.teacher, day, start, end,
            weeks.join(",")].join("|");
          if (!seen.has(key)) { seen.add(key); courses.push(course); }
        });
        return { name: semesterName || "复旦大学课表", courses: courses };
      };

      const semester = semesterFromPage();
      let root = null;
      if (semester && semester.id) {
        root = requestJSON("/student/for-std/course-table/semester/"
          + encodeURIComponent(semester.id) + "/print-data");
        const result = parseActivities(root, semester.name);
        if (result.courses.length) return JSON.stringify(result);
      }
      throw new Error("课表接口返回了数据，但没有找到可导入的课程安排，请确认当前学期");
    })();
    """#
}
