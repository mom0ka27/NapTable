import Foundation

extension SchoolCatalog {
    /// 南京工业大学本科教学管理与服务平台（正方）的课表提取脚本。
    ///
    /// 参照 GiuseppeLR/njtech_timetable 的导入流程：登录后进入「学生个人课表」
    /// 页面，从页面的学年、学期选择框读取查询参数，再在同源页面里请求个人课表
    /// JSON。课表接口返回的 `kbList`、`sjkList` 和 `jxhjkcList` 分别覆盖普通课、
    /// 实践课和教学环节课程。
    ///
    /// 这里只在已登录的 WebView 内读取接口，不接触账号密码。脚本使用同步 XHR，
    /// 因为 `SchoolWebCoordinator` 需要拿到 JavaScript 最后一条表达式的返回值。
    static let njtechExtractJS = #"""
    (() => {
      const HOST = "jwgl.njtech.edu.cn";
      const MAX_WEEK = 40;

      if (location.hostname && location.hostname.toLowerCase() !== HOST) {
        throw new Error("请先登录南京工业大学教务系统，并进入「学生个人课表」页面");
      }

      const valueOf = (element) => element == null ? "" : String(element.value == null ? element : element.value).trim();
      const optionText = (selector) => {
        const element = document.querySelector(selector);
        if (!element) return "";
        const selected = element.selectedOptions && element.selectedOptions[0];
        return String((selected && (selected.textContent || selected.innerText)) || element.textContent || "").trim();
      };
      const selectedValue = (selector) => {
        const element = document.querySelector(selector);
        return valueOf(element);
      };
      const clean = (value) => String(value == null ? "" : value)
        .replace(/<[^>]*>/g, " ")
        .replace(/\s+/g, " ")
        .trim();
      const range = (start, end) => {
        const first = Math.max(1, Math.min(start, end));
        const last = Math.min(MAX_WEEK, Math.max(start, end));
        const result = [];
        for (let week = first; week <= last; week++) result.push(week);
        return result;
      };

      const parseWeeks = (raw) => {
        const text = clean(raw).replace(/[（]/g, "(").replace(/[）]/g, ")");
        if (!text || /未安排|待定|无/.test(text)) return [];
        const result = new Set();
        text.split(/[,，、;；]/).forEach((part) => {
          const token = part.trim();
          if (!token) return;
          const odd = /单/.test(token);
          const even = !odd && /双/.test(token);
          const cleaned = token.replace(/每周|周|单周|双周|单|双|\([^)]*\)/g, "").trim();
          const bounds = cleaned.match(/\d+/g) || [];
          if (!bounds.length) return;
          const start = parseInt(bounds[0], 10);
          const end = bounds.length > 1 ? parseInt(bounds[1], 10) : start;
          range(start, end).forEach((week) => {
            if (odd && week % 2 === 0) return;
            if (even && week % 2 === 1) return;
            result.add(week);
          });
        });
        return Array.from(result).sort((a, b) => a - b);
      };

      const parseWeekday = (raw) => {
        const text = clean(raw);
        const map = { 一: 1, 二: 2, 三: 3, 四: 4, 五: 5, 六: 6, 日: 7, 天: 7 };
        if (map[text]) return map[text];
        const chinese = text.match(/[一二三四五六日天]/);
        if (chinese && map[chinese[0]]) return map[chinese[0]];
        const match = text.match(/[1-7]/);
        return match ? parseInt(match[0], 10) : 0;
      };

      const parseSections = (raw) => {
        const text = clean(raw);
        const bounds = text.match(/\d+/g) || [];
        if (!bounds.length) return null;
        const start = parseInt(bounds[0], 10);
        const end = bounds.length > 1 ? parseInt(bounds[bounds.length - 1], 10) : start;
        if (start < 1 || end < start || end > 64) return null;
        return [start, end];
      };

      const academicName = (raw) => {
        const text = clean(raw).replace(/[—–]/g, "-");
        const match = text.match(/(20\d{2})\s*-\s*(20\d{2})/);
        if (match) return match[1] + "-" + match[2];
        const year = text.match(/20\d{2}/);
        return year ? year[0] + "-" + (parseInt(year[0], 10) + 1) : "";
      };

      const termNumber = (value, label) => {
        const text = clean(label + " " + value);
        // 正方系统常用 xqm=3 表示第一学期、xqm=12 表示第二学期。
        if (/第二|下半年|春|12\b/.test(text)) return 2;
        if (/第一|上半年|秋|3\b/.test(text)) return 1;
        const match = text.match(/[12]/);
        return match ? parseInt(match[0], 10) : 0;
      };

      const xnm = selectedValue("#xnm");
      const xqm = selectedValue("#xqm");
      const academic = academicName(optionText("#xnm") || xnm);
      const semester = termNumber(xqm, optionText("#xqm"));
      const name = academic && semester ? academic + "学年第" + semester + "学期" : "";

      const params = [
        ["gnmkdm", "N2151"],
        ["xnm", xnm],
        ["xqm", xqm],
        ["kzlx", "ck"],
        ["xsdm", selectedValue("#xsdm")],
        ["kclbdm", selectedValue("#kclbdm")],
        ["kclxdm", selectedValue("#kclxdm")],
      ].map(([key, value]) => encodeURIComponent(key) + "=" + encodeURIComponent(value)).join("&");

      const xhr = new XMLHttpRequest();
      xhr.open("POST", "/kbcx/xskbcx_cxXsgrkb.html", false);
      xhr.setRequestHeader("Content-Type", "application/x-www-form-urlencoded; charset=UTF-8");
      xhr.setRequestHeader("X-Requested-With", "XMLHttpRequest");
      xhr.setRequestHeader("Accept", "application/json, text/plain, */*");
      xhr.send(params);
      if (xhr.status === 401 || xhr.status === 403) {
        throw new Error("登录已失效，请重新登录南京工业大学教务系统");
      }
      if (xhr.status !== 200) {
        throw new Error("教务课表接口返回 HTTP " + xhr.status);
      }
      if (/用户登录|统一身份认证|login_slogin|请输入用户名/.test(xhr.responseText || "")) {
        throw new Error("登录已失效，请重新登录南京工业大学教务系统");
      }

      let body;
      try {
        body = JSON.parse(xhr.responseText || "{}");
      } catch (error) {
        throw new Error("教务课表接口没有返回 JSON，可能登录已失效");
      }
      const rawCourses = [];
      ["kbList", "sjkList", "jxhjkcList"].forEach((key) => {
        if (Array.isArray(body[key])) rawCourses.push(...body[key]);
      });

      const courses = [];
      const seen = new Set();
      rawCourses.forEach((item) => {
        if (!item || typeof item !== "object") return;
        const courseName = clean(item.kcmc || item.KCMC || item.courseName);
        if (!courseName) return;
        const weekday = parseWeekday(item.xqj == null ? item.weekday : item.xqj);
        const sections = parseSections(item.jcs == null ? item.jc : item.jcs);
        const weeks = parseWeeks(item.zcd == null ? item.weeks : item.zcd);
        if (weekday < 1 || weekday > 7 || !sections) return;
        const start = sections[0];
        const end = sections[1];
        const teacher = clean(item.xm || item.teacher || item.teachingStaffName);
        const classroom = clean(item.cdmc || item.classroom || item.classPlace);
        const identity = [item.kch_id || item.kch || courseName, teacher, classroom,
          weekday, start, end, weeks.join(",")].join("|");
        if (seen.has(identity)) return;
        seen.add(identity);
        courses.push({
          name: courseName,
          class_number: clean(item.kch_id || item.kch || item.courseId),
          teacher: teacher,
          classroom: classroom,
          weeks: weeks.length ? weeks : Array.from({ length: 20 }, (_, index) => index + 1),
          week_time: weekday,
          start_time: start,
          time_count: Math.max(0, end - start),
          import_type: 1,
          info: clean(item.jxbmc || item.jxb || item.bz || item.remark),
        });
      });

      return JSON.stringify({ name: name, courses: courses });
    })();
    """#
}
