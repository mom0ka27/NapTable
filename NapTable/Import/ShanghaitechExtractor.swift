import Foundation

extension SchoolCatalog {
    /// 上海科技大学研究生课表。参考 Benedict999/shanghaitech-timetable 的
    /// 官方门户、同源 iframe、学期选择器和 loadPkjg 排课字段，独立实现转换。
    /// 来源与 MIT 许可证见 THIRD_PARTY_NOTICES.md。
    /// 只复用学校网页会话；不读取账号、密码或 Cookie。
    static let shanghaitechExtractJS = #"""
    (() => {
      const ORIGIN = "https://graduate.shanghaitech.edu.cn";
      const MODULE = "/gsapp/sys/wdkbappshtech/";
      const text = (value) => String(value == null ? "" : value).replace(/\s+/g, " ").trim();
      const integer = (value) => /^\d+$/.test(text(value)) ? Number(value) : 0;
      const wait = (message) => {
        const error = new Error(message);
        error.name = "NapTableNotReady";
        throw error;
      };
      const loginError = () => new Error("登录已失效，请重新登录上海科技大学统一身份认证");
      if (location.origin !== ORIGIN || !location.pathname.startsWith("/gsapp/")) {
        wait("请先登录上海科技大学研究生综合服务平台并进入「学生课程表」");
      }

      // 门户主地址不随课表 iframe 切换。直接打开课表模块时也可读取。
      let courseDocument = document;
      let courseWindow = window;
      if (!location.pathname.startsWith(MODULE)) {
        const frame = document.getElementById("iframeContent_wdkbappshtechxskcb");
        if (!frame) wait("请在研究生综合服务平台打开「学生课程表」（我的课表）");
        const source = new URL(frame.src, location.href);
        if (source.origin !== ORIGIN || !source.pathname.startsWith(MODULE)) {
          wait("正在等待学校的学生课程表页面加载…");
        }
        try {
          courseWindow = frame.contentWindow;
          courseDocument = frame.contentDocument;
          if (!courseWindow || !courseDocument || courseWindow.location.origin !== ORIGIN
              || !courseWindow.location.pathname.startsWith(MODULE)) {
            wait("学生课程表页面仍在加载，请稍候…");
          }
        } catch (_) {
          wait("学生课程表页面尚未就绪，请确认已登录并打开课表");
        }
      }
      const select = courseDocument.getElementById("query_xnxq");
      const termCode = text(select && select.value);
      if (!termCode) wait("课表学期仍在加载，请稍候…");
      const option = select.options && select.options[select.selectedIndex];
      const termLabel = text(option && option.textContent);
      if (!termLabel) throw new Error("无法读取课表学期名称，请在学生课程表中重新选择学期");

      // XNXQDM 来自学校选择器，不根据日期拼接内部学期代码。
      const xhr = new courseWindow.XMLHttpRequest();
      xhr.open("POST", ORIGIN + MODULE + "xskbBy/loadPkjg.do", false);
      xhr.setRequestHeader("Content-Type", "application/x-www-form-urlencoded; charset=UTF-8");
      xhr.setRequestHeader("X-Requested-With", "XMLHttpRequest");
      try { xhr.send("XNXQDM=" + encodeURIComponent(termCode) + "&ZC="); }
      catch (_) { throw new Error("无法连接上海科技大学课表接口，请检查网络后重新解析"); }
      if (xhr.status === 401 || xhr.status === 403) throw loginError();
      if (xhr.status !== 200) throw new Error("上海科技大学课表接口返回 HTTP " + xhr.status);
      if (xhr.responseURL && new URL(xhr.responseURL).origin !== ORIGIN) throw loginError();
      const source = text(xhr.responseText);
      if (source.startsWith("<")) throw loginError();
      let root;
      try { root = JSON.parse(source); }
      catch (_) { throw new Error("上海科技大学课表接口返回的数据格式已变化，请稍后重试"); }
      if (root && (Number(root.code) === 401 || Number(root.code) === 403)) throw loginError();
      if (!root || !Array.isArray(root.jgList)) {
        throw new Error("上海科技大学课表接口缺少排课结果，请确认登录状态后重试");
      }
      if (text(select.value) !== termCode) throw new Error("读取期间学期已切换，请重新解析");

      const invalid = () => new Error("部分排课数据不完整或格式已变化，已停止导入，请保留原课表并稍后重试");
      const parseWeeks = (value) => {
        const raw = text(value).replace(/\s/g, "").replace(/[～~－—–至]/g, "-")
          .replace(/[（]/g, "(").replace(/[）]/g, ")").replace(/[第周]/g, "");
        if (!raw) throw invalid();
        const weeks = new Set();
        // 末尾的单双周标记作用于整个周次表达式，例如「1-3,5-9周(单)」。
        const globalParity = raw.match(/\(([单双])\)$/);
        const parts = (globalParity ? raw.slice(0, globalParity.index) : raw).split(/[,，、;；]/);
        for (const part of parts) {
          const match = part.match(/^(\d+)(?:-(\d+))?(?:\(?([单双])\)?)?$/);
          if (!match) throw invalid();
          const start = Number(match[1]), end = Number(match[2] || match[1]);
          if (start < 1 || end > 40 || end < start) throw invalid();
          const parity = match[3] || (globalParity && globalParity[1]);
          for (let week = start; week <= end; week++) {
            if (parity === "单" && week % 2 === 0 || parity === "双" && week % 2 === 1) continue;
            weeks.add(week);
          }
        }
        if (!weeks.size) throw invalid();
        return Array.from(weeks).sort((a, b) => a - b);
      };
      const courses = [];
      for (const row of root.jgList) {
        if (!row || typeof row !== "object") throw invalid();
        const name = text(row.KCMC);
        const day = integer(row.XQ), start = integer(row.KSJCDM), end = integer(row.JSJCDM);
        if (!name || day < 1 || day > 7 || start < 1 || end < start || end > 64 || end - start > 32) {
          throw invalid();
        }
        const course = {
          name: name,
          classroom: text(row.JASMC),
          class_number: text(row.KCDM || row.BJDM),
          teacher: text(row.JGJSXM),
          weeks: parseWeeks(row.ZCMC),
          week_time: day,
          start_time: start,
          time_count: end - start,
          import_type: 1,
          info: text(row.BJMC),
        };
        // 保留每条排课，换日、不同节次数、教师及教室均交给导入预览处理。
        courses.push(course);
      }
      // 学校内部学期代码与 NapTable 服务端 termID 不同，不直接写入 termID。
      // 校历和节次方案由对应学校的服务端学期配置校准。
      return JSON.stringify({ name: "上海科技大学研究生课表 " + termLabel, courses: courses });
    })();
    """#
}
