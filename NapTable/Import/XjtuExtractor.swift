import Foundation

extension SchoolCatalog {
    /// 西安交通大学 eHall 学生课表。接口与字段参照 XLJFZ/xjtu-timetable-calendar
    /// (145915a9e3c31032cc03dfc4d10e5396b6fce912)，在已登录网页中独立实现。
    /// 学期来自 dqxnxq，周次以 SKZC 左起第一位为第 1 周；钟点由服务端配置。
    static let xjtuExtractJS = #"""
    (() => {
      if (location.protocol !== "https:" || location.hostname !== "ehall.xjtu.edu.cn"
          || !location.pathname.startsWith("/jwapp/sys/wdkb/")) {
        throw new Error("请先登录西安交通大学 eHall，选择学生角色并进入「我的课表」");
      }

      const text = (value) => String(value == null ? "" : value).trim();
      const loginError = () => new Error("登录已失效，请重新登录西安交通大学 eHall");
      const requestJSON = (path, body = "") => {
        const xhr = new XMLHttpRequest();
        xhr.open("POST", path, false);
        xhr.setRequestHeader("Accept", "application/json, text/plain, */*");
        xhr.setRequestHeader("X-Requested-With", "XMLHttpRequest");
        xhr.setRequestHeader("Content-Type", "application/x-www-form-urlencoded; charset=UTF-8");
        xhr.send(body);
        if (xhr.status === 401) throw loginError();
        if (xhr.status === 403) throw new Error("当前账号没有学生课表访问权限，请确认已选择学生角色");
        if (xhr.status !== 200) throw new Error("西交大课表接口返回 HTTP " + xhr.status);
        const source = text(xhr.responseText);
        if (source.startsWith("<") && /统一身份|账号登录|用户登录|请输入密码|(?:login|cas|ids)\.xjtu\.edu\.cn/.test(source)) {
          throw loginError();
        }
        let root;
        try { root = JSON.parse(source); }
        catch (_) { throw new Error("西交大课表接口没有返回有效 JSON，请确认已进入学生课表"); }
        if (!root || typeof root !== "object" || Array.isArray(root)) {
          throw new Error("西交大课表接口响应格式已变化");
        }
        if (root.code != null && String(root.code) !== "0") {
          throw new Error("西交大课表接口查询失败，请重新登录后重试");
        }
        return root;
      };

      const current = requestJSON("/jwapp/sys/wdkb/modules/jshkcb/dqxnxq.do");
      const termPattern = /^20\d{2}-20\d{2}-[12]$/;
      const terms = new Set();
      Object.values(current.datas || {}).forEach((module) => {
        const first = module && Array.isArray(module.rows) && module.rows[0];
        const code = first && text(first.DM || first.XNXQDM);
        if (termPattern.test(code)) terms.add(code);
      });
      if (terms.size !== 1) throw new Error("无法确定西交大当前学年学期，请进入学生课表后重新解析");
      const semester = Array.from(terms)[0];
      const root = requestJSON("/jwapp/sys/wdkb/modules/xskcb/xskcb.do",
        "XNXQDM=" + encodeURIComponent(semester));
      const table = root.datas && root.datas.xskcb;
      if (!table || !Array.isArray(table.rows)) throw new Error("西交大接口未返回学生课程列表，课表格式可能已变化");
      if (table.extParams && table.extParams.code != null && Number(table.extParams.code) !== 1) {
        throw new Error("西交大学生课表查询失败，请重新解析");
      }
      if (Number(table.totalSize) > table.rows.length) {
        throw new Error("西交大接口返回的课表不完整，请重新解析或反馈此问题");
      }

      const parseWeeks = (row) => {
        const mask = text(row.SKZC);
        if (/^[01]+$/.test(mask)) {
          const weeks = [];
          Array.from(mask).forEach((bit, index) => {
            if (bit !== "1") return;
            if (index >= 40) throw new Error("教学周超出 App 支持的 40 周范围");
            weeks.push(index + 1);
          });
          return weeks;
        }
        const source = text(row.ZCMC).replace(/[～~—–至]/g, "-")
          .replace(/[（]/g, "(").replace(/[）]/g, ")").replace(/\s+/g, "");
        if (!source) throw new Error("缺少有效周次");
        const weeks = new Set();
        source.split(/[,，、;；]/).forEach((part) => {
          const match = part.match(/^(\d+)(?:-(\d+))?(?:周)?(?:\(([单双])(?:周)?\)|([单双])周?)?$/);
          if (!match) throw new Error("无法识别教学周次「" + part + "」");
          const start = Number(match[1]), end = Number(match[2] || match[1]);
          if (start < 1 || end < start || end > 40) throw new Error("教学周次范围无效或超过 40 周");
          const parity = match[3] || match[4];
          for (let week = start; week <= end; week++) {
            if (parity === "单" && week % 2 === 0) continue;
            if (parity === "双" && week % 2 === 1) continue;
            weeks.add(week);
          }
        });
        if (!weeks.size) throw new Error("没有有效教学周次");
        return Array.from(weeks).sort((a, b) => a - b);
      };

      const courses = [], seen = new Set();
      table.rows.forEach((row, index) => {
        try {
          if (!row || typeof row !== "object" || Array.isArray(row)) throw new Error("课程记录格式无效");
          const name = text(row.KCM);
          if (!name) throw new Error("缺少课程名称");
          if (text(row.XNXQDM) && text(row.XNXQDM) !== semester) throw new Error("课程学期与查询学期不一致");
          const day = Number(row.SKXQ), start = Number(row.KSJC), end = Number(row.JSJC);
          if (!Number.isInteger(day) || day < 1 || day > 7) throw new Error("星期无效");
          if (!Number.isInteger(start) || !Number.isInteger(end) || start < 1 || end < start
              || end > 64 || end - start > 32) throw new Error("节次范围无效");
          const weeks = parseWeeks(row);
          if (!weeks.length) return; // 全零掩码表示没有排课，不能解释为每周上课。
          // ISTK 的含义未由参考项目确认；与其解析结果一致，保留所有有排课的记录。
          const course = {
            name: name, classroom: text(row.JASMC), class_number: text(row.KCH),
            teacher: text(row.SKJS), weeks: weeks, week_time: day,
            start_time: start, time_count: end - start, import_type: 1,
            info: text(row.XXXQDM_DISPLAY),
          };
          const key = JSON.stringify([text(row.JXBID), course]);
          if (!seen.has(key)) { seen.add(key); courses.push(course); }
        } catch (error) {
          throw new Error("第 " + (index + 1) + " 条课程：" + error.message);
        }
      });
      if (!courses.length) throw new Error("西交大当前学期没有可导入的课程，请确认已选课并完成排课");
      return JSON.stringify({ name: semester, courses: courses });
    })();
    """#
}
