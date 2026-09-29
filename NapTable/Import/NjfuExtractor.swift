import Foundation

extension SchoolCatalog {
    /// 南京林业大学教务系统（强智 jwxt.njfu.edu.cn/jsxsd）的课表提取脚本。
    ///
    /// 参照 NJFU-schedule 的 `NjfuImporter`：统一认证（uia.njfu.edu.cn）登录后
    /// 回到教务系统，在教务同源页面里用同步 XHR 读「学期理论课表」
    /// `/jsxsd/xskb/xskb_list.do`，解析 `table#timetable`。每个格子里的
    /// `div.kbcontent` 是完整信息（`kbcontent1` 是隐藏的简版），一格多门课用一串
    /// `-----` 隔开；课程名是不带 title 的文字，教师、周次(节次)、教室分别是
    /// `title` 为「老师/教师」「周次(节次)」「教室」的 `<font>`。
    ///
    /// 周次(节次)写作 `1-16(周)[01-02节]`、`1-8,10-16(周)[03-04节]`、
    /// `1-15(单周)[05-06节]`。学期写在 `#xnxq01id` 的选中项里，如
    /// `2025-2026-1`，服务端没有标记当前学期时学期匹配靠它。
    static let njfuExtractJS = #"""
    (() => {
      const HOST = "jwxt.njfu.edu.cn";
      const MAX_WEEK = 30;
      // 格子里没写节次时，按大节所在的行兜底（与 NJFU-schedule 一致）。
      const ROW_SECTIONS = [[1, 2], [3, 4], [5, 6], [7, 8], [9, 11]];
      const SKIPPED_FONTS = ["tzdbh", "wkxx", "ktmcstr", "bzstr", "xsks", "jxlmc"];

      if (location.host !== HOST) {
        throw new Error("请先登录南京林业大学统一认证，进入教务系统后再点「重新解析」");
      }

      const xhr = new XMLHttpRequest();
      xhr.open("GET", "/jsxsd/xskb/xskb_list.do?_t=" + Date.now(), false);
      xhr.send(null);
      if (xhr.status !== 200) {
        throw new Error("教务课表页面返回 HTTP " + xhr.status);
      }
      const html = xhr.responseText || "";
      if (html.indexOf("timetable") < 0) {
        if (/authserver\/login|type=["']?password|用户登录/.test(html)) {
          throw new Error("登录已失效，请重新登录统一认证");
        }
        throw new Error("教务系统没有返回课表页面，可能本学期尚未排课或页面已变化");
      }

      const doc = new DOMParser().parseFromString(html, "text/html");
      const table = doc.getElementById("timetable");
      if (!table) throw new Error("没有找到课表，可能本学期尚未排课");

      const clean = (value) => String(value == null ? "" : value).replace(/\s+/g, " ").trim();
      const tagOf = (node) => String(node.tagName || "").toUpperCase();

      const range = (a, b) => {
        const out = [];
        for (let w = Math.max(1, a); w <= Math.min(b, MAX_WEEK); w++) out.push(w);
        return out;
      };
      const parityOf = (text) => (/单/.test(text) ? 1 : /双/.test(text) ? 2 : 0);
      const parseWeeks = (text) => {
        // 单双周只管它所在的那一段：「1-8,10-16(单周)」里的 1-8 周是连续的。
        const set = new Set();
        text.replace(/[（]/g, "(").replace(/[）]/g, ")").split(/[,，、]/).forEach((segment) => {
          const parity = parityOf(segment);
          const digits = segment.replace(/\([^)]*\)|周|单|双/g, "").trim();
          const bounds = digits.split(/[-–—~]/).map((n) => parseInt(n, 10));
          let weeks = [];
          if (bounds.length >= 2 && !isNaN(bounds[0]) && !isNaN(bounds[1])) {
            weeks = range(Math.min(bounds[0], bounds[1]), Math.max(bounds[0], bounds[1]));
          } else if (!isNaN(bounds[0])) {
            weeks = range(bounds[0], bounds[0]);
          }
          weeks.filter((w) => parity === 0 || (parity === 1) === (w % 2 === 1)).forEach((w) => set.add(w));
        });
        return Array.from(set).sort((a, b) => a - b);
      };
      const parseSections = (text) => {
        const match = text.match(/\[([^\]]+)节\]/);
        if (!match) return null;
        const nums = (match[1].match(/\d+/g) || []).map((n) => parseInt(n, 10));
        return nums.length ? [nums[0], nums[nums.length - 1]] : null;
      };

      // 把一个 div.kbcontent 拆成若干门课：`-----` 分隔，每门课是若干段文字/字体。
      const blocksOf = (div) => {
        const blocks = [[]];
        const walk = (nodes) => {
          Array.from(nodes).forEach((node) => {
            if (node.nodeType === 3) {
              const pieces = String(node.textContent).split(/-{5,}/);
              pieces.forEach((piece, i) => {
                if (i > 0) blocks.push([]);
                const text = clean(piece);
                if (text) blocks[blocks.length - 1].push({ title: "", text: text });
              });
            } else if (tagOf(node) === "FONT") {
              const style = String(node.getAttribute("style") || "").replace(/\s/g, "");
              if (style.indexOf("display:none") >= 0) return;
              if (SKIPPED_FONTS.indexOf(node.getAttribute("name") || "") >= 0) return;
              const text = clean(node.textContent);
              if (/^-{5,}$/.test(text)) { blocks.push([]); return; }
              if (text) blocks[blocks.length - 1].push({ title: clean(node.getAttribute("title")), text: text });
            } else if (node.nodeType === 1 && tagOf(node) !== "BR") {
              const style = String(node.getAttribute("style") || "").replace(/\s/g, "");
              if (style.indexOf("display:none") < 0) walk(node.childNodes);
            }
          });
        };
        walk(div.childNodes);
        return blocks;
      };

      const courses = [];
      const seen = new Set();
      let slotRow = -1;
      Array.from(table.getElementsByTagName("tr")).forEach((tr) => {
        const cells = Array.from(tr.children).filter((c) => tagOf(c) === "TD");
        if (cells.length < 7) return;
        slotRow += 1;
        cells.slice(0, 7).forEach((td, index) => {
          const day = index + 1;
          Array.from(td.getElementsByTagName("div"))
            .filter((div) => String(div.getAttribute("class") || "").split(/\s+/).indexOf("kbcontent") >= 0)
            .forEach((div) => blocksOf(div).forEach((parts) => {
              let name = "", teacher = "", classroom = "", timing = "";
              parts.forEach((part) => {
                if (part.title === "老师" || part.title === "教师") teacher = part.text;
                else if (part.title === "教室") classroom = part.text;
                else if (part.title.indexOf("周次") >= 0 || (/周/.test(part.text) && /\[.*节\]/.test(part.text))) timing = part.text;
                else if (!part.title && !name) name = part.text;
              });
              if (!name || !timing) return;
              const weeks = parseWeeks(timing.split("[")[0]);
              const sections = parseSections(timing) || ROW_SECTIONS[slotRow];
              if (!weeks.length || !sections) return;
              const identity = [name, day, sections[0], weeks.join(",")].join("|");
              if (seen.has(identity)) return;
              seen.add(identity);
              courses.push({
                name: name,
                teacher: teacher,
                classroom: classroom,
                weeks: weeks,
                week_time: day,
                start_time: sections[0],
                time_count: Math.max(0, sections[1] - sections[0]),
                info: timing,
              });
            }));
        });
      });

      // 学期：选中的 2025-2026-1；拿不到就从页面里找第一个这种写法。
      let term = "";
      const select = doc.getElementById("xnxq01id");
      if (select) {
        const options = Array.from(select.getElementsByTagName("option"));
        const chosen = options.find((o) => o.hasAttribute("selected")) || options[0];
        if (chosen) term = clean(chosen.getAttribute("value") || chosen.textContent);
      }
      if (!/^20\d{2}-20\d{2}-[12]$/.test(term)) {
        const match = html.match(/20\d{2}-20\d{2}-[12](?!\d)/);
        term = match ? match[0] : "";
      }
      const parts = term.split("-");
      const name = parts.length === 3 ? parts[0] + "-" + parts[1] + "学年第" + parts[2] + "学期" : "";

      return JSON.stringify({ name: name, courses: courses });
    })();
    """#
}
