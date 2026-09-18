import Foundation

/// One importable school. Ported from the Flutter app's `School` /
/// `ImportView.getOnlineConfig()` catalogue: every entry is a login page plus
/// the JavaScript that turns the authenticated page into the course JSON
/// contract `CoursePayloadCodec` reads.
struct SchoolConfig: Identifiable, Equatable, Hashable {
    var id: String { pinyin }
    var title: String
    var pinyin: String
    var summary: String
    var pageTitle: String
    var initialURL: String
    var redirectURL: String
    var targetURL: String
    var preExtractJS: String
    var delayTime: Double
    var extractJS: String
    var bannerContent: String?
    var bannerAction: String?
    var bannerURL: String?
    /// Class-time override shipped with the school entry, if any.
    var classTimeList: [ClassTime]?
    /// ISO Monday of week 1 shipped with the school entry, if any.
    var semesterStartMonday: String?

    /// All login/import routes of one university share its server configuration.
    var serviceSchoolID: String {
        let host = URL(string: initialURL)?.host?.lowercased() ?? ""
        for id in ["nju", "seu", "ucas"] {
            if host == "\(id).edu.cn" || host.hasSuffix(".\(id).edu.cn") { return id }
        }
        return pinyin
    }

    var hasExtractor: Bool { !extractJS.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
}

/// The built-in catalogue. The Flutter app downloaded this list from
/// `UPDATE_ROOT/schoolList.json` and the extractors from a CDN; shipping both in
/// the binary keeps first-run imports working offline and removes the only
/// network dependency of the import screen.
enum SchoolCatalog {
    static let all: [SchoolConfig] = [
        SchoolConfig(
            title: "南京大学本科生教务系统",
            pinyin: "1nanjingdaxuebenkejiaowu",
            summary: "通过教务系统我的课表进行导入",
            pageTitle: "教务系统登录",
            initialURL: "https://authserver.nju.edu.cn/authserver/login?service=https%3A%2F%2Fehallapp.nju.edu.cn%2Fjwapp%2Fsys%2Fwdkb%2F*default%2Findex.do%23%2Fxskcb",
            redirectURL: "",
            targetURL: "https://ehallapp.nju.edu.cn/jwapp/sys/wdkb/*default/index.do#/xskcb",
            preExtractJS: "",
            delayTime: 3,
            extractJS: "(() => {\n  const WEEK_MAP = { 一: 1, 二: 2, 三: 3, 四: 4, 五: 5, 六: 6, 日: 7 };\n\n  /* 1.  name 只拿学年学期文字 */\n  const name = document.querySelector(\"#dqxnxqkclb\").textContent.trim(); // “2025-2026学年 第1学期”\n\n  /* 2. 逐行解析 */\n  const courses = [];\n  document\n    .querySelector(\"table tbody\")\n    .querySelectorAll(\"tr\")\n    .forEach((tr) => {\n      const td = tr.querySelectorAll(\"td\");\n      const classNumber = td[1].textContent.trim(); // 课程号\n      const courseName = td[2].textContent.trim(); // 课程名\n      const teacher = td[4].textContent.trim();\n      const testTime = td[10].textContent.trim() || null;\n      const info = td[8].textContent.trim() || null;\n      const timeLocFull = td[6].textContent.trim();\n\n      /* 周数解析 */\n      function parseWeeks(weekStr) {\n        const weeks = [];\n\n        weekStr.split(\",\").forEach((part) => {\n          // 检查是否为单双周\n          const isSingle = part.includes(\"(单)\");\n          const isDouble = part.includes(\"(双)\");\n          const cleanPart = part\n            .replace(/周/g, \"\")\n            .replace(/\\(单\\)/g, \"\")\n            .replace(/\\(双\\)/g, \"\"); // 去掉\"周\"字\n          if (cleanPart.includes(\"-\")) {\n            const [start, end] = cleanPart.split(\"-\").map(Number);\n            if (isSingle) {\n              // 单周：从start开始，取奇数周\n              let current = start % 2 === 1 ? start : start + 1;\n              for (let i = current; i <= end; i += 2) weeks.push(i);\n            } else if (isDouble) {\n              // 双周：从start开始，取偶数周\n              let current = start % 2 === 0 ? start : start + 1;\n              for (let i = current; i <= end; i += 2) weeks.push(i);\n            } else {\n              // 普通周：连续周\n              for (let i = start; i <= end; i++) weeks.push(i);\n            }\n          } else {\n            weeks.push(Number(cleanPart));\n          }\n        });\n        return weeks;\n      }\n\n      /* 按逗号拆多段 */\n      timeLocFull.split(/,周|，/).forEach((seg) => {\n        /* 自由时间 */\n        if (/自由时间/.test(seg)) {\n          const weeks = parseWeeks(\n            seg.match(/([\\d\\-,]+)周/)?.[1] || \"1-18\",\n            seg,\n          );\n          courses.push({\n            name: courseName,\n            classroom: \"自由地点\",\n            class_number: classNumber,\n            teacher,\n            test_time: testTime,\n            test_location: null,\n            link: null,\n            weeks,\n            week_time: 0,\n            start_time: 0,\n            time_count: 0,\n            import_type: 1,\n            info,\n            data: null,\n          });\n          return;\n        }\n\n        /* 正常匹配 */\n        // 周三 2-4节 14-18周 基础实验楼丙405\n        // 周三 2-4节 1-3周,10-13周 仙Ⅱ-304\n        // 周二 5-8节 2-18周(双) 仙1-216\n        const m = seg.match(\n          /([一二三四五六日])?\\s*(\\d+)-(\\d+)节\\s*([\\d\\-,周]+(?:\\([单双]\\))?)\\s*(.+)/,\n        );\n\n        if (!m) return;\n        const weekDay = WEEK_MAP[m[1]];\n        const startTime = Number(m[2]);\n        const endTime = Number(m[3]);\n        const classroom = m[5];\n        const weeks = parseWeeks(m[4]);\n\n        courses.push({\n          name: courseName,\n          classroom,\n          class_number: classNumber,\n          teacher,\n          test_time: testTime,\n          test_location: null,\n          link: null,\n          weeks,\n          week_time: weekDay,\n          start_time: startTime,\n          time_count: endTime - startTime, // 不+1\n          import_type: 1,\n          info,\n          data: null,\n        });\n      });\n    });\n\n  // return { name, courses };\n  return encodeURIComponent(JSON.stringify({ name, courses }));\n})();\n",
            bannerContent: "注意：如加载失败，请连接南京大学VPN\n试试浏览器访问教务网，没准系统又抽风了\n听起来有点离谱，不过在南京大学，倒也正常",
            bannerAction: "下载南京大学VPN",
            bannerURL: "https://ztna.nju.edu.cn",
            classTimeList: nil,
            semesterStartMonday: nil
        ),
        SchoolConfig(
            title: "南京大学本科生选课系统",
            pinyin: "1nanjingdaxuebenkexuanke",
            summary: "通过选课系统进行课表导入",
            pageTitle: "选课系统登录",
            initialURL: "https://xk.nju.edu.cn",
            redirectURL: "",
            targetURL: "https://xk.nju.edu.cn/xsxkapp/sys/xsxkapp/*default/grablessons.do",
            preExtractJS: "document.getElementsByClassName('yxkc-window-btn')[0].click();document.getElementsByClassName('jqx-tabs-titleContentWrapper ')[0].click();",
            delayTime: 3,
            extractJS: "function getWeekSeriesString(info) {\n  let weekList = [];\n  let strs = [];\n  try {\n    info = info.split(\" \")[2];\n    strs = info.split(\",\");\n  } catch (e) {\n    return \"[]\";\n  }\n\n  for (let i = 0; i < strs.length; i++) {\n    var rst4 = strs[i].match(/^(\\d{1,2})周$/);\n    if (rst4 != null) {\n      weekList.push(rst4[1]);\n    }\n\n    var rst2 = strs[i].match(/(\\d{1,2})-(\\d{1,2})周/);\n    if (rst2 != null) {\n      let startWeek = parseInt(rst2[1]);\n      let endWeek = parseInt(rst2[2]);\n      if (strs[i].includes(\"单\") || strs[i].includes(\"双\")) {\n        for (let j = startWeek; j <= endWeek; j = j + 2) {\n          weekList.push(j);\n        }\n      } else {\n        for (let j = startWeek; j <= endWeek; j++) {\n          weekList.push(j);\n        }\n      }\n    }\n  }\n  return weekList;\n}\n\nfunction scheduleHtmlParser() {\n  let WEEK_WITH_BIAS = [\n    \"\",\n    \"周一\",\n    \"周二\",\n    \"周三\",\n    \"周四\",\n    \"周五\",\n    \"周六\",\n    \"周日\",\n  ];\n  let WEEK_NUM = 17;\n\n  // let name = \"\";\n  let name = document.getElementsByClassName(\"currentTerm\")[0].innerHTML;\n  let rst = { name: name, courses: [] };\n  let tableHeads = document.getElementsByClassName(\"course-head\");\n  let tableHead = tableHeads[tableHeads.length - 1];\n  let headElements = tableHead.children[0].children;\n  let infoIndex = 3;\n  let courseNameIndex = 1;\n  let courseTeacherIndex = 2;\n  let courseInfoIndex = 6;\n  for (let i = 0; i < headElements.length; i++) {\n    //  console.log(headElements[i].innerHTML);\n    if (headElements[i].innerHTML.includes(\"时间地点\")) {\n      infoIndex = i;\n    } else if (headElements[i].innerHTML.includes(\"课程名\")) {\n      courseNameIndex = i;\n    } else if (headElements[i].innerHTML.includes(\"教师\")) {\n      courseTeacherIndex = i;\n    } else if (headElements[i].innerHTML.includes(\"备注\")) {\n      courseInfoIndex = i;\n    }\n  }\n  let tables = document.getElementsByClassName(\"course-body\");\n  let table = tables[tables.length - 1];\n  let elements = table.children;\n\n  for (let i = 0; i < elements.length; i++) {\n    // console.log(elements[i]);\n    //退选课程\n    // String state = e.children[6].innerHtml.trim();\n    // if(state.contains('已退选')) continue;\n\n    if (elements[i].className.includes(\"wdbm-course-tr\")) continue;\n    // print(e.className);\n\n    // Time and Place\n    let infos = elements[i].children[infoIndex].children;\n    let courseName = elements[i].children[courseNameIndex].innerHTML;\n    let courseTeacher = elements[i].children[courseTeacherIndex].innerHTML;\n    let courseInfo =\n      elements[i].children[courseInfoIndex].attributes[\"title\"].value;\n\n    // console.log(infos);\n    for (let j = 0; j < infos.length; j++) {\n      let info = infos[j].innerHTML;\n      if (info == \"\") continue;\n      info = info.replace(/^\\s+|\\s+$/gm, \"\");\n      // console.log(info);\n\n      let strs = info.split(\" \");\n\n      //自由时间缺省值\n      let weekTime = 0;\n      let startTime = 0;\n      let timeCount = 0;\n      if (!info.includes(\"自由时间\")) {\n        // Get WeekTime\n        let weekStr = info.substring(0, 2);\n        for (let k = 0; k < WEEK_WITH_BIAS.length; k++) {\n          if (WEEK_WITH_BIAS[k] == weekStr) {\n            weekTime = k;\n          }\n        }\n      }\n\n      let weekSeries;\n      // console.log(info)\n\n      let time = info.match(/(\\d{1,2})-(\\d{1,2})节/);\n      // console.log(time);\n      // var time = patten1.firstMatch(info);\n      if (time) {\n        startTime = parseInt(time[1]);\n        timeCount = parseInt(time[2]) - startTime;\n        weekSeries = getWeekSeriesString(info);\n      }\n      if (weekSeries == null) {\n        weekSeries = [];\n        for (let j = 1; j <= WEEK_NUM; j++) {\n          weekSeries.push(j);\n        }\n      }\n\n      // Get ClassRoom\n      let classRoom = strs[strs.length - 1];\n      if (\n        classRoom.match(/(\\d{1,2}|单|双)周$/) ||\n        classRoom.includes(\"自由时间\")\n      ) {\n        classRoom = \"\";\n      }\n\n      // console.log(weekTime);\n      rst[\"courses\"].push({\n        name: courseName,\n        classroom: classRoom,\n        // class_number: class_number,\n        teacher: courseTeacher,\n        // test_time: test_time,\n        // test_location: test_location,\n        link: null,\n        weeks: weekSeries,\n        week_time: weekTime,\n        start_time: startTime,\n        time_count: timeCount,\n        import_type: 1,\n        info: courseInfo,\n        data: null,\n      });\n    }\n  }\n  // return rst;\n  return encodeURIComponent(JSON.stringify(rst));\n}\nscheduleHtmlParser();\n",
            bannerContent: "注意：如加载失败，请连接南京大学VPN\n试试浏览器访问教务网，没准系统又抽风了\n听起来有点离谱，不过在南京大学，倒也正常",
            bannerAction: "下载南京大学VPN",
            bannerURL: "https://ztna.nju.edu.cn",
            classTimeList: nil,
            semesterStartMonday: nil
        ),
        SchoolConfig(
            title: "南京大学研究生教务系统",
            pinyin: "1nanjingdaxueyanjiujiaowu",
            summary: "研究生怎么还有单独的界面啊",
            pageTitle: "教务系统登录",
            initialURL: "https://authserver.nju.edu.cn/authserver/login?service=https%3A%2F%2Fehallapp.nju.edu.cn%2Fgsapp%2Fsys%2Fwdkbapp%2F*default%2Findex.do%23%2Fxskcb",
            redirectURL: "",
            targetURL: "https://ehallapp.nju.edu.cn/gsapp/sys/wdkbapp/*default/index.do#/xskcb",
            preExtractJS: "",
            delayTime: 3,
            extractJS: "function scheduleHtmlParser() {\n  // 1. 获取学期列表\n  var getTerms = function () {\n    var xhr = new XMLHttpRequest();\n    xhr.open(\n      \"POST\",\n      \"https://ehallapp.nju.edu.cn/gsapp/sys/wdkbapp/modules/xskcb/kfdxnxqcx.do\",\n      false\n    );\n    xhr.send();\n    var data = JSON.parse(xhr.responseText);\n    var terms = data.datas.kfdxnxqcx.rows;\n    terms.sort((a, b) => a.PX - b.PX); // 早→新\n    return terms;\n  };\n\n  // 2. 获取课表\n  var getRawKb = function (termCode) {\n    var xhr = new XMLHttpRequest();\n    xhr.open(\n      \"POST\",\n      \"https://ehallapp.nju.edu.cn/gsapp/sys/wdkbapp/modules/xskcb/xsjxrwcx.do\",\n      false\n    );\n    xhr.setRequestHeader(\"Content-Type\", \"application/x-www-form-urlencoded\");\n    xhr.send(\"XNXQDM=\" + termCode);\n    return JSON.parse(xhr.responseText).datas.xsjxrwcx.rows;\n  };\n\n  // 3. 解析信息\n  function parseInfo(info) {\n    const result = [];\n    const segments = info.split(\";\");\n\n    segments.forEach((seg) => {\n      // 5-9单周,13-17单周 星期五[3-4节]仙Ⅰ-319;4-18周 星期一[3-4节];4-18双周 星期五[3-4节]\n      const match = seg.match(\n        /(.+?周)\\s*星期(.+?)\\[(.+?)节\\](.*)/\n      );\n      if (!match) return;\n\n      const [, weekPart, dayPart, timePart, classroom] = match;\n\n      // 解析周次\n      const weeks = [];\n      weekPart.split(\",\").forEach((w) => {\n        var m = w.match(/(\\d+)-?(\\d+)?(?:(单|双))?周/);\n        if (!m) return [];\n        var start = parseInt(m[1], 10);\n        var end = parseInt(m[2], 10);\n        if (isNaN(end)) end = start;\n        var flag = { '单': 1, '双': 2 }[m[3]] || 0;\n        for (var w = start; w <= end; w++) {\n          if (flag === 0 || (flag === 1 && w % 2 === 1) || (flag === 2 && w % 2 === 0)) weeks.push(w);\n        }\n      });\n\n      // 解析星期几\n      const dayMap = { 一: 1, 二: 2, 三: 3, 四: 4, 五: 5, 六: 6, 日: 7 };\n      const week_time = dayMap[dayPart.trim()];\n\n      // 解析节次\n      const [startStr, endStr] = timePart.split(\"-\");\n      const start_time = parseInt(startStr, 10);\n      const time_count = parseInt(endStr, 10) - start_time;\n\n      result.push({\n        classroom: classroom.trim(),\n        weeks,\n        week_time,\n        start_time,\n        time_count,\n      });\n    });\n\n    return result;\n  }\n\n  var terms = getTerms();\n  var currentTerm = terms[0];\n  currentTermCode = currentTerm.XNXQDM;\n  currentTermName = currentTerm.XNXQDM_DISPLAY;\n\n  if (!currentTermCode) {\n    return encodeURIComponent(\n      JSON.stringify({\n        name: \"无法获取学期信息\",\n        courses: [],\n      })\n    );\n  }\n\n  // 5. 抓取并转换\n  var rows = getRawKb(currentTermCode);\n  var courses = [];\n  console.log(rows);\n  rows.forEach(function (r) {\n    var info = parseInfo(r.PKSJDD);\n    info.forEach(function (i) {\n      courses.push({\n        name: r.KCMC,\n        classroom: i.classroom,\n        class_number: r.KCDM,\n        teacher: r.RKJS,\n        test_time: null,\n        test_location: null,\n        link: null,\n        weeks: i.weeks,\n        week_time: i.week_time,\n        start_time: i.start_time,\n        time_count: i.time_count,\n        import_type: 1,\n        info: r.XKBZ,\n        data: null,\n      });\n    });\n  });\n\n  // 返回符合南哪课表格式的数据\n  var result = {\n    name: currentTermName,\n    courses: courses,\n  };\n  // return result;\n  return encodeURIComponent(JSON.stringify(result));\n}\n\nscheduleHtmlParser();\n",
            bannerContent: "注意：如加载失败，请连接南京大学VPN\n试试浏览器访问教务网，没准系统又抽风了\n听起来有点离谱，不过在南京大学，倒也正常",
            bannerAction: "下载南京大学VPN",
            bannerURL: "https://ztna.nju.edu.cn",
            classTimeList: nil,
            semesterStartMonday: nil
        ),
        SchoolConfig(
            title: "南京大学研究生选课系统",
            pinyin: "1nanjingdaxueyanjiuxuanke",
            summary: "研究生同学的课表导入方式",
            pageTitle: "选课系统登录",
            initialURL: "https://yjsxk.nju.edu.cn/yjsxkapp/sys/xsxkapp/index_nju.html",
            redirectURL: "https://yjsxk.nju.edu.cn/yjsxkapp/sys/xsxkapp/course_nju.html",
            targetURL: "https://yjsxk.nju.edu.cn/yjsxkapp/sys/xsxkapp/xsxkCourse/loadStdCourseInfo.do",
            preExtractJS: "",
            delayTime: 3,
            extractJS: "function scheduleHtmlParser() {\n  let WEEK_WITH_BIAS = [\"\", \"一\", \"二\", \"三\", \"四\", \"五\", \"六\", \"日\"];\n  let WEEK_NUM = 18;\n\n  data = JSON.parse(document.body.innerText.replace(/\\n/g, \"\"));\n  let name = data[\"results\"][data[\"results\"].length - 1][\"XNXQMC\"];\n  let rst = { name: name, courses: [] };\n  data[\"results\"].forEach((e) => {\n    // console.log(e['XNXQMC']);\n    let sem = e[\"XNXQMC\"];\n    if (sem != name) return;\n\n    let course_name = e[\"KCMC\"];\n    let class_number = e[\"KCDM\"];\n    let teacher = e[\"RKJS\"];\n    let test_time = \"\";\n    let test_location = \"\";\n    let course_info = e[\"XKBZ\"];\n    let info_str = e[\"PKSJDD\"];\n    // 自由时间课程处理\n    if (info_str == null) info_str = \"\";\n    let info_list = info_str.split(\";\");\n    info_list.forEach((i) => {\n      let week_time = 0;\n      let start_time = 0;\n      let time_count = 0;\n      let classroom = \"\";\n      let weeks = [];\n      //pattern: xx(-xx)(单/双)周 星期x[x-x节]x\n      let pattern = new RegExp(\n        \"(\\\\d{1,2})(-(\\\\d{1,2}))?(单|双)?周 星期(.)\\\\[(\\\\d{1,2})(-(\\\\d{1,2}))?节](.*)\",\n        \"i\",\n      );\n      let strs = pattern.exec(i);\n      if (strs != null) {\n        for (let z = 0; z < WEEK_WITH_BIAS.length; z++) {\n          if (WEEK_WITH_BIAS[z] == strs[5]) week_time = z;\n        }\n        if (strs[4] == \"单\") {\n          for (let z = parseInt(strs[1]); z <= parseInt(strs[3]); z += 2)\n            weeks.push(z);\n        } else if (strs[4] == \"双\") {\n          for (let z = parseInt(strs[1]); z <= parseInt(strs[3]); z += 2)\n            weeks.push(z);\n        } else if (typeof strs[2] == \"undefined\") {\n          // Just a single weak ...\n          weeks.push(parseInt(strs[1]));\n        } else {\n          for (let z = parseInt(strs[1]); z <= parseInt(strs[3]); z++)\n            weeks.push(z);\n        }\n        start_time = parseInt(strs[6]);\n        if (typeof strs[8] != \"undefined\") {\n          time_count = parseInt(strs[8]) - parseInt(strs[6]);\n        } else {\n          time_count = 1;\n        }\n        classroom = strs[9];\n      } else {\n        // 自由时间周数填充\n        for (let z = 1; z <= WEEK_NUM; z++) weeks.push(z);\n      }\n      rst[\"courses\"].push({\n        name: course_name,\n        classroom: classroom,\n        class_number: class_number,\n        teacher: teacher,\n        test_time: test_time,\n        test_location: test_location,\n        link: null,\n        weeks: weeks,\n        week_time: week_time,\n        start_time: start_time,\n        time_count: time_count,\n        import_type: 1,\n        info: course_info,\n        data: null,\n      });\n    });\n  });\n  rst[\"courses\"] = JSON.stringify(rst[\"courses\"]);\n  return encodeURIComponent(JSON.stringify(rst));\n}\nscheduleHtmlParser();\n",
            bannerContent: "导入方式：登陆后点击「我的选课」进入选课页\n注意：如加载失败，请连接南京大学VPN\n试试浏览器访问教务网，没准教务系统又抽风了\n听起来有点离谱，不过在南京大学，倒也正常",
            bannerAction: "下载南京大学VPN",
            bannerURL: "https://ztna.nju.edu.cn",
            classTimeList: nil,
            semesterStartMonday: nil
        ),
        SchoolConfig(
            title: "东南大学本研课表",
            pinyin: "dongnandaxue",
            summary: "南哪课表嘛，东南也算南哪（大误",
            pageTitle: "本研课表",
            initialURL: "http://ehall.seu.edu.cn/appShow?appId=5761129385495325",
            redirectURL: "",
            targetURL: "https://ehall.seu.edu.cn/jwapp/sys/bykb/*default/index.do",
            preExtractJS: "",
            delayTime: 3,
            extractJS: "function scheduleHtmlParser() {\n  // 配置常量\n  const CONFIG = {\n    APP_BASE: 'https://ehall.seu.edu.cn/jwapp/sys/bykb',\n    CURRENT_TERM_API: '/modules/jshkcb/dqxnxq.do',\n    TERM_LIST_API: '/modules/jshkcb/xnxqcx.do',\n    SCHEDULE_API: '/modules/xskcb/cxxszhxqkb.do',\n  };\n\n  const buildUrl = (path) => {\n    if (typeof WIS_EMAP_SERV !== 'undefined' && WIS_EMAP_SERV.getAbsPath) {\n      return WIS_EMAP_SERV.getAbsPath(path);\n    }\n    return `${CONFIG.APP_BASE}${path}`;\n  };\n\n  const encodeParams = (params = {}) => {\n    return Object.keys(params)\n      .map(key => `${encodeURIComponent(key)}=${encodeURIComponent(params[key])}`)\n      .join('&');\n  };\n\n  // 同步请求，优先使用页面自己的 EMAP Ajax 封装\n  const syncRequest = (path, params = {}) => {\n    const url = buildUrl(path);\n\n    if (typeof BH_UTILS !== 'undefined' && BH_UTILS.doSyncAjax) {\n      return BH_UTILS.doSyncAjax(url, params);\n    }\n\n    const xhr = new XMLHttpRequest();\n    xhr.open('POST', url, false); // 保持同步模式\n    xhr.setRequestHeader('Content-Type', 'application/x-www-form-urlencoded; charset=UTF-8');\n    xhr.setRequestHeader('Accept', 'application/json, text/javascript, */*; q=0.01');\n    xhr.send(encodeParams(params));\n    if (xhr.status !== 200) {\n      throw new Error(`HTTP Error: ${xhr.status}`);\n    }\n    return JSON.parse(xhr.responseText);\n  };\n\n  // 获取当前学期；若接口异常，回退到学期列表最新项\n  const fetchCurrentTerm = () => {\n    const data = syncRequest(CONFIG.CURRENT_TERM_API);\n    const rows = data?.datas?.dqxnxq?.rows || [];\n    if (rows.length > 0) return rows[0];\n\n    const termListData = syncRequest(CONFIG.TERM_LIST_API, { '*order': '-DM' });\n    const termRows = termListData?.datas?.xnxqcx?.rows || [];\n    return termRows[0];\n  };\n\n  // 获取原始课表数据\n  const fetchSchedule = (termCode) => {\n    const data = syncRequest(CONFIG.SCHEDULE_API, {\n      '*order': '+KSJC,+JSJC',\n      XNXQDM: termCode,\n    });\n    return data?.datas?.cxxszhxqkb?.rows || [];\n  };\n\n  // 解析周次（优先使用bitmap，回退到文本解析）\n  const parseWeeks = (zcmcText, bitMap) => {\n    // 方案1：优先使用bitmap（最准确）\n    if (typeof bitMap === 'string' && bitMap.length > 0) {\n      const weeks = [];\n      for (let i = 0; i < bitMap.length; i++) {\n        if (bitMap[i] === '1') weeks.push(i + 1);\n      }\n      if (weeks.length > 0) return weeks;\n    }\n\n    // 方案2：解析文本（如\"1-8周,9-16周(单)\"）\n    if (!zcmcText) return [];\n\n    const weekSet = new Set();\n    const parts = zcmcText.split(/[，,;；]/);\n\n    parts.forEach(part => {\n      const match = part.match(/(\\d+)(?:-(\\d+))?周?(?:\\((单|双)\\))?/);\n      if (!match) return;\n\n      const start = parseInt(match[1], 10);\n      const end = match[2] ? parseInt(match[2], 10) : start;\n      const parityFlags = { 单: 1, 双: 2 };\n      const parity = parityFlags[match[3]] || 0;\n\n      for (let w = start; w <= end; w++) {\n        const isOdd = (w % 2 === 1);\n        const shouldInclude =\n          parity === 0 ||\n          (parity === 1 && isOdd) ||\n          (parity === 2 && !isOdd);\n\n        if (shouldInclude) weekSet.add(w);\n      }\n    });\n\n    return Array.from(weekSet).sort((a, b) => a - b);\n  };\n\n  // 转换单条课程数据为目标格式\n  const transformCourse = (raw) => {\n    const weeks = parseWeeks(raw.ZCMC, raw.SKZC);\n    if (weeks.length === 0) return null;\n\n    const weekTime = parseInt(raw.SKXQ, 10);\n    const startTime = parseInt(raw.KSJC, 10);\n    const endTime = parseInt(raw.JSJC, 10);\n    if (!weekTime || !startTime || !endTime || endTime < startTime) return null;\n\n    return {\n      name: raw.KCM,\n      classroom: raw.JASMC || raw.JASMC_DISPLAY || '',\n      class_number: raw.KCH,\n      teacher: raw.SKJS,\n      test_time: null,\n      test_location: null,\n      link: null,\n      weeks: weeks,\n      week_time: weekTime,\n      start_time: startTime,\n      time_count: endTime - startTime, // 不 +1\n      import_type: 1,\n      info: raw.ZCMC,\n      data: null,\n    };\n  };\n\n  // 主流程\n  try {\n    // 步骤1：获取当前学期\n    const currentTerm = fetchCurrentTerm();\n\n    if (!currentTerm?.DM) {\n      throw new Error('无法获取当前学期信息');\n    }\n\n    console.log(`已选择学期：${currentTerm.DM} ${currentTerm.MC}`);\n\n    // 步骤2：获取并转换课表数据\n    const rawCourses = fetchSchedule(currentTerm.DM);\n    const courses = rawCourses\n      .map(transformCourse)\n      .filter(course => course !== null); // 过滤无有效周次的课程\n\n    // 步骤3：组装并返回结果\n    const result = {\n      name: currentTerm.MC,\n      courses: courses,\n    };\n\n    return encodeURIComponent(JSON.stringify(result));\n\n  } catch (error) {\n    console.error('课表解析失败:', error);\n    return encodeURIComponent(\n      JSON.stringify({\n        name: '无法获取学期信息',\n        courses: [],\n      })\n    );\n  }\n}\n\nscheduleHtmlParser();\n",
            bannerContent: "导入方式：登陆后自动获取当前学期课表\n注意：如加载失败，请连接东南大学VPN\n试试浏览器访问教务网，没准教务系统又抽风了",
            bannerAction: "下载东南大学VPN",
            bannerURL: "https://vpn.seu.edu.cn",
            classTimeList: [
                ClassTime(start: "08:00", end: "08:45"),
                ClassTime(start: "08:50", end: "09:35"),
                ClassTime(start: "09:50", end: "10:35"),
                ClassTime(start: "10:40", end: "11:25"),
                ClassTime(start: "11:30", end: "12:15"),
                ClassTime(start: "14:00", end: "14:45"),
                ClassTime(start: "14:50", end: "15:35"),
                ClassTime(start: "15:50", end: "16:35"),
                ClassTime(start: "16:40", end: "17:25"),
                ClassTime(start: "17:30", end: "18:15"),
                ClassTime(start: "19:00", end: "19:45"),
                ClassTime(start: "19:50", end: "20:35"),
                ClassTime(start: "20:40", end: "21:25"),
            ],
            semesterStartMonday: "2026-08-24"
        ),
        SchoolConfig(
            title: "上海交通大学研究生选课系统",
            pinyin: "shanghaijiaotongdaxueyanjiu",
            summary: "蛤交研究生同学的课表导入方式",
            pageTitle: "选课系统登录",
            initialURL: "https://yjsxk.sjtu.edu.cn/yjsxkapp/sys/xsxkapp/index.html",
            redirectURL: "https://yjsxk.sjtu.edu.cn/yjsxkapp/sys/xsxkapp/course.html",
            targetURL: "https://yjsxk.sjtu.edu.cn/yjsxkapp/sys/xsxkapp/xsxkCourse/loadStdCourseInfo.do",
            preExtractJS: "",
            delayTime: 3,
            extractJS: "function scheduleHtmlParser() {\n  let WEEK_WITH_BIAS = [\"\", \"一\", \"二\", \"三\", \"四\", \"五\", \"六\", \"日\"];\n  let WEEK_NUM = 18;\n\n  data = JSON.parse(document.body.innerText.replace(/\\n/g, \"\"));\n  let name = data[\"results\"][data[\"results\"].length - 1][\"XNXQMC\"];\n  let rst = { name: name, courses: [] };\n  data[\"results\"].forEach((e) => {\n    // console.log(e['XNXQMC']);\n    let sem = e[\"XNXQMC\"];\n    if (sem != name) return;\n\n    let course_name = e[\"KCMC\"];\n    let class_number = e[\"KCDM\"];\n    let teacher = e[\"RKJS\"];\n    let test_time = \"\";\n    let test_location = \"\";\n    let course_info = e[\"XKBZ\"];\n    let info_str = e[\"PKSJDD\"];\n    // 自由时间课程处理\n    if (info_str == null) info_str = \"\";\n    let info_list = info_str.split(\";\");\n    info_list.forEach((i) => {\n      let week_time = 0;\n      let start_time = 0;\n      let time_count = 0;\n      let classroom = \"\";\n      let weeks = [];\n      //pattern: xx(-xx)(单/双)周 星期x[x-x节]x\n      let pattern = new RegExp(\n        \"(\\\\d{1,2})(-(\\\\d{1,2}))?(单|双)?周 星期(.)\\\\[(\\\\d{1,2})(-(\\\\d{1,2}))?节](.*)\",\n        \"i\",\n      );\n      let strs = pattern.exec(i);\n      if (strs != null) {\n        for (let z = 0; z < WEEK_WITH_BIAS.length; z++) {\n          if (WEEK_WITH_BIAS[z] == strs[5]) week_time = z;\n        }\n        if (strs[4] == \"单\") {\n          for (let z = parseInt(strs[1]); z <= parseInt(strs[3]); z += 2)\n            weeks.push(z);\n        } else if (strs[4] == \"双\") {\n          for (let z = parseInt(strs[1]); z <= parseInt(strs[3]); z += 2)\n            weeks.push(z);\n        } else if (typeof strs[2] == \"undefined\") {\n          // Just a single weak ...\n          weeks.push(parseInt(strs[1]));\n        } else {\n          for (let z = parseInt(strs[1]); z <= parseInt(strs[3]); z++)\n            weeks.push(z);\n        }\n        start_time = parseInt(strs[6]);\n        if (typeof strs[8] != \"undefined\") {\n          time_count = parseInt(strs[8]) - parseInt(strs[6]);\n        } else {\n          time_count = 1;\n        }\n        classroom = strs[9];\n      } else {\n        // 自由时间周数填充\n        for (let z = 1; z <= WEEK_NUM; z++) weeks.push(z);\n      }\n      rst[\"courses\"].push({\n        name: course_name,\n        classroom: classroom,\n        class_number: class_number,\n        teacher: teacher,\n        test_time: test_time,\n        test_location: test_location,\n        link: null,\n        weeks: weeks,\n        week_time: week_time,\n        start_time: start_time,\n        time_count: time_count,\n        import_type: 1,\n        info: course_info,\n        data: null,\n      });\n    });\n  });\n  rst[\"courses\"] = JSON.stringify(rst[\"courses\"]);\n  return encodeURIComponent(JSON.stringify(rst));\n}\nscheduleHtmlParser();\n",
            bannerContent: "导入方式：登陆后点击「我的选课」进入选课页\n注意：如加载失败，请连接上交VPN\n试试浏览器访问教务网，没准教务系统又抽风了",
            bannerAction: "使用上海交通大学VPN",
            bannerURL: "https://net.sjtu.edu.cn/wlfw/VPN.htm",
            classTimeList: [
                ClassTime(start: "08:00", end: "08:45"),
                ClassTime(start: "08:55", end: "09:40"),
                ClassTime(start: "10:00", end: "10:45"),
                ClassTime(start: "10:55", end: "11:40"),
                ClassTime(start: "12:00", end: "12:45"),
                ClassTime(start: "12:55", end: "13:40"),
                ClassTime(start: "14:00", end: "14:45"),
                ClassTime(start: "14:55", end: "15:40"),
                ClassTime(start: "16:00", end: "16:45"),
                ClassTime(start: "16:55", end: "17:40"),
                ClassTime(start: "18:00", end: "18:45"),
                ClassTime(start: "18:55", end: "19:40"),
                ClassTime(start: "19:40", end: "20:20"),
                ClassTime(start: "20:25", end: "21:10"),
                ClassTime(start: "21:15", end: "22:00"),
            ],
            semesterStartMonday: "2026-09-14"
        ),
        SchoolConfig(
            title: "西北农林科技大学本科生教务系统",
            pinyin: "xibeinonglinkejidaxuebksjiaowu",
            summary: "西北怎么不算一种南哪儿呢",
            pageTitle: "统一身份认证",
            initialURL: "https://authserver.nwafu.edu.cn/authserver/login?service=https%3A%2F%2Fnewehall.nwafu.edu.cn%2Fjwapp%2Fsys%2Fwdkbby%2F*default%2Findex.do%23%2Fxskcb",
            redirectURL: "",
            targetURL: "https://newehall.nwafu.edu.cn/jwapp/sys/wdkbby/*default/index.do#/xskcb",
            preExtractJS: "",
            delayTime: 3,
            extractJS: "(() => {\n  const WEEK_MAP = { 一: 1, 二: 2, 三: 3, 四: 4, 五: 5, 六: 6, 日: 7 };\n\n  const name = document.querySelector(\"#dqxnxq2\").textContent.trim();\n  const courses = [];\n  const courseMap = new Map();\n\n  document.querySelectorAll(\".mtt_arrange_item\").forEach((item) => {\n    if (item.querySelector(\".mtt_item_tkbz\")) return;\n\n    const parentCell = item.closest(\"td[data-week]\");\n    if (!parentCell) return;\n\n    const weekDay = parseInt(parentCell.getAttribute(\"data-week\"));\n    const divs = item.querySelectorAll(\"div\");\n    if (divs.length < 3) return;\n\n    // 课程名提取\n    const courseName = divs[1].textContent\n      .replace(/^《【本】/, \"\")\n      .replace(/》\\[.*\\]$/, \"\") // 去掉》[XX]\n      .replace(/》$/, \"\")\n      .replace(/^《/, \"\")\n      .replace(/^【本】/, \"\")\n      .trim();\n\n    const infoText = divs[2].innerHTML;\n    const parts = infoText\n      .split(\"&nbsp;\")\n      .filter((p) => p && p.trim() && !p.startsWith(\"<\"));\n\n    let teacher = parts[0] ? parts[0].replace(/,$/, \"\").trim() : \"\";\n    // 去掉重复的教师姓名\n    if (teacher.includes(\",\")) {\n      const teachers = teacher.split(\",\");\n      teacher = [...new Set(teachers)].join(\",\");\n    }\n\n    let weekStr = parts[1] ? parts[1].trim() : \"\";\n    let timeStr = parts[2] ? parts[2].trim() : \"\";\n    let classroom = parts[3] ? parts[3].split(\"<\")[0].trim() : \"\";\n\n    let startTime = 0,\n      endTime = 0;\n    const timeMatch = timeStr.match(/第(\\d+)节-第(\\d+)节/);\n    if (timeMatch) {\n      startTime = parseInt(timeMatch[1]);\n      endTime = parseInt(timeMatch[2]);\n    }\n\n    // 优化周数解析\n    const weeks = [];\n    if (weekStr) {\n      weekStr.split(\",\").forEach((part) => {\n        part = part.trim();\n        const isSingle = part.includes(\"(单)\");\n        const isDouble = part.includes(\"(双)\");\n        const cleanPart = part\n          .replace(/周/g, \"\")\n          .replace(/\\(单\\)/g, \"\")\n          .replace(/\\(双\\)/g, \"\");\n\n        if (cleanPart.includes(\"-\")) {\n          const [s, e] = cleanPart.split(\"-\").map(Number);\n          if (isSingle) {\n            // 单周：从s开始，每隔一周取一次\n            for (let i = s; i <= e; i++) {\n              if (i % 2 === 1) weeks.push(i);\n            }\n          } else if (isDouble) {\n            // 双周：从s开始，每隔一周取一次\n            for (let i = s; i <= e; i++) {\n              if (i % 2 === 0) weeks.push(i);\n            }\n          } else {\n            for (let i = s; i <= e; i++) weeks.push(i);\n          }\n        } else if (cleanPart) {\n          weeks.push(Number(cleanPart));\n        }\n      });\n    }\n\n    const jxbLink = item.querySelector('a[data-action=\"查看教学班说明\"]');\n    const classNumber = jxbLink ? jxbLink.getAttribute(\"data-jxbid\") : \"\";\n\n    if (courseName && weeks.length > 0) {\n      const courseKey = `${courseName}_${teacher}_${weekDay}_${startTime}_${endTime}`;\n      if (courseMap.has(courseKey)) {\n        const existing = courseMap.get(courseKey);\n        // 合并周次并去重排序\n        existing.weeks = [...new Set([...existing.weeks, ...weeks])].sort(\n          (a, b) => a - b,\n        );\n      } else {\n        const courseData = {\n          name: courseName,\n          classroom: classroom || \"未安排教室\",\n          class_number: classNumber,\n          teacher: teacher,\n          test_time: null,\n          test_location: null,\n          link: null,\n          weeks: weeks.sort((a, b) => a - b),\n          week_time: weekDay,\n          start_time: startTime,\n          time_count: endTime - startTime,\n          import_type: 1,\n          info: null,\n          data: null,\n        };\n        courses.push(courseData);\n        courseMap.set(courseKey, courseData);\n      }\n    }\n  });\n\n  return encodeURIComponent(\n    JSON.stringify({\n      name,\n      courses,\n      note: \"西北农林科技大学课表数据\",\n      totalCourses: courses.length,\n    }),\n  );\n})();\n",
            bannerContent: "导入方式：登陆后自动获取当前学期课表\n当前为夏令时，若时间不对请重新导入课表！\n依旧为早期开发版本，如果出现问题请联系\n1852554085@qq.com",
            bannerAction: "朕知道了",
            bannerURL: nil,
            classTimeList: [
                ClassTime(start: "08:00", end: "08:45"),
                ClassTime(start: "08:55", end: "09:40"),
                ClassTime(start: "10:10", end: "10:55"),
                ClassTime(start: "11:05", end: "11:50"),
                ClassTime(start: "14:30", end: "15:15"),
                ClassTime(start: "15:25", end: "16:10"),
                ClassTime(start: "16:30", end: "17:15"),
                ClassTime(start: "17:25", end: "18:10"),
                ClassTime(start: "19:30", end: "20:15"),
                ClassTime(start: "20:20", end: "21:05"),
                ClassTime(start: "21:10", end: "21:55"),
            ],
            semesterStartMonday: "2026-09-07"
        ),
        SchoolConfig(
            title: "中国人民大学研究生教育信息系统",
            pinyin: "zhongguorenmindaxuejiaowu",
            summary: "耶！南哪课表占领世界！",
            pageTitle: "教育信息系统登录",
            initialURL: "https://yjs2.ruc.edu.cn",
            redirectURL: "https://yjs2.ruc.edu.cn/gsapp/sys/yjsemaphome/portal/index.do",
            targetURL: "https://yjs2.ruc.edu.cn/gsapp/sys/wdkbapp/*default/index.do",
            preExtractJS: "",
            delayTime: 3,
            extractJS: "function scheduleHtmlParser() {\n  // 1. 获取学期列表\n  var getTerms = function () {\n    var xhr = new XMLHttpRequest();\n    xhr.open(\n      \"POST\",\n      \"https://yjs2.ruc.edu.cn/gsapp/sys/wdkbapp/modules/xskcb/kfdxnxqcx.do\",\n      false,\n    );\n    xhr.send();\n    var data = JSON.parse(xhr.responseText);\n    var terms = data.datas.kfdxnxqcx.rows;\n    terms.sort((a, b) => a.PX - b.PX); // 早→新\n    return terms;\n  };\n\n  // 2. 获取课表\n  var getRawKb = function (termCode) {\n    var formData = new FormData();\n    formData.append(\"XNXQDM\", termCode);\n    var xhr = new XMLHttpRequest();\n    xhr.open(\n      \"POST\",\n      \"https://yjs2.ruc.edu.cn/gsapp/sys/wdkbapp/bykb/loadXskbData.do\",\n      false,\n    );\n    xhr.send(formData);\n    return JSON.parse(xhr.responseText).rwList;\n  };\n\n  // 3. 解析信息\n  function parseInfo(info) {\n    const result = [];\n    const segments = info.split(\";\");\n\n    segments.forEach((seg) => {\n      // 1-4,6-8周 星期二[3-4节]公学一楼102;3周 星期日[3-4节]公学一楼102\n      const match = seg.match(/(.+?周)\\s*星期(.+?)\\[(.+?)节\\](.*)/);\n      if (!match) return;\n\n      const [, weekPart, dayPart, timePart, classroom] = match;\n\n      // 解析周次\n      const weeks = [];\n      weekPart.split(\",\").forEach((w) => {\n        var m = w.match(/(\\d+)-?(\\d+)?(?:(单|双))?周?/);\n        if (!m) return [];\n        var start = parseInt(m[1], 10);\n        var end = parseInt(m[2], 10);\n        if (isNaN(end)) end = start;\n        var flag = { 单: 1, 双: 2 }[m[3]] || 0;\n        for (var w = start; w <= end; w++) {\n          if (\n            flag === 0 ||\n            (flag === 1 && w % 2 === 1) ||\n            (flag === 2 && w % 2 === 0)\n          )\n            weeks.push(w);\n        }\n      });\n\n      // 解析星期几\n      const dayMap = { 一: 1, 二: 2, 三: 3, 四: 4, 五: 5, 六: 6, 日: 7 };\n      const week_time = dayMap[dayPart.trim()];\n\n      // 解析节次\n      const [startStr, endStr] = timePart.split(\"-\");\n      const start_time = parseInt(startStr, 10);\n      const time_count = parseInt(endStr, 10) - start_time;\n\n      result.push({\n        classroom: classroom.trim(),\n        weeks,\n        week_time,\n        start_time,\n        time_count,\n      });\n    });\n\n    return result;\n  }\n\n  var terms = getTerms();\n  var currentTerm = terms[0];\n  currentTermCode = currentTerm.XNXQDM;\n  currentTermName = currentTerm.XNXQDM_DISPLAY;\n\n  if (!currentTermCode) {\n    return encodeURIComponent(\n      JSON.stringify({\n        name: \"无法获取学期信息\",\n        courses: [],\n      }),\n    );\n  }\n\n  // 5. 抓取并转换\n  var rows = getRawKb(currentTermCode);\n  var courses = [];\n  console.log(rows);\n  rows.forEach(function (r) {\n    // 无时间课程直接忽略\n    if (r.PKSJDD == null) return;\n    var info = parseInfo(r.PKSJDD);\n    info.forEach(function (i) {\n      courses.push({\n        name: r.KCMC,\n        classroom: i.classroom,\n        class_number: r.KCDM,\n        teacher: r.RKJS,\n        test_time: null,\n        test_location: null,\n        link: null,\n        weeks: i.weeks,\n        week_time: i.week_time,\n        start_time: i.start_time,\n        time_count: i.time_count,\n        import_type: 1,\n        info: r.XKBZ,\n        data: null,\n      });\n    });\n  });\n\n  // 返回符合南哪课表格式的数据\n  var result = {\n    name: currentTermName,\n    courses: courses,\n  };\n  // return result;\n  return encodeURIComponent(JSON.stringify(result));\n}\n\nscheduleHtmlParser();\n",
            bannerContent: "导入方式：登陆后自动获取当前学期课表\n注意：如加载失败，请连接东南大学VPN\n试试浏览器访问教务网，没准教务系统又抽风了",
            bannerAction: "使用中国人民大学VPN",
            bannerURL: "https://vpn.ruc.edu.cn",
            classTimeList: [
                ClassTime(start: "08:00", end: "08:45"),
                ClassTime(start: "08:50", end: "09:30"),
                ClassTime(start: "10:00", end: "10:45"),
                ClassTime(start: "10:46", end: "11:30"),
                ClassTime(start: "12:00", end: "12:45"),
                ClassTime(start: "12:46", end: "13:30"),
                ClassTime(start: "14:00", end: "14:45"),
                ClassTime(start: "14:46", end: "15:30"),
                ClassTime(start: "16:00", end: "16:45"),
                ClassTime(start: "16:46", end: "17:30"),
                ClassTime(start: "18:00", end: "18:45"),
                ClassTime(start: "18:46", end: "19:30"),
                ClassTime(start: "19:40", end: "20:25"),
                ClassTime(start: "20:26", end: "21:10"),
                ClassTime(start: "21:15", end: "22:00"),
            ],
            semesterStartMonday: "2026-09-07"
        ),
        SchoolConfig(
            title: "清华大学研究生信息门户",
            pinyin: "qinghuadaxueyanjiusheng",
            summary: "北伐！北伐！",
            pageTitle: "信息门户登录",
            initialURL: "https://webvpn.tsinghua.edu.cn/https/77726476706e69737468656265737421fcf2408e297e7c4377068ea48d546d30ca8cc97bcc/f/login",
            redirectURL: "https://learn.tsinghua.edu.cn/",
            targetURL: "https://webvpn.tsinghua.edu.cn/http/77726476706e69737468656265737421eaff4b8b69336153301c9aa596522b20bc86e6e559a9b290/jxmh_out.do?m=yjs_jxrl_all",
            preExtractJS: "",
            delayTime: 3,
            extractJS: "function scheduleHtmlParser() {\n  // 清华研究生课表解析器\n  // 参考 thu-info-lib 实现\n\n  const CONFIG = {\n    // 研究生课表 API 前缀\n    YJS_API_PREFIX:\n      \"https://webvpn.tsinghua.edu.cn/http/77726476706e69737468656265737421eaff4b8b69336153301c9aa596522b20bc86e6e559a9b290/jxmh_out.do?m=yjs_jxrl_all&p_start_date=\",\n    // 学期开始日期\n    DEFAULT_FIRST_DAY: \"2026-02-23\",\n    // 学期周数\n    WEEK_COUNT: 16,\n    // 分组大小（每次3周）\n    GROUP_SIZE: 3,\n  };\n\n  // 时间段映射（清华的节次时间）\n  const TIME_SLOTS = [\n    { begin: \"08:00\", end: \"08:45\" }, // 1\n    { begin: \"08:50\", end: \"09:35\" }, // 2\n    { begin: \"09:50\", end: \"10:35\" }, // 3\n    { begin: \"10:40\", end: \"11:25\" }, // 4\n    { begin: \"11:30\", end: \"12:15\" }, // 5\n    { begin: \"13:30\", end: \"14:15\" }, // 6\n    { begin: \"14:20\", end: \"15:05\" }, // 7\n    { begin: \"15:20\", end: \"16:05\" }, // 8\n    { begin: \"16:10\", end: \"16:55\" }, // 9\n    { begin: \"17:05\", end: \"17:50\" }, // 10\n    { begin: \"17:55\", end: \"18:40\" }, // 11\n    { begin: \"19:20\", end: \"20:05\" }, // 12\n    { begin: \"20:10\", end: \"20:55\" }, // 13\n    { begin: \"21:00\", end: \"21:45\" }, // 14\n  ];\n\n  // 同步 HTTP GET 请求（自动携带当前页面 cookies）\n  const httpGet = (url) => {\n    const xhr = new XMLHttpRequest();\n    xhr.open(\"GET\", url, false);\n    xhr.setRequestHeader(\"Accept\", \"application/json, text/javascript, */*\");\n    xhr.send();\n    if (xhr.status !== 200) {\n      throw new Error(`HTTP ${xhr.status}`);\n    }\n    return xhr.responseText;\n  };\n\n  // 格式化日期为 YYYYMMDD\n  const formatDate = (date) => {\n    const year = date.getFullYear();\n    const month = String(date.getMonth() + 1).padStart(2, \"0\");\n    const day = String(date.getDate()).padStart(2, \"0\");\n    return `${year}${month}${day}`;\n  };\n\n  // 从时间字符串获取节次（1-14）\n  const getPeriodFromTime = (timeStr) => {\n    if (!timeStr) return 0;\n    const [hours, minutes] = timeStr.replace(\"：\", \":\").split(\":\").map(Number);\n    const timeValue = hours * 60 + minutes;\n\n    for (let i = 0; i < TIME_SLOTS.length; i++) {\n      const [beginH, beginM] = TIME_SLOTS[i].begin.split(\":\").map(Number);\n      const [endH, endM] = TIME_SLOTS[i].end.split(\":\").map(Number);\n      const beginValue = beginH * 60 + beginM;\n      const endValue = endH * 60 + endM + 5; // 5分钟缓冲\n\n      if (timeValue >= beginValue && timeValue <= endValue) {\n        return i + 1; // 节次从1开始\n      }\n    }\n    return 0;\n  };\n\n  // 计算周次\n  const getWeekFromDate = (dateStr, firstDayStr) => {\n    const date = new Date(dateStr);\n    const firstDay = new Date(firstDayStr);\n    const diffTime = date.getTime() - firstDay.getTime();\n    const diffDays = Math.floor(diffTime / (1000 * 60 * 60 * 24));\n    return Math.floor(diffDays / 7) + 1;\n  };\n\n  // 获取星期几（1-7，周一=1）\n  const getDayOfWeek = (dateStr) => {\n    const date = new Date(dateStr);\n    const day = date.getDay();\n    return day === 0 ? 7 : day;\n  };\n\n  // 解析 JSONP 响应\n  const parseJSONP = (response) => {\n    // 清华格式: m([...])\n    const match = response.match(/m\\s*\\(\\s*(\\[.*?\\])\\s*\\)/s);\n    if (match && match[1]) {\n      return JSON.parse(match[1]);\n    }\n    // 尝试直接解析 JSON\n    if (response.trim().startsWith(\"[\")) {\n      return JSON.parse(response);\n    }\n    throw new Error(\"无法解析响应格式\");\n  };\n\n  // 解析课程数据\n  const parseSchedule = (jsonData, firstDay) => {\n    const courseMap = new Map();\n\n    jsonData.forEach((item) => {\n      try {\n        const name = item.nr; // 课程名称\n        const location = item.dd || \"\"; // 地点\n        const dateStr = item.nq; // 日期 YYYY-MM-DD\n        const beginTime = item.kssj?.replace(\"：\", \":\"); // 开始时间\n        const endTime = item.jssj?.replace(\"：\", \":\"); // 结束时间\n        const category = item.fl || \"\"; // 分类\n\n        if (!name || !dateStr || !beginTime || !endTime) {\n          return;\n        }\n\n        const week = getWeekFromDate(dateStr, firstDay);\n        const dayOfWeek = getDayOfWeek(dateStr);\n        const startPeriod = getPeriodFromTime(beginTime);\n        const endPeriod = getPeriodFromTime(endTime);\n\n        if (startPeriod === 0 || endPeriod === 0) {\n          return;\n        }\n\n        // 键包含课程名称、地点、星期和节次信息，确保同名同地点但不同时间的课程被分别录入\n        const key = `${name}@${location}@周${dayOfWeek}@第${startPeriod}-${endPeriod}节`;\n\n        if (!courseMap.has(key)) {\n          courseMap.set(key, {\n            name: name,\n            classroom: location,\n            class_number: \"\",\n            teacher: \"\",\n            test_time: null,\n            test_location: null,\n            link: null,\n            weeks: [],\n            week_time: dayOfWeek,\n            start_time: startPeriod,\n            time_count: endPeriod - startPeriod,\n            import_type: 1,\n            info: category,\n            data: null,\n          });\n        }\n\n        const course = courseMap.get(key);\n        if (!course.weeks.includes(week)) {\n          course.weeks.push(week);\n        }\n      } catch (e) {\n        // 跳过解析失败的条目\n      }\n    });\n\n    // 转换为数组并排序周次\n    const courses = [];\n    courseMap.forEach((course) => {\n      course.weeks.sort((a, b) => a - b);\n      courses.push(course);\n    });\n\n    return courses;\n  };\n\n  // 获取课表数据\n  const fetchSchedule = () => {\n    const firstDay = new Date(CONFIG.DEFAULT_FIRST_DAY);\n    const allData = [];\n\n    // 分批次获取（每次3周）\n    const groupCount = Math.ceil(CONFIG.WEEK_COUNT / CONFIG.GROUP_SIZE);\n\n    for (let i = 0; i < groupCount; i++) {\n      try {\n        const startWeek = i * CONFIG.GROUP_SIZE + 1;\n        const endWeek = Math.min(\n          (i + 1) * CONFIG.GROUP_SIZE,\n          CONFIG.WEEK_COUNT,\n        );\n\n        const startDate = new Date(firstDay);\n        startDate.setDate(startDate.getDate() + (startWeek - 1) * 7);\n\n        const endDate = new Date(firstDay);\n        endDate.setDate(endDate.getDate() + (endWeek - 1) * 7 + 6);\n\n        const url = `${CONFIG.YJS_API_PREFIX}${formatDate(startDate)}&p_end_date=${formatDate(endDate)}&jsoncallback=m`;\n\n        const response = httpGet(url);\n\n        // 检查是否是HTML（未登录）\n        if (response.trim().startsWith(\"<\")) {\n          throw new Error(\"返回HTML页面，可能未登录\");\n        }\n\n        const data = parseJSONP(response);\n        if (Array.isArray(data) && data.length > 0) {\n          allData.push(...data);\n        }\n      } catch (e) {\n        // 继续下一批\n      }\n    }\n\n    return parseSchedule(allData, CONFIG.DEFAULT_FIRST_DAY);\n  };\n\n  // 获取当前学期名称（基于开学日期）\n  const getSemesterName = (firstDayStr) => {\n    const date = new Date(firstDayStr);\n    const year = date.getFullYear();\n    const month = date.getMonth() + 1; // 1-12\n    // 2-7月为春季学期（属上一学年的第二学期），8-1月为秋季学期（属上一学年的第一学期）\n    if (month >= 2 && month <= 7) {\n      return `${year - 1}-${year}学年 春季学期`;\n    } else {\n      return `${year}-${year + 1}学年 秋季学期`;\n    }\n  };\n\n  // 主流程\n  try {\n    const courses = fetchSchedule();\n    const semesterName = getSemesterName(CONFIG.DEFAULT_FIRST_DAY);\n\n    const result = {\n      name: `清华大学研究生课表 ${semesterName}`,\n      courses: courses,\n    };\n\n    // return result;\n    return encodeURIComponent(JSON.stringify(result));\n  } catch (error) {\n    return encodeURIComponent(\n      JSON.stringify({\n        name: \"清华大学研究生课表\",\n        courses: [],\n        error: error.message,\n      }),\n    );\n  }\n}\n\nscheduleHtmlParser();\n",
            bannerContent: "导入方式：登录后自动获取本学期课表\n由于我校VPN设置，需要先登录VPN再登录网络学堂\n另外友情推荐 THU Info APP",
            bannerAction: "前往 THU Info APP",
            bannerURL: "https://app.cs.tsinghua.edu.cn",
            classTimeList: [
                ClassTime(start: "08:00", end: "08:45"),
                ClassTime(start: "08:50", end: "09:35"),
                ClassTime(start: "09:50", end: "10:35"),
                ClassTime(start: "10:40", end: "11:25"),
                ClassTime(start: "11:30", end: "12:15"),
                ClassTime(start: "13:30", end: "14:15"),
                ClassTime(start: "14:20", end: "15:05"),
                ClassTime(start: "15:20", end: "16:05"),
                ClassTime(start: "16:10", end: "16:55"),
                ClassTime(start: "17:05", end: "17:50"),
                ClassTime(start: "17:55", end: "18:40"),
                ClassTime(start: "19:20", end: "20:05"),
                ClassTime(start: "20:10", end: "20:55"),
                ClassTime(start: "21:00", end: "21:45"),
            ],
            semesterStartMonday: "2026-09-14"
        ),
        SchoolConfig(
            title: "中国科学院大学研究生课表",
            pinyin: "zhongguokexueyuandaxueyanjiushengkebiao",
            summary: "国科大在线个人课表导入",
            pageTitle: "国科大研究生课表",
            initialURL: "https://sep.ucas.ac.cn/d_index/Z2tkenhfbG9jYWw=/",
            redirectURL: "http://mooc.ucas.edu.cn/portal",
            targetURL: "https://kb.mooc.ucas.edu.cn/res/pc/curriculum/schedule.html",
            preExtractJS: "",
            delayTime: 3,
            extractJS: "// 中国科学院大学（UCAS / 国科大）研究生课表提取脚本\n// 数据源：国科大在线（超星平台）个人课表\n//   页面：https://kb.mooc.ucas.edu.cn/res/pc/curriculum/schedule.html\n//   接口：同源 /pc/curriculum/getMyLessons?week=<周>\n// 该接口为页面自身加载课表所用的同源 JSON 接口（登录后可访问），按周返回该周\n// 实际上课的课程，每节课含 weeks(上课周次)/dayOfWeek(星期)/beginNumber(起始节)/\n// length(持续节数)/location(教室)/teacherName(教师)/name(课程名)/courseNo(课程编号)。\n// 其中 weeks 字段是该课程段准确的上课周次（能体现单双周、分段、调课等变化）。\n//\n// 脚本逐周（1..maxWeek）以同步 XHR 拉取并按 lessonConfigUuid 去重合并，得到\n// 全学期所有课程段，再转换为南哪课表标准 JSON，返回 encodeURIComponent 结果。\n\nfunction scheduleHtmlParser() {\n  // 同步 GET JSON\n  function getJSON(url) {\n    const xhr = new XMLHttpRequest();\n    xhr.open(\"GET\", url, false);\n    try {\n      xhr.setRequestHeader(\"X-Requested-With\", \"XMLHttpRequest\");\n    } catch (e) {}\n    xhr.send(null);\n    if (xhr.status !== 200 || !xhr.responseText) {\n      throw new Error(\"HTTP \" + xhr.status + \" for \" + url);\n    }\n    return JSON.parse(xhr.responseText);\n  }\n\n  // 周次文本 \"2,3,4,5,7-11\" / \"2、3、4\" / \"1-16单\" / \"2-18双\" → 周次数组（1 起始）\n  function parseWeeks(text) {\n    const weeks = [];\n    if (!text) return weeks;\n    const norm = String(text)\n      .replace(/，/g, \",\")\n      .replace(/、/g, \",\")\n      .replace(/\\s/g, \"\");\n    const parts = norm.split(\",\");\n    for (let p = 0; p < parts.length; p++) {\n      const part = parts[p];\n      if (!part) continue;\n      const isSingle = /单/.test(part);\n      const isDouble = /双/.test(part);\n      const clean = part.replace(/[周单双()（）]/g, \"\");\n      if (clean.indexOf(\"-\") > -1 || clean.indexOf(\"~\") > -1) {\n        const range = clean.split(/[-~]/);\n        const start = parseInt(range[0], 10);\n        const end = parseInt(range[1], 10);\n        if (isNaN(start) || isNaN(end)) continue;\n        const step = isSingle || isDouble ? 2 : 1;\n        let cur = start;\n        if (isSingle && start % 2 === 0) cur = start + 1;\n        if (isDouble && start % 2 === 1) cur = start + 1;\n        for (let i = cur; i <= end; i += step) weeks.push(i);\n      } else {\n        const n = parseInt(clean, 10);\n        if (!isNaN(n)) weeks.push(n);\n      }\n    }\n    // 去重并升序（用普通对象，避免页面旧 polyfill 占用原生 Set/Map）\n    const seen = {};\n    const uniq = [];\n    for (let i = 0; i < weeks.length; i++) {\n      const w = weeks[i];\n      if (!seen[w]) {\n        seen[w] = 1;\n        uniq.push(w);\n      }\n    }\n    return uniq.sort((a, b) => a - b);\n  }\n\n  function termName(cur) {\n    if (!cur) return \"国科大课表\";\n    // semester: 1=第一学期(秋)，2=第二学期(春)\n    const year = String(cur.schoolYear || \"\");\n    const sem = Number(cur.semester);\n    let suffix = \"\";\n    if (sem === 1) suffix = \"学年(秋)第一学期\";\n    else if (sem === 2) suffix = \"学年(春)第二学期\";\n    if (year && suffix) {\n      const next = (Number(year) + 1).toString();\n      return \"中国科学院大学 \" + year + \"—\" + next + suffix;\n    }\n    return \"中国科学院大学研究生课表\";\n  }\n\n  function run() {\n    // 先取一次拿到学期配置（maxWeek / 学期名）\n    const firstUrl =\n      \"/pc/curriculum/getMyLessons?curTime=\" + new Date().getTime() + \"&week=1\";\n    const first = getJSON(firstUrl);\n    if (!first || first.result !== 1 || !first.data) {\n      // 未登录或会话失效：直接抛错，App 会上报错误页\n      throw new Error(\"getMyLessons 未返回有效数据（可能未登录）：\" +\n        (first && first.msg ? first.msg : \"unknown\"));\n    }\n    const curriculum = first.data.curriculum || {};\n    const maxWeek = Number(curriculum.maxWeek) || 20;\n\n    // 逐周拉取并按 lessonConfigUuid 去重合并\n    // 用普通对象而非 Map/Set：课表页是老平台页面，可能有 IE 时代 polyfill\n    // 占用原生 Map/Set，导致 forEach 等方法不存在。\n    const seen = {};\n    const merged = [];\n    for (let w = 1; w <= maxWeek; w++) {\n      try {\n        const url =\n          \"/pc/curriculum/getMyLessons?curTime=\" +\n          new Date().getTime() +\n          \"&week=\" +\n          w;\n        const rsp = getJSON(url);\n        if (!rsp || rsp.result !== 1 || !rsp.data) continue;\n        const arr = rsp.data.lessonArray || [];\n        for (let i = 0; i < arr.length; i++) {\n          const L = arr[i];\n          // 同一课程段用 lessonConfigUuid 去重；缺失时用 名称+星期+节次+教室 兜底\n          const key =\n            L.lessonConfigUuid ||\n            [L.name, L.dayOfWeek, L.beginNumber, L.length, L.location].join(\"|\");\n          if (!seen[key]) {\n            seen[key] = 1;\n            merged.push(L);\n          }\n        }\n      } catch (e) {\n        // 单周失败不影响其它周\n      }\n    }\n\n    const result = { name: termName(curriculum), courses: [] };\n\n    for (let idx = 0; idx < merged.length; idx++) {\n      const L = merged[idx];\n      const weeks = parseWeeks(L.weeks);\n      if (weeks.length === 0) continue; // 无有效周次（如免修免考/全天占位）跳过\n      const dayOfWeek = parseInt(L.dayOfWeek, 10);\n      const beginNumber = parseInt(L.beginNumber, 10);\n      const length = parseInt(L.length, 10) || 1;\n      if (!dayOfWeek || !beginNumber) continue;\n\n      const room = (L.location || \"\").trim();\n      const online = (L.onlineLocation || \"\").trim();\n      const classroom = room || online || \"待定\";\n\n      result.courses.push({\n        name: L.name || L.displayCourseName || \"\",\n        classroom: classroom,\n        class_number: L.courseNo || L.classNo || \"\",\n        teacher: L.teacherName || \"\",\n        test_time: null,\n        test_location: null,\n        link: \"https://kb.mooc.ucas.edu.cn/res/pc/curriculum/schedule.html\",\n        weeks: weeks,\n        week_time: dayOfWeek,                 // 周一=1 ... 周日=7\n        start_time: beginNumber,             // 起始节（1 起始）\n        time_count: length - 1,              // 持续节数 = 末节 - 首节\n        import_type: 1,\n        info: L.englishCourseName || null,\n        data: null,\n      });\n    }\n\n    return result;\n  }\n\n  const result = run();\n  return encodeURIComponent(JSON.stringify(result));\n}\n\nscheduleHtmlParser();\n",
            bannerContent: "导入方式：登录 SEP 后将自动跳转国科大在线个人课表\n登录后请耐心等待，脚本会自动读取本学期所有周次的课程\n仅研究生账号实测通过，本科生路径未验证",
            bannerAction: "前往国科大 SEP",
            bannerURL: "https://sep.ucas.ac.cn",
            classTimeList: [
                ClassTime(start: "08:30", end: "09:15"),
                ClassTime(start: "09:20", end: "10:05"),
                ClassTime(start: "10:25", end: "11:10"),
                ClassTime(start: "11:15", end: "12:00"),
                ClassTime(start: "13:30", end: "14:15"),
                ClassTime(start: "14:20", end: "15:05"),
                ClassTime(start: "15:25", end: "16:10"),
                ClassTime(start: "16:15", end: "17:00"),
                ClassTime(start: "17:05", end: "17:50"),
                ClassTime(start: "18:30", end: "19:15"),
                ClassTime(start: "19:20", end: "20:05"),
                ClassTime(start: "20:15", end: "21:00"),
                ClassTime(start: "21:05", end: "21:50"),
            ],
            semesterStartMonday: "2026-08-31"
        ),
    ]
}
