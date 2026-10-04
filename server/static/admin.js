(() => {
  const state = {
    authenticated: false, schools: [], school: null, term: null, apns: null,
    calendar: { version: 1, adjustments: [] }, stats: { totalUsers: 0, schools: [] }, view: "schools"
  };
  const $ = id => document.getElementById(id);
  const escapeHTML = value => String(value ?? "").replace(/[&<>"']/g, char => ({ "&": "&amp;", "<": "&lt;", ">": "&gt;", "\"": "&quot;", "'": "&#39;" })[char]);
  const escapeAttr = escapeHTML;
  const today = new Date();
  $("consoleDate").textContent = new Intl.DateTimeFormat("zh-CN", { year: "numeric", month: "long", day: "numeric", weekday: "short" }).format(today);
  $("calendarAcademicYear").value = today.getFullYear() - (today.getMonth() < 8 ? 1 : 0);
  let noticeTimer;

  const notice = (message, kind = "") => {
    const element = $("notice");
    clearTimeout(noticeTimer);
    element.textContent = message || "";
    element.className = `notice ${kind}`;
    if (message) noticeTimer = setTimeout(() => { element.textContent = ""; }, 4500);
  };
  const setLoading = (button, loading) => {
    button.disabled = loading;
    button.classList.toggle("loading", loading);
    button.setAttribute("aria-busy", String(loading));
  };
  const request = async (path, options = {}) => {
    const headers = { "Content-Type": "application/json", ...(options.headers || {}) };
    const response = await fetch(path, { credentials: "same-origin", ...options, headers });
    const data = await response.json().catch(() => ({}));
    if (!response.ok) throw Object.assign(new Error(data.error || `HTTP ${response.status}`), { status: response.status, data });
    return data;
  };

  const updateMetrics = () => {
    $("schoolCount").textContent = state.schools.length;
    $("schoolListCount").textContent = state.schools.length;
    $("termCount").textContent = state.schools.reduce((sum, school) => sum + (school.terms?.length || 0), 0);
    $("periodCount").textContent = state.schools.reduce((sum, school) => sum + (school.periods?.length || 0), 0);
    // Clients follow each school's current term: one that does not cover today is usually a term to roll over.
    const today = new Intl.DateTimeFormat("en-CA", { timeZone: "Asia/Shanghai" }).format(new Date());
    const covers = term => {
      if (!term?.semesterStartMonday) return false;
      const end = new Date(Date.parse(`${term.semesterStartMonday}T00:00:00Z`) + term.weekCount * 7 * 86400000).toISOString().slice(0, 10);
      return term.semesterStartMonday <= today && today < end;
    };
    const outside = state.schools.filter(school => !covers((school.terms || []).find(term => term.current)));
    $("activeTermCount").textContent = state.schools.length - outside.length;
    $("activeTermDetail").textContent = !state.schools.length ? "尚未配置学校"
      : outside.length ? `${outside.map(school => school.name).slice(0, 3).join("、")}${outside.length > 3 ? ` 等 ${outside.length} 所` : ""}的当前学期不含今天`
      : "所有学校的当前学期都覆盖今天";
    $("activeTermCard").classList.toggle("needs-attention", outside.length > 0);
  };
  const updateConnectionUI = connected => {
    $("authView").hidden = connected;
    $("connectionStatus").classList.toggle("connected", connected);
    $("connectionStatus").innerHTML = `<span></span>${connected ? "已连接" : "未连接"}`;
    $("sessionIndicator").classList.toggle("connected", connected);
    $("sidebarSessionText").textContent = connected ? (state.admin ? `${state.admin} · 已连接` : "已安全连接") : "尚未连接";
    $("disconnectButton").hidden = !connected;
    document.querySelectorAll(".nav-item").forEach(item => { item.disabled = !connected; });
    if (connected) showView(state.view);
    else {
      setNavigation(false);
      document.querySelectorAll(".content-view").forEach(view => { view.hidden = true; });
      $("pageTitle").textContent = "管理工作区";
      $("breadcrumbCurrent").textContent = "登录";
      $("pageSubtitle").textContent = "一处管理，让校园时间保持同步。";
    }
  };
  const viewCopy = {
    schools: ["学校配置", "维护学校节次与当前学期的第一周配置。"],
    calendar: ["统一调休", "维护对所有学校生效的调休安排。"],
    stats: ["使用统计", "查看今日打开、近 7/30 天活跃设备，以及各学校、系统版本、设备型号和 App 版本分布。"],
    shares: ["分享课表", "查找用户分享到服务端的课表，删除不该公开的分享。"],
    entitlements: ["实时活动权益", "设置实时活动是否需要试用或买断权益，查看授权设备数。"],
    apns: ["APNs 推送", "配置实况通知的推送凭据。"],
    imageImport: ["图片导入", "配置 AI 课表识别、设备验证和使用额度，查看调用结果与 token 用量。"],
    audit: ["操作记录", "谁在什么时候改了什么。"]
  };
  const mobileNavigation = window.matchMedia("(max-width: 760px)");
  const setNavigation = open => {
    document.body.classList.toggle("nav-open", open);
    $("menuButton").setAttribute("aria-expanded", String(open));
    $("sidebar").inert = mobileNavigation.matches && !open;
    document.querySelector(".main-content").inert = mobileNavigation.matches && open;
  };
  mobileNavigation.addEventListener("change", () => setNavigation(false));
  const showView = view => {
    if (!viewCopy[view]) return;
    state.view = view;
    document.querySelectorAll(".nav-item").forEach(item => {
      item.classList.toggle("active", item.dataset.view === view);
      if (item.dataset.view === view) item.setAttribute("aria-current", "page");
      else item.removeAttribute("aria-current");
    });
    document.querySelectorAll(".content-view").forEach(element => {
      element.hidden = !state.authenticated || element.id !== `${view}View`;
    });
    $("pageTitle").textContent = viewCopy[view][0];
    $("breadcrumbCurrent").textContent = viewCopy[view][0];
    $("pageSubtitle").textContent = viewCopy[view][1];
    if (view === "audit" && state.authenticated) loadAudit().catch(error => notice(error.message, "error"));
    const wasOpen = document.body.classList.contains("nav-open");
    setNavigation(false);
    if (wasOpen) $("menuButton").focus();
  };
  const addMinutes = (time, minutes) => {
    const [hours, mins] = String(time || "00:00").split(":").map(Number);
    const total = Math.min((hours * 60) + mins + minutes, (24 * 60) - 1);
    return `${String(Math.floor(total / 60)).padStart(2, "0")}:${String(total % 60).padStart(2, "0")}`;
  };

  // What each form looked like when it was last loaded or saved; a form that
  // differs has edits a switch or a reload would silently throw away.
  const forms = {
    school: () => state.school ? JSON.stringify({ name: $("schoolName").value.trim(), note: $("schoolNote").value.trim(), periods: periodRows(), seasonalPeriods: activeSeasonRows(), seasonalPeriodsEnabled: $("schoolSeasonEnabled").checked, unifiedHolidaysEnabled: $("schoolUnifiedHolidaysEnabled").checked, unifiedMakeupEnabled: $("schoolUnifiedMakeupEnabled").checked }) : "",
    term: () => state.term ? JSON.stringify(formTerm()) : "",
    calendar: () => JSON.stringify(adjustmentRows()),
    apns: () => JSON.stringify(formApns()),
    imageImport: () => JSON.stringify(formImageImport())
  };
  const formNames = { school: "学校信息", term: "学期", calendar: "统一调休", apns: "APNs 配置", imageImport: "图片导入配置" };
  const savedForms = {};
  const markClean = (...keys) => keys.forEach(key => { savedForms[key] = forms[key](); });
  // A form with nothing loaded ("") has nothing to lose.
  const unsaved = (keys = Object.keys(forms)) => keys.filter(key => key in savedForms && forms[key]() !== "" && savedForms[key] !== forms[key]());
  const confirmDiscard = keys => {
    const changed = unsaved(keys);
    return !changed.length || confirm(`${changed.map(key => formNames[key]).join("、")}有未保存的修改，确定放弃吗？`);
  };

  const renderSchools = () => {
    const list = $("schoolList");
    const query = $("schoolSearch").value.trim().toLowerCase();
    const schools = state.schools.filter(school => `${school.name} ${school.id}`.toLowerCase().includes(query));
    list.replaceChildren();
    if (!schools.length) {
      const empty = document.createElement("div");
      empty.className = "list-empty";
      empty.textContent = query ? "没有匹配的学校" : "尚未配置学校";
      list.append(empty);
      return;
    }
    schools.forEach(school => {
      const button = document.createElement("button");
      button.type = "button";
      button.className = `school-item ${state.school?.id === school.id ? "active" : ""}`;
      button.setAttribute("aria-pressed", String(state.school?.id === school.id));
      button.innerHTML = `<span class="school-avatar">${escapeHTML(school.name.slice(0, 1) || school.id.slice(0, 1))}</span><span><strong>${escapeHTML(school.name)}</strong><small>${escapeHTML(school.id)} · ${(school.terms || []).length} 个学期</small></span><svg aria-hidden="true" viewBox="0 0 24 24"><path d="m9 18 6-6-6-6"/></svg>`;
      button.onclick = () => { if (school.id !== state.school?.id && confirmDiscard(["school", "term"])) selectSchool(school.id); };
      list.append(button);
    });
  };
  const renderTerms = () => {
    const list = $("termList");
    const terms = state.school?.terms || [];
    list.replaceChildren();
    $("termListSummary").textContent = `${terms.length} 个已保存学期`;
    terms.forEach(term => {
      const button = document.createElement("button");
      button.type = "button";
      button.role = "tab";
      button.setAttribute("aria-selected", String(state.term?.id === term.id));
      button.className = `term-item ${state.term?.id === term.id ? "active" : ""}`;
      button.innerHTML = `<strong>${escapeHTML(term.id)}${term.current ? '<span class="current-mark">当前</span>' : ""}</strong><small>v${term.version} · ${term.weekCount} 周</small>`;
      button.onclick = () => { if (term.id !== state.term?.id && confirmDiscard(["term"])) selectTerm(term.id); };
      list.append(button);
    });
  };
  const periodRows = (list = $("schoolPeriodList")) => [...list.querySelectorAll(".period-row")].map((row, index) => ({
    id: index + 1, name: `第${index + 1}节`,
    start: row.querySelector('[data-field="start"]').value,
    end: row.querySelector('[data-field="end"]').value
  }));
  const seasonRows = () => [...$("schoolSeasonList").querySelectorAll(".season-schedule")].map(section => ({
    from: section.querySelector('[data-field="from"]').value.trim(),
    periods: periodRows(section).map(({ start, end }) => ({ start, end }))
  }));
  const activeSeasonRows = () => $("schoolSeasonEnabled").checked ? seasonRows() : [];
  const updateSeasonEditor = () => {
    const enabled = $("schoolSeasonEnabled").checked;
    $("schoolSeasonEditor").hidden = !enabled;
    $("schoolSeasonEditor").disabled = !enabled;
    $("schoolSeasonHint").textContent = enabled
      ? "按每年生效月日自动切换作息；保存学校配置后生效。"
      : "全年使用上方节次时间；保存后清空分季配置。保存前重新打开可恢复本次编辑。";
  };
  const renderSeasons = () => {
    const list = $("schoolSeasonList");
    list.replaceChildren();
    (state.school?.seasonalPeriods || []).forEach((season, index) => {
      const section = document.createElement("section");
      section.className = "season-schedule";
      const title = season.from === "05-01" ? "夏、秋季作息" : season.from === "10-01" ? "冬、春季作息" : "分季作息";
      section.innerHTML = `<div class="editor-section-heading"><label>${title} · 每年生效月日<input data-field="from" value="${escapeAttr(season.from)}" placeholder="05-01" pattern="[0-9]{2}-[0-9]{2}" maxlength="5" aria-label="生效月日（月-日）"></label><button class="button text-button remove-season" type="button">删除这套作息</button></div><div class="period-list"></div>`;
      const rows = section.querySelector(".period-list");
      season.periods.forEach((period, number) => {
        const row = document.createElement("div");
        row.className = "period-row";
        row.innerHTML = `<div class="period-number">第 ${number + 1} 节</div><label><span>开始时间</span><input data-field="start" value="${escapeAttr(period.start)}" type="time" aria-label="${title}第${number + 1}节开始时间"></label><label><span>结束时间</span><input data-field="end" value="${escapeAttr(period.end)}" type="time" aria-label="${title}第${number + 1}节结束时间"></label>`;
        rows.append(row);
      });
      section.querySelector(".remove-season").onclick = () => {
        state.school.seasonalPeriods = seasonRows();
        state.school.seasonalPeriods.splice(index, 1);
        renderSeasons();
      };
      list.append(section);
    });
    $("addSeasonButton").disabled = (state.school?.seasonalPeriods || []).length >= 4;
  };
  const renderSchoolPeriods = () => {
    const list = $("schoolPeriodList");
    list.replaceChildren();
    (state.school?.periods || []).forEach((period, index) => {
      const row = document.createElement("div");
      row.className = "period-row";
      row.innerHTML = `<div class="period-number">第 ${index + 1} 节</div><label><span>开始时间</span><input data-field="start" value="${escapeAttr(period.start)}" type="time" aria-label="第${index + 1}节开始时间"></label><label><span>结束时间</span><input data-field="end" value="${escapeAttr(period.end)}" type="time" aria-label="第${index + 1}节结束时间"></label><button class="remove-button" type="button" aria-label="删除第${index + 1}节" title="删除节次"><svg aria-hidden="true" viewBox="0 0 24 24"><path d="M3 6h18M8 6V4h8v2M19 6l-1 14H6L5 6M10 11v5M14 11v5"/></svg></button>`;
      row.querySelector(".remove-button").onclick = () => {
        state.school.periods = periodRows();
        state.school.seasonalPeriods = seasonRows();
        state.school.periods.splice(index, 1);
        state.school.seasonalPeriods.forEach(season => season.periods.splice(index, 1));
        renderSchoolPeriods(); renderSeasons();
      };
      list.append(row);
    });
  };
  const fillSchool = ({ keepTerm = false } = {}) => {
    $("editorTitle").textContent = state.school.name;
    $("editorEyebrow").textContent = state.school.id;
    $("schoolId").value = state.school.id;
    $("renameSchoolButton").disabled = true;
    $("schoolName").value = state.school.name;
    $("schoolNote").value = state.school.note || "";
    $("schoolUnifiedHolidaysEnabled").checked = state.school.unifiedHolidaysEnabled !== false;
    $("schoolUnifiedMakeupEnabled").checked = state.school.unifiedMakeupEnabled !== false;
    $("schoolSeasonEnabled").checked = Boolean(state.school.seasonalPeriods?.length);
    updateSeasonEditor();
    $("newTermButton").disabled = false;
    $("editorEmpty").hidden = true;
    $("editor").hidden = false;
    renderSchools(); renderSchoolPeriods(); renderSeasons(); markClean("school"); renderTerms();
    if (!keepTerm) fillTerm();
  };
  const emptyTerm = () => ({
    id: "", version: 0, semesterStartMonday: "", weekCount: 18,
    timezone: "Asia/Shanghai", note: "", current: !(state.school?.terms || []).some(term => term.current)
  });
  const fillTerm = () => {
    const term = state.term;
    $("termTitle").textContent = term?.id || "新学期";
    $("termVersion").textContent = term?.version ? `已保存 v${term.version}` : "待保存";
    $("termVersion").classList.toggle("configured", Boolean(term?.version));
    $("termId").value = term?.id || "";
    $("termTimezone").value = term?.timezone || "Asia/Shanghai";
    $("termStart").value = term?.semesterStartMonday || "";
    $("termWeeks").value = term?.weekCount || 18;
    $("termCurrent").checked = Boolean(term?.current);
    $("termNote").value = term?.note || "";
    $("deleteTermButton").disabled = !term?.version || Boolean(term.current);
    $("deleteTermButton").title = !term?.version ? "学期尚未保存" : term.current ? "当前学期不能删除，请先把另一个学期设为当前" : "删除这个学期";
    markClean("term");
  };
  const selectSchool = id => {
    // A copy: unsaved period edits must not leak into the catalogue list.
    state.school = structuredClone(state.schools.find(school => school.id === id));
    const current = state.school?.terms?.find(term => term.current) || state.school?.terms?.[0];
    state.term = current ? structuredClone(current) : emptyTerm();
    fillSchool();
  };
  const selectTerm = id => {
    const term = state.school.terms.find(item => item.id === id);
    state.term = term ? structuredClone(term) : emptyTerm();
    renderTerms(); fillTerm();
  };
  const validatePeriods = periods => {
    if (!periods.length) throw new Error("学校至少需要一个节次");
    let previous = "";
    periods.forEach((period, index) => {
      if (!period.start || !period.end || period.start >= period.end) throw new Error(`第${index + 1}节时间无效`);
      if (previous && period.start < previous) throw new Error("节次必须按时间顺序且不能重叠");
      previous = period.end;
    });
  };
  const formTerm = () => ({
    id: $("termId").value.trim(), semesterStartMonday: $("termStart").value,
    weekCount: Number($("termWeeks").value), timezone: $("termTimezone").value,
    current: $("termCurrent").checked, note: $("termNote").value.trim()
  });
  const validateTerm = term => {
    if (!/^[a-zA-Z0-9][a-zA-Z0-9._-]{1,79}$/.test(term.id)) throw new Error("学期 ID 需为 2-80 位字母、数字、点、下划线或短横线");
    if (!/^\d{4}-\d{2}-\d{2}$/.test(term.semesterStartMonday)) throw new Error("第一周日期必须是 YYYY-MM-DD");
    const date = new Date(`${term.semesterStartMonday}T00:00:00Z`);
    if (Number.isNaN(date.valueOf()) || date.toISOString().slice(0, 10) !== term.semesterStartMonday || date.getUTCDay() !== 1) throw new Error("第一周日期必须是有效的周一");
    if (!Number.isInteger(term.weekCount) || term.weekCount < 1 || term.weekCount > 40) throw new Error("总周数必须是 1-40 的整数");
    if (term.timezone !== "Asia/Shanghai") throw new Error("当前服务只支持 Asia/Shanghai");
  };

  const adjustmentRows = () => [...$("globalAdjustmentList").querySelectorAll(".adjustment-row")].map(row => {
    const kind = row.querySelector('[data-field="kind"]').value;
    const value = { date: row.querySelector('[data-field="date"]').value, kind, note: row.querySelector('[data-field="note"]').value.trim() };
    if (kind === "swap") value.source = row.querySelector('[data-field="source"]')?.value || "";
    return value;
  });
  // 表单行里没有“常见选择”，从 DOM 重建时按日期把原来的候选日期带回来，否则别的行的提示会消失。
  const adjustmentRowsWithCandidates = () => {
    const candidates = new Map((state.calendar.adjustments || [])
      .filter(item => item.candidates?.length).map(item => [item.date, item.candidates]));
    return adjustmentRows().map(item => candidates.has(item.date) ? { ...item, candidates: candidates.get(item.date) } : item);
  };
  const candidateChips = (item, swap) => {
    if (!swap || item.source || !item.candidates?.length) return "";
    const chips = item.candidates
      .map(date => `<button type="button" class="candidate-chip" data-date="${escapeAttr(date)}">${escapeAttr(date.slice(5))}</button>`)
      .join("");
    return `<span class="candidate-hint">上哪天的课由学校通知决定，常见选择：${chips}</span>`;
  };
  const renderCalendar = () => {
    $("calendarVersion").textContent = `v${state.calendar.version || 1}`;
    const list = $("globalAdjustmentList");
    list.replaceChildren();
    (state.calendar.adjustments || []).forEach((item, index) => {
      const row = document.createElement("div");
      const swap = item.kind === "swap";
      row.className = `adjustment-row ${swap ? "is-swap" : "is-off"}`;
      row.innerHTML = `<label>日期<input data-field="date" type="date" value="${escapeAttr(item.date || "")}"></label><label>类型<select data-field="kind"><option value="off"${swap ? "" : " selected"}>放假</option><option value="swap"${swap ? " selected" : ""}>调课</option></select></label>${swap ? `<label>上哪天的课<input data-field="source" type="date" value="${escapeAttr(item.source || "")}"></label>` : ""}<label class="adjustment-note">说明<input data-field="note" maxlength="80" placeholder="例如 国庆节" value="${escapeAttr(item.note || "")}"></label><button class="remove-button" type="button" aria-label="删除这条调休" title="删除调休"><svg aria-hidden="true" viewBox="0 0 24 24"><path d="M3 6h18M8 6V4h8v2M19 6l-1 14H6L5 6M10 11v5M14 11v5"/></svg></button>`;
      row.insertAdjacentHTML("beforeend", candidateChips(item, swap));
      if (swap && !item.source) row.classList.add("needs-source");
      row.querySelectorAll(".candidate-chip").forEach(chip => {
        chip.onclick = () => {
          row.querySelector('[data-field="source"]').value = chip.dataset.date;
          state.calendar.adjustments = adjustmentRowsWithCandidates();
          renderCalendar();
        };
      });
      row.querySelector('[data-field="kind"]').onchange = () => { state.calendar.adjustments = adjustmentRowsWithCandidates(); renderCalendar(); };
      row.querySelector(".remove-button").onclick = () => {
        state.calendar.adjustments = adjustmentRowsWithCandidates();
        state.calendar.adjustments.splice(index, 1);
        renderCalendar();
      };
      list.append(row);
    });
    $("globalAdjustmentEmpty").hidden = Boolean(state.calendar.adjustments?.length);
  };
  const validISODate = value => {
    if (!/^\d{4}-\d{2}-\d{2}$/.test(value)) return false;
    const date = new Date(`${value}T00:00:00Z`);
    return !Number.isNaN(date.valueOf()) && date.toISOString().slice(0, 10) === value;
  };
  const validateAdjustments = adjustments => {
    const seen = new Set();
    adjustments.forEach(item => {
      if (!validISODate(item.date)) throw new Error("调休日期必须是有效日期");
      if (seen.has(item.date)) throw new Error(`${item.date} 填了两次调休`);
      seen.add(item.date);
      if (item.kind === "swap" && !validISODate(item.source || "")) throw new Error(`${item.date} 是调课，要写明上哪一天的课`);
    });
  };
  const renderStats = () => {
    const schools = state.stats.schools || [];
    const count = value => Number(value || 0).toLocaleString("zh-CN");
    $("todayUserCount").textContent = count(state.stats.todayUsers);
    $("todayUserDetail").textContent = `新设备 ${count(state.stats.newUsersToday)} · 昨日 ${count(state.stats.yesterdayUsers)}`;
    $("weeklyUserCount").textContent = count(state.stats.weeklyUsers);
    $("totalUserCount").textContent = count(state.stats.totalUsers);
    $("monthlyUserDetail").textContent = `按安装去重 · 未关联学校 ${count(state.stats.unassignedUsers)}`;
    $("activeSchoolCount").textContent = schools.filter(school => school.users > 0).length;
    const updatedAt = new Date(state.stats.updatedAt);
    $("statsUpdatedAt").textContent = Number.isNaN(updatedAt.getTime()) ? "近 30 天的设备使用情况" : `近 30 天 · 更新于 ${updatedAt.toLocaleString("zh-CN", {month:"2-digit",day:"2-digit",hour:"2-digit",minute:"2-digit"})}`;
    const list = $("statsList");
    list.replaceChildren();
    schools.forEach(school => {
      const row = document.createElement("div");
      row.className = "stats-row";
      row.innerHTML = `<div class="school-cell"><span class="school-avatar" aria-hidden="true">${escapeHTML(school.name.slice(0, 1))}</span><strong>${escapeHTML(school.name)}</strong></div><code>${escapeHTML(school.id)}</code><span class="today-cell">${count(school.todayUsers)}</span><span>${count(school.users)}</span>`;
      list.append(row);
    });
    $("unassignedStats").textContent = `未关联当前学校目录：${Number(state.stats.unassignedUsers || 0)} 台`;
    const filter = $("statsSchoolFilter");
    const selected = filter.value;
    filter.replaceChildren(new Option("全部学校", ""));
    schools.forEach(school => filter.add(new Option(school.name, school.id)));
    filter.value = schools.some(school => school.id === selected) ? selected : "";
    renderDeviceStats();
    renderSchoolShare();
    renderDailyTrend();
    if (!schools.length) {
      const empty = document.createElement("div");
      empty.className = "inline-empty";
      empty.textContent = "尚无学校统计数据";
      list.append(empty);
    }
  };

  const renderSchoolShare = () => {
    const total = Number(state.stats.totalUsers || 0);
    const rows = (state.stats.schools || []).filter(school => school.users > 0).map(school => ({ name: school.name, users: Number(school.users) }));
    if (state.stats.unassignedUsers > 0) rows.push({ name: "未关联学校", users: Number(state.stats.unassignedUsers) });
    const colors = ["#527c48", "#9ab76e", "#d0dba5", "#8ea79b", "#c6b789", "#8b9cae"];
    const legend = $("schoolShareLegend");
    legend.replaceChildren();
    $("chartDeviceCount").textContent = total.toLocaleString("zh-CN");
    const stops = [];
    let start = 0;
    rows.forEach((item, index) => {
      const percent = total ? item.users / total * 100 : 0;
      const color = colors[index % colors.length];
      stops.push(`${color} ${start}% ${Math.min(100, start + percent)}%`);
      start += percent;
      const row = document.createElement("div");
      row.className = "legend-row";
      row.innerHTML = `<i style="background:${color}" aria-hidden="true"></i><span>${escapeHTML(item.name)}</span><strong>${percent.toFixed(1)}%</strong>`;
      legend.append(row);
    });
    $("schoolShareChart").style.background = total && stops.length ? `conic-gradient(${stops.join(",")})` : "#edf1e7";
    $("schoolShareChart").setAttribute("aria-label", total ? rows.map(item => `${item.name} ${item.users} 台`).join("，") : "暂无使用数据");
    if (!rows.length) legend.innerHTML = '<p class="chart-empty">等待第一台设备<br>用户同意基础协议后开始统计</p>';
  };

  const renderDailyTrend = () => {
    const days = state.stats.daily || [];
    const chart = $("dailyTrend"), table = $("dailyTable"), tooltip = $("trendTooltip");
    chart.replaceChildren(); table.replaceChildren(); tooltip.hidden = true;
    // Round the axis up to a friendly step so a quiet month still has headroom.
    const peak = Math.max(0, ...days.map(day => Number(day.users || 0)));
    const step = peak <= 5 ? 5 : 10 ** Math.floor(Math.log10(peak)) * (peak / 10 ** Math.floor(Math.log10(peak)) <= 2 ? 2 : peak / 10 ** Math.floor(Math.log10(peak)) <= 5 ? 5 : 10);
    const top = Math.max(step, Math.ceil(peak / step) * step);
    $("trendMax").textContent = top.toLocaleString("zh-CN");
    const label = date => date.slice(5).replace("-", "/");
    const show = (bar, day) => {
      const users = Number(day.users || 0), fresh = Number(day.newUsers || 0);
      tooltip.innerHTML = "";
      const title = document.createElement("span"); title.textContent = day.date;
      tooltip.append(title);
      for (const [name, value, kind] of [["打开设备", users, ""], ["新设备", fresh, "is-new"], ["回访设备", users - fresh, "is-returning"]]) {
        const row = document.createElement("div");
        row.innerHTML = `<i class="${kind}"></i><strong></strong><em></em>`;
        row.querySelector("strong").textContent = value.toLocaleString("zh-CN");
        row.querySelector("em").textContent = name;
        tooltip.append(row);
      }
      const box = chart.getBoundingClientRect(), mark = bar.getBoundingClientRect();
      tooltip.hidden = false;
      const left = mark.left - box.left + mark.width / 2 + chart.offsetLeft;
      tooltip.style.left = `${Math.min(Math.max(left, tooltip.offsetWidth / 2), chart.offsetLeft + box.width - tooltip.offsetWidth / 2)}px`;
    };
    days.forEach((day, index) => {
      const users = Number(day.users || 0), fresh = Math.min(users, Number(day.newUsers || 0));
      const bar = document.createElement("button");
      bar.type = "button";
      bar.className = "trend-bar" + (index === days.length - 1 ? " is-today" : "");
      bar.setAttribute("aria-label", `${day.date}：打开 ${users} 台，其中新设备 ${fresh} 台`);
      const stack = document.createElement("span");
      stack.className = "trend-stack";
      stack.style.height = `${users / top * 100}%`;
      if (users - fresh > 0) { const seg = document.createElement("i"); seg.className = "is-returning"; seg.style.flexGrow = users - fresh; stack.append(seg); }
      if (fresh > 0) { const seg = document.createElement("i"); seg.className = "is-new"; seg.style.flexGrow = fresh; stack.append(seg); }
      bar.append(stack);
      if (index % 7 === (days.length - 1) % 7) {
        const tick = document.createElement("small"); tick.textContent = index === days.length - 1 ? "今天" : label(day.date);
        bar.append(tick);
      }
      bar.addEventListener("pointerenter", () => show(bar, day));
      bar.addEventListener("focus", () => show(bar, day));
      bar.addEventListener("pointerleave", () => { tooltip.hidden = true; });
      bar.addEventListener("blur", () => { tooltip.hidden = true; });
      chart.append(bar);
    });
    [...days].reverse().forEach(day => {
      const row = document.createElement("tr");
      for (const value of [day.date, Number(day.users || 0).toLocaleString("zh-CN"), Number(day.newUsers || 0).toLocaleString("zh-CN")]) {
        const cell = document.createElement("td"); cell.textContent = value; row.append(cell);
      }
      table.append(row);
    });
  };

  const renderDeviceStats = () => {
    const selected = $("statsSchoolFilter").value;
    const stats = (state.stats.schools || []).find(school => school.id === selected) || state.stats;
    for (const [id, key] of [["systemVersionStats", "systemVersions"], ["deviceModelStats", "deviceModels"], ["appVersionStats", "appVersions"]]) {
      const list = $(id);
      list.replaceChildren();
      const items = stats[key] || [];
      const total = items.reduce((sum, item) => sum + Number(item.users || 0), 0);
      for (const item of items) {
        const count = Number(item.users || 0);
        const percent = total ? Math.max(0, Math.min(100, count / total * 100)) : 0;
        const row = document.createElement("div");
        row.className = "distribution-row";
        row.innerHTML = `<strong>${escapeHTML(item.name)}</strong><span><b>${count.toLocaleString("zh-CN")} 台</b>${percent.toFixed(1)}%</span><div class="distribution-track" aria-hidden="true"><i style="width:${percent}%"></i></div>`;
        list.append(row);
      }
      if (!items.length) list.innerHTML = '<div class="distribution-empty"><svg aria-hidden="true" viewBox="0 0 24 24"><path d="M4 20h16M7 16v-4M12 16V5M17 16V9"/></svg><strong>还没有设备数据</strong><span>设备上报后，分布会显示在这里</span></div>';
    }
  };

  const fillApns = value => {
    const config = value || { keyPath: "", keyID: "", teamID: "", bundleID: "", tickSeconds: 5, channels: {} };
    const configured = Boolean(config.keyPath && config.keyID && config.teamID && config.bundleID);
    state.apns = config;
    $("apnsKeyPath").value = config.keyPath || "";
    $("apnsKeyID").value = config.keyID || "";
    $("apnsTeamID").value = config.teamID || "";
    $("apnsBundleID").value = config.bundleID || "";
    $("apnsTickSeconds").value = config.tickSeconds ?? 5;
    $("apnsStatus").textContent = configured ? "已配置" : "未配置";
    $("apnsStatus").className = `badge ${configured ? "configured" : ""}`;
    $("apnsNavDot").classList.toggle("configured", configured);
    $("apnsNavDot").setAttribute("aria-label", configured ? "已配置" : "未配置");
    markClean("apns");

  };
  const formApns = () => ({
    keyPath: $("apnsKeyPath").value.trim(), keyID: $("apnsKeyID").value.trim(),
    teamID: $("apnsTeamID").value.trim(), bundleID: $("apnsBundleID").value.trim(),
    tickSeconds: Number($("apnsTickSeconds").value)
  });

  const fillEntitlements = summary => {
    state.entitlementSummary = summary;
    const required = summary.settings.requireEntitlement;
    $("entitledDevices").textContent = summary.entitledDevices;
    $("entitlementMode").textContent = required ? "需要权益" : "Beta 免费";
    $("entitlementModeDetail").textContent = required ? "没有试用或买断的设备收不到提醒" : "所有设备都能收到提醒";
    $("requireEntitlement").checked = required;
  };
  const loadEntitlements = async () => fillEntitlements(await request("/v1/admin/entitlements"));
  const saveEntitlementSettings = async () => {
    const button = $("saveEntitlementSettingsButton");
    if ($("requireEntitlement").checked && !state.entitlementSummary?.settings.requireEntitlement
        && !confirm(`打开后，没有试用或买断权益的设备不再收到实时活动提醒（目前 ${state.entitlementSummary?.entitledDevices ?? 0} 台设备有权益）。确定开始收费？`)) return;
    setLoading(button, true);
    try {
      await request("/v1/admin/entitlements/settings", { method: "POST", body: JSON.stringify({ requireEntitlement: $("requireEntitlement").checked }) });
      await loadEntitlements();
      notice("收费规则已保存", "success");
    } catch (error) { notice(error.message, "error"); }
    finally { setLoading(button, false); }
  };
  const publisherKinds = { device: "设备", ip: "IP" };
  const publisherCell = publisher => publisher
    ? `${escapeHTML(publisherKinds[publisher.kind] || publisher.kind)} <code>${escapeHTML(publisher.id)}</code>` : "—";
  const dateTime = value => {
    const date = new Date(value);
    return Number.isNaN(date.getTime()) ? "—" : date.toLocaleString("zh-CN", { year: "numeric", month: "2-digit", day: "2-digit", hour: "2-digit", minute: "2-digit" });
  };
  const renderShareList = list => {
    const body = $("shareTable");
    body.replaceChildren();
    $("shareDetail").hidden = true;
    $("shareListSummary").textContent = list.total > list.shares.length ? `共 ${list.total} 份，显示最近更新的 ${list.shares.length} 份` : `共 ${list.total} 份分享`;
    for (const share of list.shares) {
      const row = document.createElement("tr");
      row.tabIndex = 0;
      row.innerHTML = `<td><code>${escapeHTML(share.code)}</code></td><td>${escapeHTML(share.owner)}</td><td>${publisherCell(share.publisher)}</td><td>${escapeHTML(share.schoolName)} · ${escapeHTML(share.termID)}</td><td>${share.courseCount}</td><td>${dateTime(share.updatedAt)}</td><td><button class="button danger" type="button">删除</button></td>`;
      const open = () => showShare(share.code);
      row.onclick = open;
      row.onkeydown = event => { if (event.key === "Enter" && event.target === row) open(); };
      row.querySelector("button").onclick = event => { event.stopPropagation(); deleteShare(share, event.currentTarget); };
      body.append(row);
    }
    if (!list.shares.length) body.innerHTML = `<tr><td colspan="7">${$("shareSearch").value.trim() ? "没有匹配的分享" : "还没有分享"}</td></tr>`;
  };
  const attestEndpoints = { "share.publish": "发布分享", "share.update": "更新分享", "liveActivity.register": "注册实时活动设备",
    "liveActivity.timetable": "上传实时活动课表", "usage.report": "使用统计上报", "imageImport.recognize": "图片识别" };
  const renderAbuse = abuse => {
    const shares = abuse.shares;
    $("shareTotal").textContent = shares.total;
    $("shareBytes").textContent = `课程数据 ${Math.round(shares.payloadBytes / 1024)} KB`;
    $("shareToday").textContent = shares.createdToday;
    $("shareUnidentified").textContent = `其中仅凭 IP 识别 ${shares.unidentifiedToday}`;
    $("shareRules").textContent = `每人 ${shares.maxActivePerPublisher} 个`;
    $("shareRulesDetail").textContent = `${shares.idleDays} 天无人读取或更新即删除`;
    const attest = abuse.appAttest;
    const modes = { off: "关闭", log: "只记录", enforce: "拦截伪造" };
    $("attestMode").textContent = attest ? modes[attest.mode] : "—";
    const keys = attest ? Object.values(attest.keys).reduce((sum, count) => sum + count, 0) : 0;
    $("attestKeys").textContent = attest && !attest.configured ? "未配置 Team ID，无法认证" : `已认证设备 ${keys}`;
    const byEndpoint = {};
    for (const row of attest ? attest.outcomes : []) {
      const entry = byEndpoint[row.endpoint] ||= { valid: 0, missing: 0, invalid: 0, reasons: {} };
      if (row.outcome === "valid" || row.outcome === "missing") entry[row.outcome] += row.count;
      else { entry.invalid += row.count; entry.reasons[row.outcome] = (entry.reasons[row.outcome] || 0) + row.count; }
    }
    const body = $("attestTable");
    body.replaceChildren();
    for (const [endpoint, entry] of Object.entries(byEndpoint)) {
      const row = document.createElement("tr");
      const reasons = Object.entries(entry.reasons).map(([reason, count]) => `${reason} ${count}`).join("、") || "—";
      row.innerHTML = `<td>${escapeHTML(attestEndpoints[endpoint] || endpoint)}</td><td>${entry.valid}</td><td>${entry.missing}</td><td>${entry.invalid}</td><td>${escapeHTML(reasons)}</td>`;
      body.append(row);
    }
    if (!body.children.length) body.innerHTML = '<tr><td colspan="5">近 7 天没有记录</td></tr>';
  };
  const loadShares = async () => {
    const [list, abuse] = await Promise.all([
      request(`/v1/admin/shares?q=${encodeURIComponent($("shareSearch").value.trim())}`), request("/v1/admin/abuse")
    ]);
    renderShareList(list); renderAbuse(abuse);
  };
  const showShare = async code => {
    try {
      // The public read: exactly what a follower installs.
      const share = await request(`/v1/shares/${encodeURIComponent(code)}`);
      const names = [...new Set(share.courses.map(course => course.name))];
      const detail = $("shareDetail");
      detail.innerHTML = `<h3>分享 <code>${escapeHTML(share.id)}</code> · ${escapeHTML(share.name)}</h3><p>第一周周一 ${escapeHTML(share.semester_start_monday || "—")} · ${share.term_week_count} 周 · ${share.courseCount} 条课程记录 · 创建于 ${dateTime(share.createdAt)}</p><ul class="share-courses">${names.map(name => `<li>${escapeHTML(name)}</li>`).join("")}</ul>`;
      detail.hidden = false;
    } catch (error) {
      notice(error.status === 404 ? "该分享已不存在" : error.message, "error");
      if (error.status === 404) loadShares().catch(() => {});
    }
  };
  const deleteShare = async (share, button) => {
    if (!confirm(`删除 ${share.owner} 的分享 ${share.code}？\n\n分享码立即失效，已导入的人保留本机副本但不再收到更新。此操作无法恢复。`)) return;
    setLoading(button, true);
    try {
      await request(`/v1/admin/shares/${encodeURIComponent(share.code)}`, { method: "DELETE" });
      notice(`分享 ${share.code} 已删除`, "success");
    } catch (error) {
      if (error.status !== 404) { setLoading(button, false); return notice(error.message, "error"); }
      notice(`分享 ${share.code} 已不存在`, "error");
    }
    await loadShares().catch(error => notice(error.message, "error"));
  };

  const auditActions = {
    "school.create": "新增学校", "school.save": "保存学校", "school.rename": "修改学校 ID", "school.delete": "删除学校",
    "term.save": "保存学期", "term.delete": "删除学期", "calendar.save": "保存调休", "share.delete": "删除分享",
    "entitlement.settings": "保存实时活动权益规则",
    "apns.save": "保存 APNs", "imageImport.save": "保存图片导入配置", "session.signIn": "登录", "session.signOut": "退出", "session.failed": "登录失败"
  };
  const loadAudit = async () => {
    const { entries } = await request(`/v1/admin/audit?action=${encodeURIComponent($("auditFilter").value)}`);
    const body = $("auditTable");
    body.replaceChildren();
    for (const entry of entries) {
      const row = document.createElement("tr");
      const detail = Object.entries(entry.detail || {}).map(([key, value]) => `${key}: ${typeof value === "object" ? JSON.stringify(value) : value}`).join("，");
      for (const value of [dateTime(entry.at), entry.admin || "—", auditActions[entry.action] || entry.action, entry.target || "—", detail || "—"]) {
        const cell = document.createElement("td"); cell.textContent = value; row.append(cell);
      }
      if (entry.action === "session.failed") row.classList.add("is-failed");
      body.append(row);
    }
    if (!entries.length) body.innerHTML = '<tr><td colspan="5">还没有操作记录</td></tr>';
  };

  const saveSchool = async () => {
    const button = $("saveSchoolButton");
    try {
      const value = { id: state.school.id, name: $("schoolName").value.trim(), note: $("schoolNote").value.trim(), semesterStart: "", periods: periodRows(), seasonalPeriods: activeSeasonRows(), unifiedHolidaysEnabled: $("schoolUnifiedHolidaysEnabled").checked, unifiedMakeupEnabled: $("schoolUnifiedMakeupEnabled").checked };
      if (!value.id || !value.name) throw new Error("学校 ID 和名称不能为空");
      validatePeriods(value.periods);
      if ($("schoolSeasonEnabled").checked && !value.seasonalPeriods.length) throw new Error("启用分季作息时，请至少添加一套作息");
      const dates = new Set();
      value.seasonalPeriods.forEach(season => {
        const day = new Date(`2001-${season.from}T00:00:00Z`);
        if (!/^\d{2}-\d{2}$/.test(season.from) || Number.isNaN(day.valueOf()) || day.toISOString().slice(5, 10) !== season.from || dates.has(season.from)) throw new Error("分季作息的生效月日须有效且不能重复，格式为月-日（如 05-01）");
        dates.add(season.from);
        if (season.periods.length !== value.periods.length) throw new Error("分季作息与全年作息的节次数量须相同");
        validatePeriods(season.periods);
      });
      setLoading(button, true);
      const saved = await request(`/v1/admin/schools/${encodeURIComponent(value.id)}`, { method: "POST", body: JSON.stringify(value) });
      const index = state.schools.findIndex(item => item.id === saved.id);
      if (index >= 0) state.schools[index] = saved; else state.schools.push(saved);
      state.school = structuredClone(saved);
      // The term form may hold its own unsaved edits: leave it as it is.
      updateMetrics(); fillSchool({ keepTerm: true });
      notice("学校配置已保存", "success");
    } catch (error) { notice(error.message, "error"); }
    finally { setLoading(button, false); }
  };
  const renameSchool = async () => {
    const oldID = state.school?.id;
    const newID = $("schoolId").value.trim();
    if (!oldID || newID === oldID) return;
    if (!/^[a-zA-Z0-9][a-zA-Z0-9._-]{1,79}$/.test(newID)) return notice("学校 ID 需为 2-80 位字母、数字、点、下划线或短横线", "error");
    if (!confirm(`确定将学校 ID 从 ${oldID} 改为 ${newID}？已保存的学期、分享和统计关联会随之更新。`)) return;
    const button = $("renameSchoolButton");
    setLoading(button, true);
    try {
      const saved = await request(`/v1/admin/schools/${encodeURIComponent(oldID)}/rename`, {
        method: "POST", body: JSON.stringify({ id: newID })
      });
      state.schools = state.schools.map(school => school.id === oldID ? saved : school);
      // Keep unsaved name, note and period edits: only the ID changed.
      const draft = { name: $("schoolName").value, note: $("schoolNote").value, periods: periodRows(), seasonalPeriods: seasonRows(), seasonalPeriodsEnabled: $("schoolSeasonEnabled").checked, unifiedHolidaysEnabled: $("schoolUnifiedHolidaysEnabled").checked, unifiedMakeupEnabled: $("schoolUnifiedMakeupEnabled").checked };
      state.school = { ...structuredClone(saved), periods: draft.periods, seasonalPeriods: draft.seasonalPeriods };
      updateMetrics(); fillSchool({ keepTerm: true });
      $("schoolName").value = draft.name; $("schoolNote").value = draft.note;
      $("schoolSeasonEnabled").checked = draft.seasonalPeriodsEnabled;
      $("schoolUnifiedHolidaysEnabled").checked = draft.unifiedHolidaysEnabled;
      $("schoolUnifiedMakeupEnabled").checked = draft.unifiedMakeupEnabled;
      updateSeasonEditor();
      savedForms.school = JSON.stringify({ name: saved.name, note: saved.note || "", periods: saved.periods, seasonalPeriods: saved.seasonalPeriods || [], seasonalPeriodsEnabled: Boolean(saved.seasonalPeriods?.length), unifiedHolidaysEnabled: saved.unifiedHolidaysEnabled !== false, unifiedMakeupEnabled: saved.unifiedMakeupEnabled !== false });
      notice(`学校 ID 已更新为 ${saved.id}`, "success");
    } catch (error) { notice(error.message, "error"); }
    finally { setLoading(button, false); }
  };
  const saveTerm = async () => {
    const button = $("saveTermButton");
    try {
      const term = formTerm();
      validateTerm(term);
      setLoading(button, true);
      await request(`/v1/admin/schools/${encodeURIComponent(state.school.id)}/terms`, { method: "POST", body: JSON.stringify(term) });
      const data = await request("/v1/schools");
      state.schools = data.schools || [];
      const fresh = state.schools.find(school => school.id === state.school.id);
      // Only the terms are new: the school form may hold its own unsaved edits.
      state.school.terms = structuredClone(fresh.terms);
      state.term = structuredClone(fresh.terms.find(item => item.id === term.id));
      updateMetrics(); renderSchools(); renderTerms(); fillTerm();
      notice(`学期 ${state.term.id} 已保存，服务端版本 v${state.term.version}`, "success");
    } catch (error) { notice(error.message, "error"); }
    finally { setLoading(button, false); }
  };
  const deleteTerm = async () => {
    const school = state.school, term = state.term;
    if (!school || !term?.version || term.current) return;
    if (!confirm(`删除“${school.name}”的学期 ${term.id}？\n\n客户端只跟随当前学期，不受影响；绑定这个学期的分享保留发布时的时间，但不能再“同步最新配置”。此操作无法恢复。`)) return;
    const button = $("deleteTermButton");
    setLoading(button, true);
    try {
      await request(`/v1/admin/schools/${encodeURIComponent(school.id)}/terms/${encodeURIComponent(term.id)}`, { method: "DELETE" });
      const fresh = ((await request("/v1/schools")).schools || []);
      state.schools = fresh;
      state.school.terms = structuredClone(fresh.find(item => item.id === school.id)?.terms || []);
      const current = state.school.terms.find(item => item.current) || state.school.terms[0];
      state.term = current ? structuredClone(current) : emptyTerm();
      updateMetrics(); renderSchools(); renderTerms(); fillTerm();
      notice(`学期 ${term.id} 已删除`, "success");
    } catch (error) { notice(error.message, "error"); }
    finally { setLoading(button, false); $("deleteTermButton").disabled = !state.term?.version || Boolean(state.term.current); }
  };
  const saveCalendar = async () => {
    const button = $("saveCalendarButton");
    try {
      const adjustments = adjustmentRows();
      validateAdjustments(adjustments);
      setLoading(button, true);
      state.calendar = await request("/v1/admin/calendar", { method: "POST", body: JSON.stringify({ adjustments }) });
      renderCalendar(); markClean("calendar");
      const data = await request("/v1/schools");
      state.schools = data.schools || [];
      updateMetrics(); renderSchools();
      notice(`统一调休已保存，版本 v${state.calendar.version}`, "success");
    } catch (error) { notice(error.message, "error"); }
    finally { setLoading(button, false); }
  };
  const importCalendar = async () => {
    const button = $("importCalendarButton");
    setLoading(button, true);
    try {
      const academicYear = Number($("calendarAcademicYear").value);
      if (!Number.isInteger(academicYear) || academicYear < 2000 || academicYear > 2100) throw new Error("请填写 2000–2100 的学年起始年份");
      const result = await request("/v1/admin/calendar/import", { method: "POST", body: JSON.stringify({ academicYear }) });
      const current = adjustmentRows();
      const seen = new Set(current.map(item => item.date));
      const added = (result.proposed || []).filter(item => !seen.has(item.date));
      if (current.length + added.length > 200) throw new Error("最多配置 200 条调休，请先清理过期日期");
      state.calendar.adjustments = [...current, ...added].sort((a, b) => a.date.localeCompare(b.date));
      renderCalendar();
      const pending = added.filter(item => item.needsSource).length;
      const kept = (result.years || []).reduce((sum, year) => sum + (year.kept?.length || 0), 0);
      const note = $("calendarImportNote");
      note.hidden = false;
      note.textContent = added.length
        ? `已读取 ${(result.years || []).map(year => year.year).join("、")} 年安排：新增 ${added.length} 条`
          + (kept ? `，保留已有 ${kept} 条` : "")
          + (pending ? `。其中 ${pending} 个补课日需要先选定上哪天的课，再点“保存调休”。` : "。确认后点“保存调休”写入。")
        : `已读取 ${(result.years || []).map(year => year.year).join("、")} 年安排，没有新的调休需要添加。`;
      if (result.errors?.length) note.textContent += ` 部分年份未获取，请稍后重新导入补齐：${result.errors.join("；")}`;
      (result.errors || []).forEach(error => notice(error, "error"));
      if (!result.errors?.length) notice(added.length ? `导入 ${added.length} 条待确认调休` : "调休已是最新", "success");
    } catch (error) { notice(error.message, "error"); }
    finally { setLoading(button, false); }
  };
  const saveApns = async () => {
    const button = $("saveApnsButton");
    setLoading(button, true);
    try {
      const save = extra => request("/v1/admin/apns", { method: "POST", body: JSON.stringify({ ...formApns(), ...extra }) });
      let saved;
      try { saved = await save({}); }
      catch (error) {
        // Another Bundle ID while the current app's devices still get broadcasts:
        // switching gives them up, so it takes an explicit confirmation.
        const impact = error.status === 409 && error.data?.retire;
        if (!impact) throw error;
        const ok = confirm(`旧 Bundle ID（${impact.bundles.join("、")}）还有未到期的广播。\n\n`
          + `切换到新 Bundle ID 会放弃旧 App：${impact.devices} 台设备不再收到实时活动，`
          + `${impact.channels} 个广播频道会被删除。新 App 的设备不受影响。\n\n确定切换吗？`);
        if (!ok) { notice("已取消，APNs 配置未改动"); return; }
        saved = await save({ retireOtherBundles: true });
      }
      fillApns(saved);
      notice("APNs 配置已保存", "success");
    } catch (error) { notice(error.message, "error"); }
    finally { setLoading(button, false); }
  };
  const refreshStats = async () => {
    const button = $("refreshStatsButton");
    setLoading(button, true);
    try {
      state.stats = await request("/v1/admin/stats");
      renderStats(); notice("统计数据已刷新", "success");
    } catch (error) { notice(error.message, "error"); }
    finally { setLoading(button, false); }
  };

  const openNewSchool = () => {
    if (!confirmDiscard(["school", "term"])) return;
    $("newSchoolForm").reset(); $("newSchoolDialog").showModal();
    requestAnimationFrame(() => $("newSchoolId").focus());
  };
  const createSchool = async event => {
    event.preventDefault();
    const id = $("newSchoolId").value.trim();
    const name = $("newSchoolName").value.trim();
    if (state.schools.some(item => item.id === id)) return notice("学校 ID 已存在", "error");
    const button = event.currentTarget.querySelector('[type="submit"]');
    setLoading(button, true);
    try {
      // create: true 让服务端在 ID 已被占用时返回 409，而不是覆盖别人刚建好的学校。
      const school = await request(`/v1/admin/schools/${encodeURIComponent(id)}`, {
        method: "POST", body: JSON.stringify({ create: true, name, note: "", periods: [{ id: 1, name: "第1节", start: "08:00", end: "08:50" }] })
      });
      state.schools.push(school); updateMetrics(); $("newSchoolDialog").close();
      $("schoolSearch").value = ""; selectSchool(school.id);
      document.querySelector(".metadata-section").open = true;
      notice("学校已创建，请继续配置节次与学期", "success");
    } catch (error) {
      if (error.status !== 409) return notice(error.message, "error");
      notice("该学校 ID 已存在，已刷新学校列表，请换一个 ID 再试", "error");
      try {
        state.schools = (await request("/v1/schools")).schools || [];
        renderSchools(); updateMetrics();
      } catch (refreshError) { notice(refreshError.message, "error"); }
    }
    finally { setLoading(button, false); }
  };
  const deleteSchool = async () => {
    const school = state.school;
    if (!school || !confirm(`确定删除“${school.name}”及其全部学期配置？已有分享快照会保留。${unsaved(["school", "term"]).length ? "\n\n表单里未保存的修改也会一并丢弃。" : ""}`)) return;
    const button = $("deleteSchoolButton");
    setLoading(button, true);
    try {
      await request(`/v1/admin/schools/${encodeURIComponent(school.id)}`, { method: "DELETE" });
      state.schools = state.schools.filter(item => item.id !== school.id);
      if (state.school?.id === school.id) {
        state.school = null; state.term = null;
        $("editor").hidden = true; $("editorEmpty").hidden = false;
      }
      renderSchools(); updateMetrics();
      notice("学校及学期配置已删除", "success");
    } catch (error) { notice(error.message, "error"); }
    finally { setLoading(button, false); }
  };
  const imageImportFields = ["enabled", "endpoint", "model", "requireAttest", "deviceDailyLimit", "ipHourlyLimit", "globalDailyLimit", "timeoutSeconds", "maxOutputTokens"];
  const imageField = key => $("imageImport" + key[0].toUpperCase() + key.slice(1));
  const formImageImport = () => Object.fromEntries(imageImportFields.map(key => {
    const element = imageField(key);
    return [key, element.type === "checkbox" ? element.checked : element.type === "number" ? Number(element.value) : element.value.trim()];
  }));
  const showImageImport = data => {
    imageImportFields.forEach(key => {
      const element = imageField(key);
      if (element.type === "checkbox") element.checked = data.config[key];
      else element.value = data.config[key];
    });
    $("imageImportStatus").textContent = `${data.config.enabled ? "已开放" : "已关闭"} · ${data.config.configured ? "模型与密钥已配置" : "请设置模型和服务器 API 密钥"}`;
    $("saveImageImportButton").disabled = false;
    const outcomes = { success: "成功", empty: "未识别到课程", upstreamError: "接口失败", invalidResult: "结果无效", pending: "处理中或被中断", attestRequired: "需要设备验证", invalidImage: "图片无效", busy: "并发已满", quotaRejected: "超过额度" };
    const rows = data.stats.daily || [];
    const today = rows.filter(row => row.day === data.stats.today);
    const attempts = today.filter(row => ["success", "empty", "upstreamError", "invalidResult", "pending"].includes(row.outcome)).reduce((sum, row) => sum + row.requests, 0);
    $("imageImportSummary").textContent = `今日已调用 ${attempts} / ${data.config.globalDailyLimit} 次 · 成功 ${today.filter(row => row.outcome === "success").reduce((sum, row) => sum + row.requests, 0)} 次 · 统计保留 ${data.stats.retentionDays} 天`;
    $("imageImportStats").innerHTML = rows.length ? rows.map(row => `<tr><td>${escapeHTML(row.day)}</td><td>${escapeHTML(outcomes[row.outcome] || row.outcome)}</td><td>${row.requests}</td><td>${row.inputTokens}</td><td>${row.outputTokens}</td><td>${row.courses}</td><td>${(row.durationMs / row.requests / 1000).toFixed(1)} 秒</td></tr>`).join("") : '<tr><td colspan="7">暂无识别记录</td></tr>';
    markClean("imageImport");
  };
  const loadImageImport = async () => showImageImport(await request("/v1/admin/image-import"));
  $("imageImportForm").onsubmit = async event => {
    event.preventDefault();
    const button = $("saveImageImportButton"); setLoading(button, true);
    try {
      showImageImport(await request("/v1/admin/image-import", { method: "POST", body: JSON.stringify(formImageImport()) }));
      notice("图片导入配置已保存", "success");
    } catch (error) { notice(error.message, "error"); }
    finally { setLoading(button, false); }
  };
  $("refreshImageImportButton").onclick = async () => {
    if (!confirmDiscard(["imageImport"])) return;
    try { await loadImageImport(); } catch (error) { notice(error.message, "error"); }
  };

  const loadConsole = async () => {
    const catalogue = await request("/v1/schools");
    state.authenticated = true;
    state.schools = catalogue.schools || [];
    state.school = null; state.term = null;
    renderSchools(); updateMetrics(); updateConnectionUI(true);
    if (state.schools.length) selectSchool(state.schools[0].id);
    else { $("editor").hidden = true; $("editorEmpty").hidden = false; }
    // Every other section loads on its own: one that fails reports itself and
    // leaves the rest usable. A save button opens only once its data is in,
    // so a failed load can never be saved over the real configuration.
    const section = (load, show) => load().then(show).catch(error => notice(error.message, "error"));
    section(() => request("/v1/admin/apns"), apns => { fillApns(apns); $("saveApnsButton").disabled = false; });
    section(() => request("/v1/admin/calendar"), calendar => {
      state.calendar = calendar; renderCalendar(); markClean("calendar"); $("saveCalendarButton").disabled = false;
    });
    section(() => request("/v1/admin/stats"), stats => { state.stats = stats; renderStats(); });
    section(loadEntitlements, () => {});
    section(loadImageImport, () => {});
    section(loadShares, () => {});
    if (state.view === "audit") section(loadAudit, () => {});
  };
  const signedOut = () => {
    state.authenticated = false; state.admin = null; state.schools = []; state.school = null; state.term = null;
    Object.keys(savedForms).forEach(key => delete savedForms[key]);
    $("saveApnsButton").disabled = true; $("saveCalendarButton").disabled = true;
    $("saveImageImportButton").disabled = true;
    updateConnectionUI(false);
  };
  const connect = async event => {
    event?.preventDefault();
    const token = $("adminToken").value.trim();
    if (!token) return;
    const button = $("connectButton");
    setLoading(button, true); notice("正在读取服务配置…");
    try {
      // The token is exchanged for an HttpOnly session cookie and then dropped,
      // so a reload restores the console without asking for it again.
      state.admin = (await request("/v1/admin/session", { method: "POST", body: JSON.stringify({ token }) })).admin;
      $("adminToken").value = "";
      await loadConsole();
      notice(`已读取 ${state.schools.length} 所学校`, "success");
    } catch (error) {
      signedOut();
      notice(error.status === 429 ? "错误次数过多，请 15 分钟后再试" : error.message === "admin token required" ? "管理员令牌无效" : error.message, "error");
    } finally { setLoading(button, false); }
  };
  const restore = async () => {
    try {
      state.admin = (await request("/v1/admin/session")).admin;
    } catch { return signedOut(); }
    try {
      await loadConsole();
    } catch (error) {
      signedOut();
      notice(error.message, "error");
    }
  };
  const disconnect = async () => {
    if (!confirmDiscard()) return;
    try { await request("/v1/admin/session", { method: "DELETE" }); } catch { /* the cookie is dropped either way */ }
    $("adminToken").value = "";
    signedOut(); notice("管理会话已断开", "success"); $("adminToken").focus();
  };

  document.querySelectorAll(".nav-item").forEach(item => { item.onclick = () => showView(item.dataset.view); });
  $("authForm").onsubmit = connect;
  $("disconnectButton").onclick = disconnect;
  $("newSchoolButton").onclick = openNewSchool;
  $("newSchoolForm").onsubmit = createSchool;
  $("closeSchoolDialog").onclick = () => $("newSchoolDialog").close();
  $("cancelSchoolDialog").onclick = () => $("newSchoolDialog").close();
  $("newTermButton").onclick = () => { if (!confirmDiscard(["term"])) return; state.term = emptyTerm(); renderTerms(); fillTerm(); $("termId").focus(); };
  $("saveTermButton").onclick = saveTerm;
  $("saveSchoolButton").onclick = saveSchool;
  $("renameSchoolButton").onclick = renameSchool;
  $("schoolId").oninput = () => { $("renameSchoolButton").disabled = $("schoolId").value.trim() === state.school?.id; };
  $("saveCalendarButton").onclick = saveCalendar;
  $("importCalendarButton").onclick = importCalendar;
  $("saveApnsButton").onclick = saveApns;
  $("deleteSchoolButton").onclick = deleteSchool;
  $("deleteTermButton").onclick = deleteTerm;
  $("auditFilter").onchange = () => loadAudit().catch(error => notice(error.message, "error"));
  window.addEventListener("beforeunload", event => { if (state.authenticated && unsaved().length) event.preventDefault(); });
  $("refreshStatsButton").onclick = refreshStats;
  $("statsSchoolFilter").onchange = renderDeviceStats;
  $("saveEntitlementSettingsButton").onclick = saveEntitlementSettings;
  let shareSearchTimer;
  $("shareSearch").oninput = () => { clearTimeout(shareSearchTimer); shareSearchTimer = setTimeout(() => loadShares().catch(error => notice(error.message, "error")), 250); };
  $("schoolSearch").oninput = renderSchools;
  $("addSchoolPeriodButton").onclick = () => {
    state.school.periods = periodRows();
    state.school.seasonalPeriods = seasonRows();
    // Avoid Array.prototype.at so the console also works in older Safari/WebViews.
    const last = state.school.periods[state.school.periods.length - 1];
    const start = last?.end || "08:00";
    state.school.periods.push({ id: state.school.periods.length + 1, name: `第${state.school.periods.length + 1}节`, start, end: addMinutes(start, 50) });
    state.school.seasonalPeriods.forEach(season => {
      const start = season.periods[season.periods.length - 1]?.end || "08:00";
      season.periods.push({ start, end: addMinutes(start, 50) });
    });
    renderSchoolPeriods(); renderSeasons();
  };
  $("schoolSeasonEnabled").onchange = () => {
    // Keep the rows while disabled so toggling back before saving restores edits.
    if ($("schoolSeasonEnabled").checked && !seasonRows().length) {
      state.school.seasonalPeriods = [{ from: "", periods: structuredClone(periodRows()) }];
      renderSeasons();
    }
    updateSeasonEditor();
  };
  $("addSeasonButton").onclick = () => {
    state.school.seasonalPeriods = seasonRows();
    state.school.seasonalPeriods.push({ from: "", periods: structuredClone(periodRows()) });
    renderSeasons();
  };
  $("addGlobalAdjustmentButton").onclick = () => {
    state.calendar.adjustments = adjustmentRows();
    state.calendar.adjustments.push({ date: "", kind: "off", note: "" });
    renderCalendar();
  };
  $("toggleTokenButton").onclick = () => {
    const revealed = $("adminToken").type === "text";
    $("adminToken").type = revealed ? "password" : "text";
    $("toggleTokenButton").classList.toggle("revealed", !revealed);
    $("toggleTokenButton").title = revealed ? "显示令牌" : "隐藏令牌";
    $("toggleTokenButton").setAttribute("aria-label", revealed ? "显示令牌" : "隐藏令牌");
  };
  const closeNavigation = () => {
    const wasOpen = document.body.classList.contains("nav-open");
    setNavigation(false);
    if (wasOpen) $("menuButton").focus();
  };
  $("menuButton").onclick = () => {
    setNavigation(!document.body.classList.contains("nav-open"));
    if (document.body.classList.contains("nav-open")) {
      ($("sidebar").querySelector(".nav-item.active:not(:disabled)") || $("sidebar").querySelector(".brand")).focus();
    }
  };
  $("sidebarScrim").onclick = closeNavigation;
  document.addEventListener("keydown", event => { if (event.key === "Escape") closeNavigation(); });
  setNavigation(false);
  $("newSchoolDialog").addEventListener("click", event => { if (event.target === $("newSchoolDialog")) $("newSchoolDialog").close(); });
  updateConnectionUI(false);
  restore();
})();
