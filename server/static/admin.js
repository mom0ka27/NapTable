(() => {
  const state = {
    token: "", schools: [], school: null, term: null, apns: null,
    calendar: { version: 1, adjustments: [] }, stats: { totalUsers: 0, schools: [] }, view: "schools"
  };
  const $ = id => document.getElementById(id);
  const escapeHTML = value => String(value ?? "").replace(/[&<>"']/g, char => ({ "&": "&amp;", "<": "&lt;", ">": "&gt;", "\"": "&quot;", "'": "&#39;" })[char]);
  const escapeAttr = escapeHTML;
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
    if (state.token) headers["X-Admin-Token"] = state.token;
    const response = await fetch(path, { ...options, headers });
    const data = await response.json().catch(() => ({}));
    if (!response.ok) throw new Error(data.error || `HTTP ${response.status}`);
    return data;
  };

  const updateMetrics = () => {
    $("schoolCount").textContent = state.schools.length;
    $("termCount").textContent = state.schools.reduce((sum, school) => sum + (school.terms?.length || 0), 0);
    $("periodCount").textContent = state.schools.reduce((sum, school) => sum + (school.periods?.length || 0), 0);
  };
  const updateConnectionUI = connected => {
    $("authView").hidden = connected;
    $("connectionStatus").classList.toggle("connected", connected);
    $("connectionStatus").innerHTML = `<span></span>${connected ? "已连接" : "未连接"}`;
    $("sessionIndicator").classList.toggle("connected", connected);
    $("sidebarSessionText").textContent = connected ? "已安全连接" : "尚未连接";
    $("disconnectButton").hidden = !connected;
    document.querySelectorAll(".nav-item").forEach(item => { item.disabled = !connected; });
    if (connected) showView(state.view);
    else document.querySelectorAll(".content-view").forEach(view => { view.hidden = true; });
  };
  const viewCopy = {
    schools: ["学校配置", "维护学校节次与当前学期的第一周配置。"],
    calendar: ["统一调休", "维护对所有学校生效的调休安排。"],
    stats: ["使用统计", "查看各学校已注册设备的使用人数。"],
    apns: ["APNs 推送", "配置推送凭据并管理学校广播频道。"]
  };
  const showView = view => {
    if (!viewCopy[view]) return;
    state.view = view;
    document.querySelectorAll(".nav-item").forEach(item => item.classList.toggle("active", item.dataset.view === view));
    document.querySelectorAll(".content-view").forEach(element => {
      element.hidden = !state.token || element.id !== `${view}View`;
    });
    $("pageTitle").textContent = viewCopy[view][0];
    $("breadcrumbCurrent").textContent = viewCopy[view][0];
    $("pageSubtitle").textContent = viewCopy[view][1];
    document.body.classList.remove("nav-open");
  };
  const addMinutes = (time, minutes) => {
    const [hours, mins] = String(time || "00:00").split(":").map(Number);
    const total = Math.min((hours * 60) + mins + minutes, (24 * 60) - 1);
    return `${String(Math.floor(total / 60)).padStart(2, "0")}:${String(total % 60).padStart(2, "0")}`;
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
      button.innerHTML = `<span class="school-avatar">${escapeHTML(school.name.slice(0, 1) || school.id.slice(0, 1))}</span><span><strong>${escapeHTML(school.name)}</strong><small>${escapeHTML(school.id)} · ${(school.terms || []).length} 个学期</small></span><svg aria-hidden="true" viewBox="0 0 24 24"><path d="m9 18 6-6-6-6"/></svg>`;
      button.onclick = () => selectSchool(school.id);
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
      button.onclick = () => selectTerm(term.id);
      list.append(button);
    });
  };
  const periodRows = () => [...$("schoolPeriodList").querySelectorAll(".period-row")].map((row, index) => ({
    id: index + 1, name: `第${index + 1}节`,
    start: row.querySelector('[data-field="start"]').value,
    end: row.querySelector('[data-field="end"]').value
  }));
  const renderSchoolPeriods = () => {
    const list = $("schoolPeriodList");
    list.replaceChildren();
    (state.school?.periods || []).forEach((period, index) => {
      const row = document.createElement("div");
      row.className = "period-row";
      row.innerHTML = `<div class="period-number">第 ${index + 1} 节</div><label><span>开始时间</span><input data-field="start" value="${escapeAttr(period.start)}" type="time" aria-label="第${index + 1}节开始时间"></label><label><span>结束时间</span><input data-field="end" value="${escapeAttr(period.end)}" type="time" aria-label="第${index + 1}节结束时间"></label><button class="remove-button" type="button" aria-label="删除第${index + 1}节" title="删除节次"><svg aria-hidden="true" viewBox="0 0 24 24"><path d="M3 6h18M8 6V4h8v2M19 6l-1 14H6L5 6M10 11v5M14 11v5"/></svg></button>`;
      row.querySelector(".remove-button").onclick = () => {
        state.school.periods = periodRows();
        state.school.periods.splice(index, 1);
        renderSchoolPeriods();
      };
      list.append(row);
    });
  };
  const fillSchool = () => {
    $("editorTitle").textContent = state.school.name;
    $("editorEyebrow").textContent = state.school.id;
    $("schoolId").value = state.school.id;
    $("schoolName").value = state.school.name;
    $("schoolNote").value = state.school.note || "";
    $("newTermButton").disabled = false;
    $("editorEmpty").hidden = true;
    $("editor").hidden = false;
    renderSchools(); renderSchoolPeriods(); renderTerms(); fillTerm();
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
  };
  const selectSchool = id => {
    state.school = state.schools.find(school => school.id === id);
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
    if (kind === "swap") value.source = row.querySelector('[data-field="source"]').value;
    return value;
  });
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
      row.className = "adjustment-row";
      const swap = item.kind === "swap";
      row.innerHTML = `<label>日期<input data-field="date" type="date" value="${escapeAttr(item.date || "")}"></label><label>类型<select data-field="kind"><option value="off"${swap ? "" : " selected"}>放假</option><option value="swap"${swap ? " selected" : ""}>调课</option></select></label><label>上哪天的课<input data-field="source" type="date" value="${escapeAttr(item.source || "")}"${swap ? "" : " disabled"}>${candidateChips(item, swap)}</label><label>说明<input data-field="note" maxlength="80" placeholder="例如 国庆节" value="${escapeAttr(item.note || "")}"></label><button class="remove-button" type="button" aria-label="删除这条调休" title="删除调休"><svg aria-hidden="true" viewBox="0 0 24 24"><path d="M3 6h18M8 6V4h8v2M19 6l-1 14H6L5 6M10 11v5M14 11v5"/></svg></button>`;
      if (swap && !item.source) row.classList.add("needs-source");
      row.querySelectorAll(".candidate-chip").forEach(chip => {
        chip.onclick = () => {
          row.querySelector('[data-field="source"]').value = chip.dataset.date;
          state.calendar.adjustments = adjustmentRows();
          renderCalendar();
        };
      });
      row.querySelector('[data-field="kind"]').onchange = () => { state.calendar.adjustments = adjustmentRows(); renderCalendar(); };
      row.querySelector(".remove-button").onclick = () => {
        state.calendar.adjustments = adjustmentRows();
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
    $("totalUserCount").textContent = state.stats.totalUsers || 0;
    $("activeSchoolCount").textContent = schools.filter(school => school.users > 0).length;
    const list = $("statsList");
    list.replaceChildren();
    schools.forEach(school => {
      const row = document.createElement("div");
      row.className = "stats-row";
      row.innerHTML = `<strong>${escapeHTML(school.name)}</strong><code>${escapeHTML(school.id)}</code><span>${Number(school.users || 0).toLocaleString("zh-CN")}</span>`;
      list.append(row);
    });
    if (!schools.length) {
      const empty = document.createElement("div");
      empty.className = "inline-empty";
      empty.textContent = "尚无学校统计数据";
      list.append(empty);
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
    const list = $("apnsChannelList");
    list.replaceChildren();
    Object.entries(config.channels || {}).sort(([a], [b]) => a.localeCompare(b)).forEach(([key, raw]) => {
      const channel = typeof raw === "object" ? (raw.channelID || raw.channelId || "") : raw;
      const [environment, schoolID] = key.split(":", 2);
      const school = state.schools.find(item => item.id === schoolID);
      const row = document.createElement("div");
      row.className = "apns-channel-row readonly";
      row.innerHTML = `<span><strong>${escapeHTML(school?.name || schoolID || key)}</strong><small>${environment === "sandbox" ? "沙盒" : "生产"} · ${escapeHTML(key)}</small></span><code title="${escapeAttr(channel)}">${escapeHTML(channel)}</code><span class="channel-status">正常</span>`;
      list.append(row);
    });
    $("channelEmpty").hidden = list.children.length > 0;
  };
  const formApns = () => ({
    keyPath: $("apnsKeyPath").value.trim(), keyID: $("apnsKeyID").value.trim(),
    teamID: $("apnsTeamID").value.trim(), bundleID: $("apnsBundleID").value.trim(),
    tickSeconds: Number($("apnsTickSeconds").value)
  });

  const saveSchool = async () => {
    const button = $("saveSchoolButton");
    try {
      const value = { id: $("schoolId").value.trim(), name: $("schoolName").value.trim(), note: $("schoolNote").value.trim(), semesterStart: "", periods: periodRows() };
      if (!value.id || !value.name) throw new Error("学校 ID 和名称不能为空");
      validatePeriods(value.periods);
      setLoading(button, true);
      const saved = await request(`/v1/schools/${encodeURIComponent(value.id)}`, { method: "POST", body: JSON.stringify(value) });
      const index = state.schools.findIndex(item => item.id === saved.id);
      if (index >= 0) state.schools[index] = saved; else state.schools.push(saved);
      state.school = saved;
      const termID = state.term?.id;
      state.term = saved.terms.find(term => term.id === termID) || saved.terms.find(term => term.current) || saved.terms[0] || emptyTerm();
      updateMetrics(); fillSchool();
      notice("学校配置已保存", "success");
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
      state.school = state.schools.find(school => school.id === state.school.id);
      state.term = structuredClone(state.school.terms.find(item => item.id === term.id));
      updateMetrics(); fillSchool();
      notice(`学期 ${state.term.id} 已保存，服务端版本 v${state.term.version}`, "success");
    } catch (error) { notice(error.message, "error"); }
    finally { setLoading(button, false); }
  };
  const saveCalendar = async () => {
    const button = $("saveCalendarButton");
    try {
      const adjustments = adjustmentRows();
      validateAdjustments(adjustments);
      setLoading(button, true);
      state.calendar = await request("/v1/admin/calendar", { method: "POST", body: JSON.stringify({ adjustments }) });
      renderCalendar();
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
      const result = await request("/v1/admin/calendar/import", { method: "POST", body: JSON.stringify({}) });
      const current = adjustmentRows();
      const seen = new Set(current.map(item => item.date));
      const added = (result.proposed || []).filter(item => !seen.has(item.date));
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
      (result.errors || []).forEach(error => notice(error, "error"));
      if (!result.errors?.length) notice(added.length ? `导入 ${added.length} 条待确认调休` : "调休已是最新", "success");
    } catch (error) { notice(error.message, "error"); }
    finally { setLoading(button, false); }
  };
  const saveApns = async () => {
    const button = $("saveApnsButton");
    setLoading(button, true);
    try {
      const saved = await request("/v1/admin/apns", { method: "POST", body: JSON.stringify(formApns()) });
      fillApns(saved);
      const errors = saved.channelSync?.errors || [];
      notice(errors.length ? `配置已保存，${errors.length} 个频道同步失败` : "APNs 配置与学校频道已保存", errors.length ? "error" : "success");
    } catch (error) { notice(error.message, "error"); }
    finally { setLoading(button, false); }
  };
  const reconcileChannels = async () => {
    const button = $("reconcileChannelsButton");
    setLoading(button, true);
    try {
      const result = await request("/v1/admin/apns/reconcile", { method: "POST", body: "{}" });
      fillApns(result.config || state.apns);
      notice(result.errors?.length ? `${result.errors.length} 个频道同步失败` : `频道同步完成，新建 ${result.created?.length || 0} 个`, result.errors?.length ? "error" : "success");
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
    $("newSchoolForm").reset(); $("newSchoolDialog").showModal();
    requestAnimationFrame(() => $("newSchoolId").focus());
  };
  const createSchool = event => {
    event.preventDefault();
    const id = $("newSchoolId").value.trim();
    const name = $("newSchoolName").value.trim();
    if (state.schools.some(item => item.id === id)) return notice("学校 ID 已存在", "error");
    const school = { id, name, note: "", periods: [{ id: 1, name: "第1节", start: "08:00", end: "08:50" }], currentTermID: null, terms: [] };
    state.schools.push(school); updateMetrics(); $("newSchoolDialog").close(); selectSchool(school.id);
    document.querySelector(".metadata-section").open = true;
    notice("学校已加入编辑区，请保存学校配置", "success");
  };
  const connect = async event => {
    event?.preventDefault();
    state.token = $("adminToken").value.trim();
    if (!state.token) return;
    const button = $("connectButton");
    setLoading(button, true); notice("正在读取服务配置…");
    try {
      const [catalogue, apns, calendar, stats] = await Promise.all([
        request("/v1/schools"), request("/v1/admin/apns"), request("/v1/admin/calendar"), request("/v1/admin/stats")
      ]);
      state.schools = catalogue.schools || [];
      state.school = null; state.term = null; state.calendar = calendar; state.stats = stats;
      $("saveApnsButton").disabled = false; $("saveCalendarButton").disabled = false;
      fillApns(apns); renderCalendar(); renderStats(); renderSchools(); updateMetrics(); updateConnectionUI(true);
      notice(`已读取 ${state.schools.length} 所学校`, "success");
    } catch (error) {
      state.token = "";
      $("saveApnsButton").disabled = true; $("saveCalendarButton").disabled = true;
      updateConnectionUI(false);
      notice(error.message === "admin token required" ? "管理员令牌无效" : error.message, "error");
    } finally { setLoading(button, false); }
  };
  const disconnect = () => {
    state.token = ""; state.schools = []; state.school = null; state.term = null;
    $("adminToken").value = ""; $("saveApnsButton").disabled = true; $("saveCalendarButton").disabled = true;
    updateConnectionUI(false); notice("管理会话已断开", "success"); $("adminToken").focus();
  };

  document.querySelectorAll(".nav-item").forEach(item => { item.onclick = () => showView(item.dataset.view); });
  $("authForm").onsubmit = connect;
  $("disconnectButton").onclick = disconnect;
  $("newSchoolButton").onclick = openNewSchool;
  $("newSchoolForm").onsubmit = createSchool;
  $("closeSchoolDialog").onclick = () => $("newSchoolDialog").close();
  $("cancelSchoolDialog").onclick = () => $("newSchoolDialog").close();
  $("newTermButton").onclick = () => { state.term = emptyTerm(); renderTerms(); fillTerm(); $("termId").focus(); };
  $("saveTermButton").onclick = saveTerm;
  $("saveSchoolButton").onclick = saveSchool;
  $("saveCalendarButton").onclick = saveCalendar;
  $("importCalendarButton").onclick = importCalendar;
  $("saveApnsButton").onclick = saveApns;
  $("reconcileChannelsButton").onclick = reconcileChannels;
  $("refreshStatsButton").onclick = refreshStats;
  $("schoolSearch").oninput = renderSchools;
  $("addSchoolPeriodButton").onclick = () => {
    state.school.periods = periodRows();
    const last = state.school.periods.at(-1);
    const start = last?.end || "08:00";
    state.school.periods.push({ id: state.school.periods.length + 1, name: `第${state.school.periods.length + 1}节`, start, end: addMinutes(start, 50) });
    renderSchoolPeriods();
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
  $("menuButton").onclick = () => document.body.classList.add("nav-open");
  $("sidebarScrim").onclick = () => document.body.classList.remove("nav-open");
  $("newSchoolDialog").addEventListener("click", event => { if (event.target === $("newSchoolDialog")) $("newSchoolDialog").close(); });
  updateConnectionUI(false);
})();
