import Foundation

extension SchoolCatalog {
    /// 浙江大学本科生教务网（zdbk.zju.edu.cn）的课表提取脚本。
    ///
    /// 参考 Celechron 的 ZDBK 流程：统一认证完成后，在教务同源页面用
    /// `/jwglxt/kbcx/xskbcx_cxXsKb.html` 查询当前学期的 `kbList`，不接触账号密码。
    /// 课表接口的周次通常由 `dsz`（单双周）给出；若响应包含 `zc`，优先使用接口
    /// 的明确周次。节次由 `djj`（起始节）和 `skcd`（持续节数）组成。
    static let zjuExtractJS = #"""
    (() => {
      const ORIGIN = "https://zdbk.zju.edu.cn";
      const MAX_WEEK = 40;
      const DEFAULT_WEEK_COUNT = 16;

      if (location.origin !== ORIGIN || !location.pathname.startsWith("/jwglxt/")) {
        throw new Error("请先登录浙江大学统一认证，进入本科教务网后再点「重新解析」");
      }

      const text = (value) => String(value == null ? "" : value)
        .replace(/\u00a0/g, " ").replace(/\s+/g, " ").trim();
      const int = (value) => {
        const result = parseInt(value, 10);
        return isNaN(result) ? 0 : result;
      };
      const loginError = () => new Error("登录已失效，请重新登录浙江大学统一认证");

      const selected = (selector) => {
        const select = document.querySelector(selector);
        if (!select) return null;
        let value = text(select.value);
        let label = "";
        if (select.selectedOptions && select.selectedOptions.length) {
          label = text(select.selectedOptions[0].textContent || select.selectedOptions[0].innerText);
          if (!value) value = text(select.selectedOptions[0].value);
        }
        if (!label && select.options) {
          for (let i = 0; i < select.options.length; i++) {
            if (select.options[i].selected || select.options[i].defaultSelected) {
              value = value || text(select.options[i].value);
              label = text(select.options[i].textContent || select.options[i].innerText);
              break;
            }
          }
        }
        return value || label ? { value: value, label: label } : null;
      };

      // 浙大这个地址在不同版本的教务网里既可能返回带下拉框的 HTML，
      // 也可能直接返回 JSON（浏览器会把它显示成一串 JSON 文本）。
      const pageJSON = () => {
        try {
          const node = document.body;
          const raw = text(node && (node.innerText || node.textContent));
          if (!raw) return null;
          const first = JSON.parse(raw);
          if (typeof first === "string") return JSON.parse(first);
          return first;
        } catch (_) { return null; }
      };
      const pageRoot = pageJSON();
      const pageItems = Array.isArray(pageRoot)
        ? pageRoot
        : (pageRoot && Array.isArray(pageRoot.kbList) ? pageRoot.kbList : null);
      const valueFrom = (root, keys) => {
        if (!root || typeof root !== "object") return "";
        for (let i = 0; i < keys.length; i++) {
          const value = root[keys[i]];
          if (value != null && text(value)) return text(value);
        }
        return "";
      };
      const termCode = (value, label) => {
        const raw = text(value);
        if (raw === "3" || raw === "12" || raw === "16") return raw;
        if (/第二|春夏|春/.test(raw + " " + text(label))) return "12";
        if (/短/.test(raw + " " + text(label))) return "16";
        if (/第一|秋冬|秋/.test(raw + " " + text(label))) return "3";
        const match = raw.match(/(?:^|[-_])(\d{1,2})$/);
        if (match) return match[1] === "1" ? "3" : match[1] === "2" ? "12" : match[1];
        return "";
      };
      const yearFrom = (value) => {
        const match = text(value).match(/20\d{2}/);
        return match ? match[0] : "";
      };
      const pageYear = valueFrom(pageRoot, ["xnm", "XNM", "xn", "XN", "year", "academicYear", "xnmmc", "XNMMC", "xnxqmc", "XNXQMC"])
        || yearFrom(valueFrom(pageRoot, ["xnxqdm", "XNXQDM", "xnxq", "XNXQ", "term", "semester"]));
      const pageTermValue = valueFrom(pageRoot, ["xqm", "XQM", "xq", "XQ", "xqmmc", "XQMMC", "xqmc", "XQMC", "term", "semester", "xnxqdm", "XNXQDM", "xnxq", "XNXQ"]);
      const yearOption = selected("#xnm") || selected("select[name='xnm']");
      const termOption = selected("#xqm") || selected("select[name='xqm']");
      let year = yearOption && yearOption.value || pageYear;
      let term = termCode(termOption && termOption.value, termOption && termOption.label)
        || termCode(pageTermValue, termOption && termOption.label);
      const yearLabel = yearOption && yearOption.label || "";
      const termLabel = termOption && termOption.label || pageTermValue;
      const yearMatch = text(year || yearLabel).match(/20\d{2}/);
      if (yearMatch) year = yearMatch[0];
      // 直接 JSON 课表响应的旧版本可能只返回 kbList/xh，不带学年字段。
      // 这时用当前日期推断当前学年学期；服务端学期配置仍会做最终校准。
      if (!year && pageItems) {
        const now = new Date();
        const month = now.getMonth() + 1;
        // Celechron 以 9 月作为学年边界：9 月起是秋冬，次年 2 月起是春夏。
        year = String(now.getFullYear() - (month < 9 ? 1 : 0));
        if (!term) term = month < 9 ? "12" : "3";
      }
      if (!year) throw new Error("无法读取当前学年，请进入学生课表页面后重试");
      if (!term) term = termCode(term, termLabel);
      if (!term) throw new Error("无法读取当前学期，请进入学生课表页面后重试");

      // 与 Celechron 一样，当前学期由今天的学年边界决定，不采用页面可能残留的历史下拉选项。
      // 9 月至次年 1 月是秋冬（3），2 月至 8 月是春夏（12）。
      const today = new Date();
      const month = today.getMonth() + 1;
      const currentYear = month >= 9 ? today.getFullYear() : today.getFullYear() - 1;
      const currentTerm = month >= 9 || month <= 1 ? "3" : "12";
      year = String(currentYear);
      term = currentTerm;

      const semesterNumber = term === "12" ? 2 : term === "16" ? 0 : 1;
      const academicName = semesterNumber === 0
        ? year + "-" + (Number(year) + 1) + "学年短学期"
        : year + "-" + (Number(year) + 1) + "学年第" + semesterNumber + "学期";

      const request = () => {
        const xhr = new XMLHttpRequest();
        const query = "gnmkdm=N2151&xnm=" + encodeURIComponent(year)
          + "&xqm=" + encodeURIComponent(term) + "&kzlx=ck";
        xhr.open("POST", ORIGIN + "/jwglxt/kbcx/xskbcx_cxXsKb.html?" + query, false);
        xhr.setRequestHeader("Accept", "application/json, text/plain, */*");
        xhr.setRequestHeader("Content-Type", "application/x-www-form-urlencoded; charset=UTF-8");
        xhr.setRequestHeader("X-Requested-With", "XMLHttpRequest");
        xhr.send(query);
        if (xhr.status === 401 || xhr.status === 403) throw loginError();
        if (xhr.status !== 200) throw new Error("浙大教务课表接口返回 HTTP " + xhr.status);
        const source = text(xhr.responseText);
        if (!source || source[0] === "<") {
          if (/用户登录|统一认证|cas|login/i.test(source)) throw loginError();
          throw new Error("浙大教务课表接口没有返回有效数据");
        }
        let root;
        try { root = JSON.parse(source); }
        catch (_) { throw new Error("浙大教务课表接口返回的数据格式已变化"); }
        if (root && (root.code === 401 || root.code === 403)) throw loginError();
        return root;
      };

      const decode = (value) => text(value)
        .replace(/&nbsp;/gi, " ").replace(/&amp;/gi, "&")
        .replace(/&lt;/gi, "<").replace(/&gt;/gi, ">").replace(/&quot;/gi, '"');
      const courseFields = (value) => {
        const raw = decode(value).replace(/<br\s*\/?>/gi, "\n")
          .replace(/<[^>]*>/g, "");
        const lines = raw.split(/\n+/).map(text).filter(Boolean);
        const roomIndex = lines.findIndex((line) => line.indexOf("zwf") >= 0);
        const room = roomIndex >= 0 ? lines[roomIndex].replace(/zwf[\s\S]*$/, "") : (lines[3] || "");
        return { name: lines[0] || "", teacher: lines[2] || "", classroom: text(room) };
      };

      const range = (start, end) => {
        const result = [];
        for (let week = Math.max(1, start); week <= Math.min(MAX_WEEK, end); week++) result.push(week);
        return result;
      };
      const parseWeeks = (value, dsz) => {
        const raw = text(value).replace(/[～~—–至]/g, "-");
        const result = new Set();
        if (raw) {
          raw.split(/[,，、;；]/).forEach((part) => {
            const numbers = part.match(/\d+/g) || [];
            if (!numbers.length) return;
            const start = Number(numbers[0]), end = Number(numbers[1] || numbers[0]);
            const weeks = range(start, end);
            const odd = /单/.test(part), even = !odd && /双/.test(part);
            weeks.forEach((week) => {
              if (odd && week % 2 === 0) return;
              if (even && week % 2 === 1) return;
              result.add(week);
            });
          });
        }
        if (!result.size) {
          const parity = String(dsz == null ? "" : dsz);
          range(1, DEFAULT_WEEK_COUNT).forEach((week) => {
            if (parity === "1" && week % 2 === 1) return;
            if (parity === "0" && week % 2 === 0) return;
            result.add(week);
          });
        }
        return Array.from(result).sort((a, b) => a - b);
      };

      // GET 页面可能只返回空的 kbList 初始化 JSON；空数组仍需 POST 查询。
      // 页面 JSON 可能带有历史课程；只把它用于读取学期参数，课程统一来自当前学期 POST。
      const root = request();
      if (root === null) return JSON.stringify({ name: academicName, courses: [] });
      const items = Array.isArray(root) ? root : (root && Array.isArray(root.kbList) ? root.kbList : null);
      if (!items) throw new Error("浙大教务课表接口缺少 kbList 数组");
      const courses = [];
      const seen = new Set();
      items.forEach((item, index) => {
        if (!item || typeof item !== "object" || String(item.sfyjskc || "") === "1") return;
        const itemYear = yearFrom(valueFrom(item, ["xnm", "XNM", "xn", "XN", "year", "academicYear",
          "xnmmc", "XNMMC", "xnxqmc", "XNXQMC"])
          || valueFrom(item, ["xnxqdm", "XNXQDM", "xnxq", "XNXQ"]));
        const itemTerm = termCode(valueFrom(item, ["xqm", "XQM", "xq", "XQ", "xqmmc", "XQMMC",
          "xqmc", "XQMC", "xnxqdm", "XNXQDM", "xnxq", "XNXQ"]), "");
        if (itemYear && itemYear !== year) return;
        if (itemTerm && itemTerm !== term) return;
        const fields = courseFields(item.kcb);
        const name = text(item.kcmc || item.courseName || fields.name);
        const day = int(item.xqj), start = int(item.djj), duration = int(item.skcd);
        if (!name || day < 1 || day > 7 || start < 1 || duration < 1) return;
        const weeks = parseWeeks(item.zc || item.ZC || item.zcd || item.week, item.dsz);
        if (!weeks.length) return;
        const course = {
          name: name,
          classroom: text(item.cdmc || item.classroom || fields.classroom),
          class_number: text(item.kch_id || item.kch || item.kchId),
          teacher: text(item.xm || item.teacher || fields.teacher),
          weeks: weeks,
          week_time: day,
          start_time: start,
          time_count: Math.max(0, duration - 1),
          import_type: 1,
          info: text(item.xxq || item.kcbj || ""),
        };
        const identity = [item.kch_id || item.kch || name, day, start, duration, weeks.join(",")].join("|");
        if (!seen.has(identity)) { seen.add(identity); courses.push(course); }
      });

      return JSON.stringify({ name: academicName, courses: courses });
    })();
    """#
}
