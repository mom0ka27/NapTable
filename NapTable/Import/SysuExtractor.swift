import Foundation

extension SchoolCatalog {
    /// 中山大学教务系统（jwxt.sysu.edu.cn）的课表提取脚本。
    ///
    /// 参照 sysukcb 的 `JwxtImportService`：登录后在教务同源页面里用同步 XHR
    /// 调教务的 JSON 接口，先读当前学年学期，再读学生课表。教务的学期写作
    /// `2025-1`（1 是秋季学期、2 是春季学期），表名写成
    /// `2025-2026学年第1学期`，服务端没有标记当前学期时学期匹配靠它。
    ///
    /// 周次字符串（`1-16周`、`1-15周(单)`、`2,4,6周`）按 sysukcb 的
    /// `WeekMask.parse` 规则展开：空串只算起始周，单双周只过滤对应奇偶。
    static let sysuExtractJS = #"""
    (() => {
      const ORIGIN = "https://jwxt.sysu.edu.cn";
      const MAX_WEEK = 30;

      if (location.origin !== ORIGIN) {
        throw new Error("请先登录中山大学教务系统，进入教务首页后再点「重新解析」");
      }

      const call = (method, path, body, menuId) => {
        const xhr = new XMLHttpRequest();
        const sep = path.indexOf("?") >= 0 ? "&" : "?";
        xhr.open(method, ORIGIN + path + sep + "_t=" + Math.floor(Date.now() / 1000), false);
        xhr.setRequestHeader("Accept", "application/json, text/plain, */*");
        xhr.setRequestHeader("Content-Type", "application/json;charset=UTF-8");
        xhr.setRequestHeader("X-Requested-With", "XMLHttpRequest");
        xhr.setRequestHeader("menuId", menuId || "jwxsd_xskbcx");
        xhr.setRequestHeader("lastAccessTime", String(Date.now()));
        xhr.send(body ? JSON.stringify(body) : null);
        if (xhr.status === 401 || xhr.status === 403) {
          throw new Error("登录已失效，请重新登录教务系统");
        }
        if (xhr.status !== 200) {
          throw new Error("教务接口 " + path + " 返回 HTTP " + xhr.status);
        }
        let json;
        try {
          json = JSON.parse(xhr.responseText);
        } catch (e) {
          throw new Error("教务没有返回课表数据，可能登录已失效，请重新登录");
        }
        if (json && json.code != null && Number(json.code) !== 200) {
          const code = Number(json.code);
          if (code === 401 || code === 403) throw new Error("登录已失效，请重新登录教务系统");
          throw new Error(json.message || json.msg || "教务接口返回 " + json.code);
        }
        return json ? json.data : null;
      };

      const text = (value) => (value == null ? "" : String(value)).trim().replace(/\/+$/, "").trim();
      const courseName = (value) => {
        const raw = text(value);
        const match = raw.match(/^[^()（）]*[（(][^()（）]*[）)]\s*(.+)$/);
        return match ? match[1].trim() : raw;
      };
      const classroom = (value) => text(value).split(/[-－—]/).pop()
        .replace(/[（(]\s*\d+\s*座\s*[）)]/g, "").trim();
      const int = (value) => {
        const n = parseInt(value, 10);
        return isNaN(n) ? 0 : n;
      };

      const range = (a, b) => {
        const out = [];
        for (let w = Math.max(1, a); w <= Math.min(b, MAX_WEEK); w++) out.push(w);
        return out;
      };

      const parsePart = (part, startWeek) => {
        const token = part.trim();
        if (!token) return [];
        const odd = token.indexOf("单") >= 0;
        const even = !odd && token.indexOf("双") >= 0;
        const cleaned = token.replace(/每周|单周|双周|周|单|双|[()（）]/g, "").trim();
        let weeks = [];
        if (!cleaned) {
          weeks = range(startWeek, MAX_WEEK);
        } else {
          const bounds = cleaned.split(/[-–—~]/);
          if (bounds.length >= 2) {
            const a = parseInt(bounds[0].replace(/\D/g, ""), 10);
            const b = parseInt(bounds[1].replace(/\D/g, ""), 10);
            if (!isNaN(a) && !isNaN(b)) weeks = range(Math.min(a, b), Math.max(a, b));
          } else {
            const n = parseInt(cleaned.replace(/\D/g, ""), 10);
            if (!isNaN(n) && n >= 1 && n <= MAX_WEEK) weeks = [n];
          }
        }
        if (odd) weeks = weeks.filter((w) => w % 2 === 1);
        if (even) weeks = weeks.filter((w) => w % 2 === 0);
        return weeks;
      };

      const parseWeeks = (detail, startWeek) => {
        const first = Math.max(1, startWeek);
        const raw = String(detail || "").replace(/\//g, "").trim();
        if (!raw) return [first];
        const set = new Set();
        raw.split(/[,，、;；]/).forEach((part) => parsePart(part, first).forEach((w) => set.add(w)));
        if (set.size === 0) return [first];
        return Array.from(set).sort((a, b) => a - b);
      };

      const current = call("GET", "/jwxt/base-info/acadyearterm/showNewAcadlist") || {};
      const semester = text(current.acadYearSemester);
      if (!semester) throw new Error("无法读取当前学年学期");

      const table = call("POST", "/jwxt/timetable-search/stuTimeTabPrint/studentQuery", {
        acadYear: semester,
        submitFlag: "1",
        nothroughCourseFlag: "1",
      }) || {};
      const timetable = table.timetable || {};

      const courses = [];
      const seen = new Set();
      Object.keys(timetable).forEach((key) => {
        const items = timetable[key];
        if (!Array.isArray(items)) return;
        items.forEach((item) => {
          if (!item) return;
          const name = courseName(item.courseName);
          if (!name) return;
          const startWeek = int(item.startWeek) || 1;
          const detail = text(item.timeDetail);
          const weeks = parseWeeks(item.timeDetail, startWeek);
          const day = int(item.week);
          const start = int(item.startClassTimes);
          const end = int(item.endClassTimes);
          const identity = [item.classesId || name, day, start, weeks.join(",")].join("|");
          if (seen.has(identity)) return;
          seen.add(identity);
          courses.push({
            name: name,
            teacher: text(item.teachingStaffName),
            classroom: classroom(item.classPlace),
            weeks: weeks,
            week_time: day,
            start_time: start,
            time_count: Math.max(0, end - start),
            info: detail,
          });
        });
      });

      const parts = semester.split("-");
      const year = parseInt(parts[0], 10);
      const name = parts.length === 2 && !isNaN(year)
        ? year + "-" + (year + 1) + "学年第" + parts[1] + "学期"
        : semester;

      return JSON.stringify({ name: name, courses: courses });
    })();
    """#
}
