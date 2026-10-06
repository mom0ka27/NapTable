// ---------- 格子 · 方块 ----------
const WD=["一","二","三","四","五","六","日"];
function axisCell(p,t,x,y,w,h,i){A(p,`left:${x}px;top:${y}px;width:${w}px;height:${h}px;display:flex;flex-direction:column;align-items:center;justify-content:center;gap:2px`,`<div style="font:700 14px var(--round);color:${t.ink};line-height:1">${i+1}</div><div style="font:500 8.5px/1.18 var(--round);color:${t.ink2};text-align:center">${PERIODS[i][0]}<br>${PERIODS[i][1]}</div>`)}
function adjBadge(kind,size=13){return `<span style="display:inline-flex;align-items:center;justify-content:center;width:${size}px;height:${size}px;border-radius:3.5px;background:${kind=="休"?"#E11D48":"#C2410C"};color:#fff;font:600 8.5px var(--sans)">${kind}</span>`}
function weekTiles(p,t,dark){
 const S=STY.grid,x0=7,axis=38,gap=5,sec=8,th=41,head=48,y0=148;
 const tw=(393-x0*2-axis-6*gap)/7;
 const colX=i=>x0+axis+i*(tw+gap);
 const rowY=i=>y0+head+i*(th+gap)+(i>=4?sec:0)+(i>=8?sec:0);
 A(p,`left:${x0}px;top:${y0+6}px;width:${axis}px;text-align:center;font:600 11px var(--sans);color:${t.ink2}`,"节次");
 DAYS.forEach((d,i)=>{const isT=d.today;
  A(p,`left:${colX(i)-4}px;top:${y0+2}px;width:${tw+8}px;display:flex;flex-direction:column;align-items:center;gap:3px`,`<div style="font:700 16px var(--sans);color:${isT?t.acc:t.ink}">${WD[i]}</div><div style="display:flex;align-items:center;gap:1.5px;font:600 ${d.adj?9.5:11}px var(--round);color:${isT?t.acc:t.ink2};white-space:nowrap">04.${String(d.d).padStart(2,"0")}${d.adj?adjBadge(d.adj,12):""}</div>`)});
 PERIODS.forEach((pp,i)=>axisCell(p,t,x0,rowY(i),axis,th,i));
 const occ=new Set();SCHED.forEach(([d,s0,sp])=>{for(let q=s0;q<s0+sp;q++)occ.add(d+"-"+q)});
 for(let i=0;i<7;i++)for(let r=0;r<11;r++){if(occ.has(i+"-"+(r+1)))continue;
  const hol=DAYS[i].holiday,isT=DAYS[i].today;
  A(p,`left:${colX(i)}px;top:${rowY(r)}px;width:${tw}px;height:${th}px;border-radius:9px;${hol?`border:1px dashed ${t.tline};`:`background:${isT?t.todayTile:t.tile};border:1px solid ${isT?t.todayLine:t.tline};`}`)}
 A(p,`left:${colX(0)}px;top:${rowY(2)+6}px;width:${tw}px;display:flex;justify-content:center;writing-mode:vertical-rl;font:600 12px var(--sans);color:${t.ink3};letter-spacing:7px`,"清明假期");
 const ny=rowY(NOW.period)+NOW.frac*th;
 A(p,`left:${colX(2)-2}px;top:${ny-1}px;width:${tw+4}px;height:2px;border-radius:1px;background:${t.acc}`);
 SCHED.forEach(([day,st,span,k])=>{const c=C[k],col=S.course(c.h,dark),x=colX(day),y=rowY(st-1),h=rowY(st+span-2)+th-y;
  const live=day==NOW.day&&st<=NOW.period+1&&NOW.period+1<st+span;
  A(p,`left:${x}px;top:${y}px;width:${tw}px;height:${h}px;border-radius:9px;background:${col.fill};border:1.5px solid ${live?t.acc:col.line};${live?`box-shadow:0 0 0 1.5px ${t.acc};`:""}display:flex;flex-direction:column;align-items:center;justify-content:center;padding:4px 2px;text-align:center`,`<div class="clamp" style="-webkit-line-clamp:3;font:700 12.5px/1.22 var(--sans);color:${col.text}">${c.n}</div><div class="clamp" style="-webkit-line-clamp:2;margin-top:3px;font:600 9.5px/1.2 var(--sans);color:${col.sub}">@${c.r}</div>`)});
 A(p,`left:${x0+1}px;top:${ny-8}px;width:${axis-2}px;height:16px;border-radius:8px;background:${t.accF};color:${t.on};font:600 9px var(--sans);display:flex;align-items:center;justify-content:center`,NOW.label);
}
function dayTiles(p,t,dark){
 const S=STY.grid,x0=10,axis=42,gap=5,sec=8,th=38,y0=206,tx=x0+axis+2,tw=393-tx-10;
 const rowY=i=>y0+i*(th+gap)+(i>=4?sec:0)+(i>=8?sec:0);
 PERIODS.forEach((pp,i)=>axisCell(p,t,x0,rowY(i),axis,th,i));
 const occ=new Set();TODAY.forEach(e=>{for(let q=e.p[0];q<=e.p[1];q++)occ.add(q)});
 for(let i=1;i<=11;i++)if(!occ.has(i))A(p,`left:${tx}px;top:${rowY(i-1)}px;width:${tw}px;height:${th}px;border-radius:9px;background:${t.tile};border:1px solid ${t.tline}`);
 const ny=rowY(NOW.period)+NOW.frac*th;
 A(p,`left:${tx-2}px;top:${ny-1}px;width:${tw+4}px;height:2px;background:${t.acc}`);
 TODAY.forEach(e=>{const c=C[e.k],col=S.course(c.h,dark),y=rowY(e.p[0]-1),h=rowY(e.p[1]-1)+th-y;
  const done=e.st=="done",now=e.st=="now",next=e.st=="next";
  const status=done?`<span style="font:600 11px var(--sans);color:${t.ink3}">已结束</span>`:now?`<span style="padding:2px 7px;border-radius:9px;background:${t.accF};color:${t.on};font:600 11px var(--sans);white-space:nowrap">${e.left}</span>`:next?`<span style="font:600 11px var(--sans);color:${t.acc};white-space:nowrap">${e.left}</span>`:"";
  A(p,`left:${tx}px;top:${y}px;width:${tw}px;height:${h}px;border-radius:11px;background:${done?(dark?"rgba(255,255,255,.04)":"#F6F7F9"):col.fill};border:1.5px solid ${done?t.tline:(now?t.acc:col.line)};${now?`box-shadow:0 0 0 1.5px ${t.acc};`:""}padding:0 14px;display:flex;align-items:center;gap:10px`,`<div style="flex:1;min-width:0"><div style="font:700 15.5px var(--sans);color:${done?t.ink3:col.text}">${c.n}</div><div style="margin-top:4px;font:600 11.5px var(--sans);color:${done?t.ink3:col.sub}">@${c.r} · ${c.t}</div></div>${status}`)});
 A(p,`left:${x0+2}px;top:${ny-8}px;width:${axis-4}px;height:16px;border-radius:8px;background:${t.accF};color:${t.on};font:600 9px var(--sans);display:flex;align-items:center;justify-content:center`,NOW.label);
}
function monthTiles(p,t,dark,days){
 const S=STY.grid,gap=5,tw=(393-16-6*gap)/7,th=58,y0=150;
 WD.forEach((w,i)=>A(p,`left:${8+i*(tw+gap)}px;top:${y0}px;width:${tw}px;text-align:center;font:700 13px var(--sans);color:${t.ink}`,w));
 days.forEach((d,i)=>{const r=Math.floor(i/7),c=i%7,x=8+c*(tw+gap),y=y0+24+r*(th+gap);
  const red=dark?"#FF6B81":"#D61F45";
  const fill=d.today?t.todayTile:(d.off&&d.inMonth?(dark?"rgba(225,29,72,.10)":"#FFF3F4"):t.tile);
  const cell=A(p,`left:${x}px;top:${y}px;width:${tw}px;height:${th}px;border-radius:10px;background:${fill};border:${d.today?1.5:1}px solid ${d.today?t.acc:t.tline};opacity:${d.inMonth?1:.45};display:flex;flex-direction:column;align-items:center;justify-content:center;gap:1px`);
  cell.innerHTML=`<div style="font:700 16px var(--round);color:${d.today?t.acc:(d.off?red:t.ink)}">${d.d}</div><div style="font:${d.fest?600:500} 9px var(--sans);color:${d.fest?red:(d.today?t.acc:t.ink2)}">${d.today?"三月初一":d.lunar}</div>`;
  const dots=E("div","display:flex;gap:2.5px;height:6px;align-items:center;margin-top:2px");
  d.courses.slice(0,4).forEach(k=>dots.appendChild(E("div",`width:4px;height:4px;border-radius:50%;background:${S.course(C[k].h,dark).bar}`)));
  cell.appendChild(dots);
  if(d.off||d.work)A(cell,`right:3px;top:3px;display:flex`,adjBadge(d.off?"休":"班",13));
 });
 const ys=y0+24+5*(th+gap)+14;
 A(p,`left:14px;top:${ys}px`,`<div style="font:700 16px var(--sans);color:${t.ink}">4月7日 周三</div><div style="margin-top:2px;font:500 12px var(--sans);color:${t.ink2}">第 7 周 · 三月初一 · 4 门课</div>`);
 TODAY.slice(0,3).forEach((e,i)=>{const c=C[e.k],col=S.course(c.h,dark),y=ys+48+i*50;
  A(p,`left:8px;top:${y}px;width:377px;height:44px;border-radius:11px;background:${col.fill};border:1.5px solid ${col.line};display:flex;align-items:center;gap:10px;padding:0 14px`,`<div style="font:700 12px var(--round);color:${col.sub};width:40px">${PERIODS[e.p[0]-1][0]}</div><div style="flex:1;font:700 14px var(--sans);color:${col.text};white-space:nowrap;overflow:hidden">${c.n}</div><div style="font:600 12px var(--sans);color:${col.sub}">@${c.r}</div>`)});
}
// ---------- shared date strip ----------
function dateStrip(p,id,t,dark,y){
 const x0=12,w=(393-24)/7;
 DAYS.forEach((d,i)=>{
  const x=x0+i*w,isT=d.today;
  let css=`left:${x}px;top:${y}px;width:${w}px;height:56px;display:flex;flex-direction:column;align-items:center;justify-content:center;gap:2px;`,html;
  if(id=="modern"){
   if(isT)css+=`background:${dark?"rgba(237,121,109,.16)":"rgba(226,111,99,.11)"};border-radius:14px;`;
   html=`<div style="font:600 17px var(--round);color:${isT?t.acc:(d.holiday?t.ink3:t.ink)}">${d.d}</div><div style="font:500 11px var(--sans);color:${isT?t.acc:t.ink2}">${isT?"今天":d.w}</div>`;
  } else if(id=="grid"){
   css+=`width:${w-5}px;margin-left:2.5px;border-radius:11px;background:${isT?t.todayTile:t.tile};border:${isT?1.5:1}px solid ${isT?t.acc:t.tline};`;
   html=`<div style="font:700 15px var(--sans);color:${isT?t.acc:t.ink}">${WD[i]}</div><div style="font:600 10.5px var(--round);color:${isT?t.acc:t.ink2}">04.${String(d.d).padStart(2,"0")}</div>`;
  } else if(id=="table"){
   css+=`border:.5px solid ${t.pline};margin-left:-.5px;background:${isT?t.accF:t.panel};`;
   const adjc=d.adj=="休"?(dark?"#FF6B81":"#D61F45"):(dark?"#FF9A5C":"#C2410C");
   html=`<div style="font:600 12px var(--sans);color:${isT?t.on:t.ink}">${isT?"今天":d.w}</div><div style="font:500 10.5px var(--mono);color:${isT?t.on:t.ink2}">4/${d.d}${d.adj?`<b style="font:700 10px var(--sans);color:${adjc};margin-left:2px">${d.adj}</b>`:""}</div>`;
  } else if(id=="paper"){
   html=`<div style="font:400 18px var(--serif);color:${isT?t.acc:(d.holiday?t.ink3:t.ink)};width:30px;height:30px;border-radius:50%;display:flex;align-items:center;justify-content:center;${isT?`border:1.2px solid ${t.acc};`:""}">${d.d}</div><div style="font:400 11px var(--song);color:${isT?t.acc:t.ink2}">${isT?"今日":d.w}</div>`;
  } else {
   html=`<div style="font:700 12.5px var(--sans);color:${t.ink}">${isT?"今天":d.w}</div><div style="font:500 11px var(--mono);color:${t.ink2}">${String(d.d).padStart(2,"0")}</div>`+(isT?`<div style="position:absolute;left:9px;right:9px;bottom:0;height:3px;background:${t.acc}"></div>`:"");
  }
  const cell=A(p,css,html);
  if(d.adj&&id!="table"){
   const off=d.adj=="休";let bc;
   if(id=="modern"||id=="grid")bc=`width:14px;height:14px;border-radius:4px;background:${off?"#E11D48":"#C2410C"};color:#fff;font:600 9px var(--sans);`;
   if(id=="paper")bc=off?`width:14px;height:14px;border-radius:2px;background:${t.accF};color:${t.on};font:700 9.5px var(--song);`:`width:14px;height:14px;border-radius:2px;border:1px solid ${t.ink2};color:${t.ink2};font:700 9.5px var(--song);`;
   if(id=="board")bc=off?`width:14px;height:14px;background:${t.ink};color:${t.canvas};font:700 9px var(--sans);`:`width:14px;height:14px;border:1.2px solid ${t.ink};color:${t.ink};font:700 9px var(--sans);`;
   A(cell,`right:4px;top:3px;display:flex;align-items:center;justify-content:center;${bc}`,d.adj);
  }
 });
}
// ---------- day views ----------
function dayModern(p,t,dark){
 const S=STY.modern,y0=214,cardH=100,gap=14;let y=y0;const rows=[];
 TODAY.forEach((e,i)=>{rows.push({e,y});y+=cardH+gap;if(i==1)y+=26});
 A(p,`left:80px;top:${y0+12}px;width:1px;height:${rows[rows.length-1].y-y0}px;background:${t.rule}`);
 rows.forEach(({e,y},i)=>{
  const c=C[e.k],col=S.course(c.h,dark),st=PERIODS[e.p[0]-1][0],en=PERIODS[e.p[1]-1][1];
  const done=e.st=="done",now=e.st=="now",next=e.st=="next";
  A(p,`left:12px;top:${y+3}px;width:58px;text-align:right`,`<div style="font:600 16px var(--sans);font-variant-numeric:tabular-nums;color:${done?t.ink3:(now?t.acc:t.ink)}">${st}</div><div style="font:500 12px var(--sans);font-variant-numeric:tabular-nums;color:${done?t.ink3:t.ink2};margin-top:2px">${en}</div>`+(now?`<div style="display:inline-block;margin-top:7px;padding:2px 6px;border-radius:9px;background:${t.accF};color:${t.on};font:600 10px var(--sans);white-space:nowrap">${e.left}</div>`:"")+(next?`<div style="margin-top:7px;font:600 10px/1.3 var(--sans);color:${t.acc}">下一节</div>`:""));
  const ny=y+13;
  if(now)A(p,`left:74px;top:${ny-6}px;width:13px;height:13px;border-radius:50%;background:${t.acc};box-shadow:0 0 0 4px ${dark?"rgba(237,121,109,.22)":"rgba(226,111,99,.18)"}`);
  else if(next)A(p,`left:75px;top:${ny-5}px;width:11px;height:11px;border-radius:50%;border:2px solid ${t.acc};background:${t.canvas}`);
  else A(p,`left:77px;top:${ny-3}px;width:7px;height:7px;border-radius:50%;background:${t.ink3}`);
  const fill=done?(dark?"rgba(255,255,255,.05)":"oklch(0.955 0.004 260)"):col.fill;
  A(p,`left:96px;top:${y}px;width:281px;height:${cardH}px;border-radius:20px;background:${fill};border:1px solid ${done?(dark?"rgba(255,255,255,.06)":"rgba(0,0,0,.05)"):col.line};box-shadow:${done?"none":`inset 0 0 0 .6px rgba(255,255,255,${dark?.10:.62}),0 3px 7px rgba(0,0,0,${dark?.18:.07})`};padding:15px 18px`,
   `<div style="font:600 17px var(--sans);color:${done?t.ink2:t.ink}">${c.n}</div><div style="margin-top:6px;font:400 13px var(--sans);color:${t.ink2}">@${c.r}</div><div style="margin-top:6px;font:500 11px var(--sans);color:${done?t.ink3:col.text}">第 ${e.p[0]}–${e.p[1]} 节 · ${c.t}</div>`+(next?`<div style="position:absolute;right:16px;top:17px;font:600 11px var(--sans);color:${t.acc}">${e.left}</div>`:"")+(done?`<div style="position:absolute;right:14px;top:12px;width:22px;height:22px;border-radius:50%;background:${dark?"rgba(255,255,255,.12)":"#E5E5EA"};display:flex;align-items:center;justify-content:center;transform:rotate(10deg)">${ic.check(t.ink2)}</div>`:""));
  if(i==1)A(p,`left:96px;top:${y+cardH+gap+3}px;width:281px;text-align:center;font:500 12px var(--sans);color:${t.ink3}`,"午休 · 2 小时 20 分");
 });
}
function dayGrid(p,t,dark){
 const S=STY.table,x0=8,w=377,y0=204,rh=43,hh=30,cols=[34,72,168,103];
 const T=A(p,`left:${x0}px;top:${y0}px;width:${w}px;height:${hh+rh*11}px;background:${t.panel};border:1px solid ${t.pline};border-radius:10px;overflow:hidden`);
 A(T,`left:0;top:0;width:${w}px;height:${hh}px;background:${t.head};border-bottom:1px solid ${t.pline}`);
 let cx=0;["节","时间","课程","教室"].forEach((hd,i)=>{A(T,`left:${cx}px;top:0;width:${cols[i]}px;height:${hh}px;display:flex;align-items:center;${i<2?"justify-content:center;":"padding-left:9px;"}font:600 11px var(--sans);color:${t.ink2}`,hd);cx+=cols[i]});
 A(T,`left:0;top:${hh}px;width:${cols[0]}px;height:${rh*11}px;background:${t.head}`);
 for(let i=0;i<11;i++){const y=hh+i*rh;
  if(i>0)A(T,`left:0;top:${y}px;width:${w}px;height:0;border-top:${(i==4||i==8)?"1px solid "+t.pline:".5px solid "+t.rule}`);
  A(T,`left:0;top:${y}px;width:${cols[0]}px;height:${rh}px;display:flex;align-items:center;justify-content:center;font:700 12.5px var(--sans);color:${t.ink}`,i+1);
  A(T,`left:${cols[0]}px;top:${y}px;width:${cols[1]}px;height:${rh}px;display:flex;flex-direction:column;align-items:center;justify-content:center;font:500 10px/1.35 var(--mono);color:${t.ink2}`,`${PERIODS[i][0]}<span style="opacity:.75">${PERIODS[i][1]}</span>`);
 }
 const occ=new Set();TODAY.forEach(e=>{for(let q=e.p[0];q<=e.p[1];q++)occ.add(q)});
 for(let i=1;i<=11;i++)if(!occ.has(i))A(T,`left:${cols[0]+cols[1]+10}px;top:${hh+(i-1)*rh}px;height:${rh}px;display:flex;align-items:center;font:400 12px var(--sans);color:${t.ink3}`,"—");
 TODAY.forEach(e=>{
  const c=C[e.k],col=S.course(c.h,dark),y=hh+(e.p[0]-1)*rh,h=(e.p[1]-e.p[0]+1)*rh,x=cols[0]+cols[1];
  const done=e.st=="done",now=e.st=="now",next=e.st=="next";
  A(T,`left:${x+.5}px;top:${y+.5}px;width:${cols[2]+cols[3]-.5}px;height:${h-.5}px;background:${done?(dark?"#1D1F23":"#F4F5F7"):col.fill};border-left:3px solid ${done?t.ink3:col.bar}`);
  A(T,`left:${x+11}px;top:${y+9}px;width:${cols[2]-16}px`,`<div style="font:600 13.5px/1.25 var(--sans);color:${done?t.ink3:col.text}">${c.n}</div><div style="margin-top:4px;font:500 10.5px var(--sans);color:${done?t.ink3:col.sub}">${c.t}</div>`);
  A(T,`left:${x+cols[2]}px;top:${y+9}px;width:${cols[3]}px;padding-left:9px;font:500 11.5px var(--sans);color:${done?t.ink3:col.sub}`,c.r);
  const tag=done?["已结束",t.ink3,"transparent",`1px solid ${t.ink3}`]:now?[e.left,t.on,t.accF,"1px solid "+t.accF]:next?["下一节",t.acc,"transparent",`1px solid ${t.acc}`]:null;
  if(tag)A(T,`left:${x+cols[2]+9}px;top:${y+h-25}px;padding:1px 5px;font:600 10px var(--sans);color:${tag[1]};background:${tag[2]};border:${tag[3]};white-space:nowrap`,tag[0]);
  if(now)A(T,`left:0;top:${y}px;width:3px;height:${h}px;background:${t.accF}`);
 });
 const ny=hh+NOW.period*rh+NOW.frac*rh;
 A(T,`left:${cols[0]}px;top:${ny-1}px;width:${w-cols[0]}px;height:2px;background:${t.acc}`);
 A(T,`left:0;top:${ny-8}px;width:${cols[0]}px;height:16px;background:${t.accF};color:${t.on};font:600 9px var(--mono);display:flex;align-items:center;justify-content:center`,NOW.label);
}
function dayPaper(p,t,dark){
 const S=STY.paper;
 A(p,`left:24px;top:192px;display:flex;align-items:baseline;gap:10px`,`<span style="font:700 26px var(--song);color:${t.ink}">四月七日</span><span style="font:400 15px var(--song);color:${t.ink2}">星期三</span>`);
 A(p,`left:24px;top:230px;font:400 12.5px var(--song);color:${t.ink2};letter-spacing:.5px`,`三月初一 · 清明后二日 · 第七周`);
 const sheet=A(p,`left:12px;top:262px;width:369px;height:446px;background:${t.panel};border:1.6px solid ${t.pline}`);
 A(sheet,`left:2.5px;top:2.5px;right:2.5px;bottom:2.5px;border:.6px solid ${t.pline};opacity:.55`);
 let y=16;
 [["上午",[0,1]],["下午",[2]],["晚上",[3]]].forEach(([lbl,idx])=>{
  A(sheet,`left:18px;top:${y}px;display:flex;align-items:center;gap:8px;width:331px`,`<span style="font:700 12px var(--song);color:${t.ink2};letter-spacing:3px">${lbl}</span><span style="flex:1;border-top:.6px solid ${t.rule2}"></span>`);
  y+=26;
  idx.forEach(ii=>{
   const e=TODAY[ii],c=C[e.k],col=S.course(c.h,dark),st=PERIODS[e.p[0]-1][0],en=PERIODS[e.p[1]-1][1];
   const done=e.st=="done",now=e.st=="now",next=e.st=="next";
   const row=A(sheet,`left:18px;top:${y}px;width:331px;height:74px`);
   A(row,`left:0;top:3px;width:52px`,`<div style="font:400 19px var(--serif);color:${done?t.ink3:(now?t.acc:t.ink)}">${st}</div><div style="font:400 12px var(--serif);color:${done?t.ink3:t.ink2};margin-top:3px">${en}</div>`);
   A(row,`left:60px;top:6px;width:2px;height:50px;background:${col.bar};opacity:${done?.35:1}`);
   A(row,`left:72px;top:1px;width:259px`,`<div style="display:flex;align-items:baseline;gap:6px"><span style="font:700 17px var(--song);color:${done?t.ink3:t.ink};white-space:nowrap">${c.n}</span><span style="flex:1;border-bottom:1.2px dotted ${t.rule2};transform:translateY(-4px)"></span><span style="font:400 12px var(--song);color:${t.ink2};white-space:nowrap">第${CN[e.p[0]-1]}、${CN[e.p[1]-1]}节</span></div><div style="margin-top:5px;font:400 12px var(--sans);color:${done?t.ink3:t.ink2}">${c.r} · ${c.t}${done?" · 已毕":""}</div>`+(now?`<div style="margin-top:7px;display:inline-flex;align-items:center;gap:7px;font:400 12px var(--song);color:${t.acc}"><span style="padding:1px 5px;background:${t.accF};color:${t.on};font:700 11px var(--song)">正在上</span>${e.left}</div>`:"")+(next?`<div style="margin-top:7px;font:400 12px var(--song);color:${t.acc}">下一节 · ${e.left}</div>`:""));
   y+=86;
  });
 });
}
function dayBoard(p,t,dark){
 const S=STY.board;
 A(p,`left:20px;top:184px;display:flex;align-items:baseline;gap:8px;width:353px`,`<span style="font:700 12px var(--sans);color:${t.ink2};letter-spacing:2px">现在</span><span style="font:700 14px var(--mono);color:${t.ink}">11:05</span><span style="flex:1"></span><span style="font:500 12px var(--sans);color:${t.ink2}">今天还有 3 节</span>`);
 const e=TODAY[1],c=C[e.k];
 const blk=A(p,`left:12px;top:208px;width:369px;height:160px;background:${dark?"#1C1C1E":"#0B0B0C"};color:#fff;padding:16px 18px`);
 blk.innerHTML=`<div style="display:flex;justify-content:space-between;align-items:center"><span style="font:700 11px var(--sans);letter-spacing:2px;color:#A1A1A6">正在上 · 第 3–4 节</span><span style="font:700 12.5px var(--sans);color:#ED796D">${e.left}</span></div><div style="margin-top:10px;font:600 30px var(--mono);letter-spacing:-.5px">10:00<span style="color:#6C6C70"> – </span>11:40</div><div style="margin-top:6px;font:700 21px var(--sans)">${c.n}</div><div style="margin-top:5px;font:500 13px var(--mono);color:#A1A1A6">${c.r} · ${c.t}</div><div style="position:absolute;left:18px;right:18px;bottom:14px;height:3px;background:#3A3A3C"><div style="width:22%;height:3px;background:#ED796D"></div></div>`;
 A(p,`left:20px;top:388px;font:700 11px var(--sans);letter-spacing:2px;color:${t.ink2}`,"接下来");
 [TODAY[2],TODAY[3]].forEach((e,i)=>{
  const c=C[e.k],col=S.course(c.h,dark),y=410+i*76;
  A(p,`left:12px;top:${y}px;width:369px;height:0;border-top:${i==0?"1.6px solid "+t.pline:".5px solid "+t.rule}`);
  A(p,`left:20px;top:${y+13}px;font:600 23px var(--mono);color:${t.ink}`,PERIODS[e.p[0]-1][0]);
  A(p,`left:116px;top:${y+12}px;width:170px`,`<div style="font:700 16px var(--sans);color:${t.ink};white-space:nowrap"><span style="display:inline-block;width:8px;height:8px;margin-right:6px;vertical-align:2px;background:${col.dot}"></span>${c.n}</div><div style="margin-top:5px;font:500 12px var(--mono);color:${t.ink2}">${c.r} · 第${e.p[0]}–${e.p[1]}节</div>`);
  A(p,`right:20px;top:${y+17}px;font:600 12px var(--sans);color:${e.st=="next"?t.acc:t.ink2};text-align:right;white-space:nowrap`,e.st=="next"?e.left:"晚上");
 });
 const yd=410+2*76;
 A(p,`left:12px;top:${yd}px;width:369px;height:0;border-top:.5px solid ${t.rule}`);
 A(p,`left:20px;top:${yd+16}px;font:700 11px var(--sans);letter-spacing:2px;color:${t.ink2}`,"已结束");
 const c0=C[TODAY[0].k];
 A(p,`left:20px;top:${yd+38}px;width:353px;display:flex;gap:14px;align-items:baseline`,`<span style="font:500 15px var(--mono);color:${t.ink3}">08:00</span><span style="font:600 14px var(--sans);color:${t.ink3}">${c0.n}</span><span style="flex:1"></span><span style="font:500 12px var(--mono);color:${t.ink3}">${c0.r}</span>`);
}
function dayPhone(id,dark){
 const S=STY[id],t=dark?S.dark:S.light;
 const p=E("div",`--canvas:${t.canvas};--ink:${t.ink}`,null,"phone");
 statusBar(p,t,dark);topBar(p,id,t,dark,"day");dateStrip(p,id,t,dark,108);
 if(id=="modern"){A(p,`left:20px;top:180px;font:500 13px var(--sans);color:${t.ink2}`,"4月7日 周三 · 第 7 周 · 4 节课");dayModern(p,t,dark)}
 if(id=="grid"){A(p,`left:14px;top:180px;font:500 13px var(--sans);color:${t.ink2}`,"4月7日 周三 · 第 7 周 · 4 门课");dayTiles(p,t,dark)}
 if(id=="table"){A(p,`left:12px;top:178px;font:500 13px var(--sans);color:${t.ink2}`,"4月7日 周三 · 第 7 周 · 4 门 8 节");dayGrid(p,t,dark)}
 if(id=="paper")dayPaper(p,t,dark);
 if(id=="board")dayBoard(p,t,dark);
 tabBar(p,id,t,dark);homeBar(p,t);return p;
}
// ---------- month views ----------
const LUNAR={"3/29":"廿二","3/30":"廿三","3/31":"廿四","4/1":"廿五","4/2":"廿六","4/3":"廿七","4/4":"廿八","4/5":"清明","4/6":"三十","4/7":"三月","4/8":"初二","4/9":"初三","4/10":"初四","4/11":"初五","4/12":"初六","4/13":"初七","4/14":"初八","4/15":"初九","4/16":"初十","4/17":"十一","4/18":"十二","4/19":"十三","4/20":"十四","4/21":"十五","4/22":"十六","4/23":"十七","4/24":"十八","4/25":"十九","4/26":"二十","4/27":"廿一","4/28":"廿二","4/29":"廿三","4/30":"廿四","5/1":"劳动节","5/2":"廿六"};
const PAT={0:["math","pe"],1:["la","en","prog"],2:["math","hist","phy","pol"],3:["ds","en","lab"],4:["la","prog","eth"],5:[],6:[]};
const OFF=new Set(["4/3","4/4","4/5","5/1","5/2"]),WORK=new Set(["4/11"]);
function monthDays(){
 const out=[];let m=3,d=29;const len={3:31,4:30,5:31};
 for(let i=0;i<35;i++){const key=`${m}/${d}`,wd=i%7;
  const courses=OFF.has(key)?[]:WORK.has(key)?PAT[0]:PAT[wd];
  out.push({key,m,d,wd,inMonth:m==4,lunar:LUNAR[key],off:OFF.has(key),work:WORK.has(key),fest:key=="4/5"||key=="5/1",today:key=="4/7",courses});
  d++;if(d>len[m]){d=1;m++}}
 return out;
}
function monthRow(p,id,t){
 const y=110;
 const v={modern:["600 17px var(--sans)","2027 年 4 月",t.ink,"丁未年 · 三月"],grid:["600 17px var(--sans)","2027 年 4 月",t.ink,"丁未年 · 三月"],table:["600 17px var(--sans)","2027 年 4 月",t.ink,"第 6–10 周"],paper:["700 18px var(--song)","二〇二七年 · 四月",t.ink,"丁未年 三月"],board:["700 17px var(--mono)","2027.04",t.ink,"W6–W10"]}[id];
 A(p,`left:20px;top:${y}px;display:flex;align-items:baseline;gap:10px;white-space:nowrap`,`<span style="font:${v[0]};color:${v[2]}">${v[1]}</span><span style="font:${id=="paper"?"400 13px var(--song)":id=="board"?"500 12px var(--mono)":"400 13px var(--sans)"};color:${t.ink2}">${v[3]}</span>`);
 A(p,`right:22px;top:${y+2}px;display:flex;gap:22px`,ic.chev(t.ink2,'l',17,2.2)+ic.chev(t.ink2,'r',17,2.2));
}
function monthPhone(id,dark){
 const S=STY[id],t=dark?S.dark:S.light;
 const p=E("div",`--canvas:${t.canvas};--ink:${t.ink}`,null,"phone");
 statusBar(p,t,dark);topBar(p,id,t,dark,"month");monthRow(p,id,t);
 const days=monthDays(),W=["一","二","三","四","五","六","日"];
 if(id=="modern"){
  const P=A(p,`left:8px;top:150px;width:377px;height:600px;border-radius:20px;background:${t.panel};border:1px solid ${t.pline}`);
  const cw=(377-20)/7;
  W.forEach((w,i)=>A(P,`left:${10+i*cw}px;top:14px;width:${cw}px;text-align:center;font:500 11px var(--sans);color:${i>=5?t.ink3:t.ink2}`,w));
  days.forEach((d,i)=>{const r=Math.floor(i/7),c=i%7,x=10+c*cw,y=40+r*62;
   const cell=A(P,`left:${x}px;top:${y}px;width:${cw}px;height:60px;display:flex;flex-direction:column;align-items:center;gap:2px;opacity:${d.inMonth?1:.45}`);
   const num=A(cell,`position:relative;width:32px;height:32px;border-radius:50%;display:flex;align-items:center;justify-content:center;font:${d.today?700:500} 18px var(--round);${d.today?`background:${t.accF};color:${t.on};`:`color:${d.off?(dark?"#FF6B81":"#D61F45"):(c>=5?t.ink2:t.ink)};`}`,String(d.d));
   num.style.position="relative";
   cell.appendChild(E("div",`font:${d.fest?600:400} 10px var(--sans);color:${d.fest?(dark?"#FF6B81":"#D61F45"):t.ink2}`,d.lunar));
   const dots=E("div","display:flex;gap:3px;height:6px;align-items:center");
   d.courses.slice(0,3).forEach(k=>dots.appendChild(E("div",`width:4px;height:4px;border-radius:50%;background:oklch(${dark?0.75:0.62} 0.13 ${C[k].h})`)));
   if(d.courses.length>3)dots.appendChild(E("div",`width:3px;height:3px;border-radius:50%;background:${t.ink3}`));
   cell.appendChild(dots);
   if(d.off||d.work)A(cell,`left:${cw/2+9}px;top:-2px;width:13px;height:13px;border-radius:4px;background:${d.off?"#E11D48":"#C2410C"};color:#fff;font:600 8.5px var(--sans);display:flex;align-items:center;justify-content:center`,d.off?"休":"班");
  });
  A(P,`left:16px;top:356px;width:345px;height:0;border-top:.5px solid ${t.rule}`);
  A(P,`left:18px;top:372px`,`<div style="font:600 16px var(--sans);color:${t.ink}">4月7日 周三</div><div style="margin-top:3px;font:400 12.5px var(--sans);color:${t.ink2}">第 7 周 · 三月初一 · 4 节课</div>`);
  TODAY.slice(0,3).forEach((e,i)=>{const c=C[e.k],col=S.course(c.h,dark),y=430+i*52;
   A(P,`left:14px;top:${y}px;width:349px;height:44px;border-radius:12px;background:${col.fill};display:flex;align-items:center;gap:10px;padding:0 12px`,`<div style="width:3px;height:24px;border-radius:2px;background:oklch(${dark?0.75:0.6} 0.12 ${c.h})"></div><div style="flex:1;font:600 14px var(--sans);color:${t.ink};white-space:nowrap;overflow:hidden">${c.n}</div><div style="font:500 12px var(--sans);font-variant-numeric:tabular-nums;color:${t.ink2}">${PERIODS[e.p[0]-1][0]}</div><div style="width:64px;text-align:right;font:400 12px var(--sans);color:${t.ink2}">${c.r}</div>`);
  });
 }
 if(id=="grid")monthTiles(p,t,dark,days);
 if(id=="table"){
  const cw=377/7,rh=100,hh=28;
  const P=A(p,`left:8px;top:150px;width:377px;height:${hh+rh*5}px;border-radius:10px;background:${t.panel};border:1px solid ${t.pline};overflow:hidden`);
  A(P,`left:0;top:0;width:377px;height:${hh}px;background:${t.head};border-bottom:1px solid ${t.pline}`);
  W.forEach((w,i)=>A(P,`left:${i*cw}px;top:0;width:${cw}px;height:${hh}px;display:flex;align-items:center;justify-content:center;font:600 11px var(--sans);color:${i>=5?t.ink3:t.ink2}`,w));
  [5,6].forEach(i=>A(P,`left:${i*cw}px;top:${hh}px;width:${cw}px;height:${rh*5}px;background:${t.wkend}`));
  days.forEach((d,i)=>{const r=Math.floor(i/7),c=i%7,x=c*cw,y=hh+r*rh;
   if(d.off)A(P,`left:${x}px;top:${y}px;width:${cw}px;height:${rh}px;background:repeating-linear-gradient(135deg,transparent 0 6px,${dark?"rgba(255,255,255,.05)":"rgba(20,22,26,.045)"} 6px 7px)`);
   if(d.today)A(P,`left:${x}px;top:${y}px;width:${cw}px;height:${rh}px;background:${t.today}`);
   const cell=A(P,`left:${x}px;top:${y}px;width:${cw}px;height:${rh}px;opacity:${d.inMonth?1:.42}`);
   A(cell,`left:4px;top:4px;min-width:20px;height:18px;padding:0 3px;display:flex;align-items:center;justify-content:center;font:${d.today?700:600} 12.5px var(--sans);${d.today?`background:${t.accF};color:${t.on};border-radius:4px`:`color:${d.off?(dark?"#FF6B81":"#D61F45"):(c>=5?t.ink2:t.ink)}`}`,String(d.d));
   A(cell,`right:4px;top:7px;font:${d.fest?600:400} 8.5px var(--sans);color:${d.fest?(dark?"#FF6B81":"#D61F45"):t.ink3}`,(d.off?"休 ":"")+(d.work?"班 ":"")+(d.lunar.length>2?d.lunar.slice(0,2):d.lunar));
   d.courses.slice(0,3).forEach((k,j)=>{const col=S.course(C[k].h,dark);
    A(cell,`left:3px;top:${27+j*17}px;width:${cw-6}px;height:15px;background:${col.fill};border-left:2px solid ${col.bar};padding-left:3px;font:600 9px/15px var(--sans);color:${col.text};white-space:nowrap;overflow:hidden`,C[k].s)});
   if(d.courses.length>3)A(cell,`left:5px;top:${27+3*17}px;font:600 9px var(--sans);color:${t.ink2}`,`+${d.courses.length-3}`);
  });
  for(let r=1;r<5;r++)A(P,`left:0;top:${hh+r*rh}px;width:377px;height:0;border-top:.5px solid ${t.rule}`);
  for(let c=1;c<7;c++)A(P,`left:${c*cw}px;top:0;width:0;height:${hh+rh*5}px;border-left:.5px solid ${t.rule}`);
  A(p,`left:16px;top:${150+hh+rh*5+16}px;width:361px;display:flex;align-items:center;gap:8px;font:500 12.5px var(--sans);color:${t.ink2}`,`<span style="padding:1px 6px;background:${t.accF};color:${t.on};font:600 11px var(--sans)">今天</span>4 门课 · 下一节 14:00 大学物理 · 教4-203`);
 }
 if(id=="paper"){
  const P=A(p,`left:10px;top:150px;width:373px;height:600px;background:${t.panel};border:1.6px solid ${t.pline}`);
  A(P,`left:2.5px;top:2.5px;right:2.5px;bottom:2.5px;border:.6px solid ${t.pline};opacity:.55`);
  const cw=(373-24)/7;
  W.forEach((w,i)=>A(P,`left:${12+i*cw}px;top:16px;width:${cw}px;text-align:center;font:400 12px var(--song);color:${i>=5?t.acc:t.ink2}`,w));
  A(P,`left:12px;top:40px;width:349px;height:0;border-top:.8px solid ${t.rule2}`);
  days.forEach((d,i)=>{const r=Math.floor(i/7),c=i%7,x=12+c*cw,y=50+r*62;
   const cell=A(P,`left:${x}px;top:${y}px;width:${cw}px;height:60px;display:flex;flex-direction:column;align-items:center;gap:1px;opacity:${d.inMonth?1:.4}`);
   A(cell,`position:relative;width:32px;height:32px;border-radius:50%;display:flex;align-items:center;justify-content:center;font:400 19px var(--serif);${d.today?`border:1.3px solid ${t.acc};color:${t.acc};`:`color:${d.off?t.acc:(c>=5?t.ink2:t.ink)};`}`,String(d.d)).style.position="relative";
   cell.appendChild(E("div",`font:400 10px var(--song);color:${d.fest||d.today?t.acc:t.ink2}`,d.today?"三月初一":d.lunar));
   const n=d.courses.length;
   cell.appendChild(E("div",`margin-top:3px;width:${n?4+n*4:0}px;height:1.6px;border-radius:1px;background:${t.ink3}`));
   if(d.off||d.work)A(cell,`left:${cw/2+8}px;top:-1px;width:13px;height:13px;border-radius:2px;display:flex;align-items:center;justify-content:center;font:700 8.5px var(--song);${d.off?`background:${t.accF};color:${t.on}`:`border:1px solid ${t.ink2};color:${t.ink2}`}`,d.off?"休":"班");
  });
  A(P,`left:18px;top:368px;width:337px;display:flex;align-items:center;gap:8px`,`<span style="font:700 15px var(--song);color:${t.ink}">四月七日</span><span style="font:400 12px var(--song);color:${t.ink2}">三月初一 · 星期三</span><span style="flex:1;border-top:.6px solid ${t.rule2}"></span>`);
  TODAY.forEach((e,i)=>{const c=C[e.k],col=S.course(c.h,dark),y=404+i*46,done=e.st=="done",now=e.st=="now";
   A(P,`left:18px;top:${y}px;width:337px;display:flex;align-items:baseline;gap:10px`,`<span style="font:400 15px var(--serif);width:44px;color:${done?t.ink3:(now?t.acc:t.ink)}">${PERIODS[e.p[0]-1][0]}</span><span style="width:2px;height:16px;background:${col.bar};opacity:${done?.35:1};align-self:center"></span><span style="font:700 15px var(--song);color:${done?t.ink3:t.ink};white-space:nowrap">${c.n}</span><span style="flex:1;border-bottom:1.2px dotted ${t.rule2};transform:translateY(-3px)"></span><span style="font:400 11.5px var(--sans);color:${t.ink2};white-space:nowrap">${c.r}</span>`)});
 }
 if(id=="board"){
  const cw=393/7,rh=66,y0=150;
  W.forEach((w,i)=>A(p,`left:${i*cw}px;top:${y0}px;width:${cw}px;height:26px;display:flex;align-items:center;justify-content:center;font:700 11.5px var(--sans);color:${i>=5?t.ink3:t.ink}`,w));
  A(p,`left:0;top:${y0+26}px;width:393px;height:0;border-top:1.6px solid ${t.pline}`);
  days.forEach((d,i)=>{const r=Math.floor(i/7),c=i%7,x=c*cw,y=y0+28+r*rh;
   if(r>0&&c==0)A(p,`left:0;top:${y}px;width:393px;height:0;border-top:.5px solid ${t.rule}`);
   const inv=d.today;
   const cell=A(p,`left:${x+3}px;top:${y+4}px;width:${cw-6}px;height:${rh-8}px;display:flex;flex-direction:column;align-items:center;justify-content:center;gap:3px;opacity:${d.inMonth?1:.4};${inv?`background:${t.ink};`:""}`);
   cell.innerHTML=`<div style="font:700 17px var(--mono);color:${inv?t.canvas:(c>=5?t.ink2:t.ink)}">${String(d.d).padStart(2,"0")}</div><div style="font:600 9.5px var(--mono);color:${inv?t.canvas:t.ink2};opacity:${inv?.8:1}">${d.off?"":d.courses.length?d.courses.length+"节":"—"}</div>`;
   if(d.off||d.work)A(cell,`left:auto;right:2px;top:2px;width:13px;height:13px;display:flex;align-items:center;justify-content:center;font:700 8.5px var(--sans);${d.off?`background:${t.ink};color:${t.canvas}`:`border:1.1px solid ${t.ink};color:${t.ink}`}`,d.off?"休":"班");
   if(d.off&&d.inMonth)A(cell,`left:0;right:0;top:${rh/2+4}px;text-align:center;font:600 9px var(--sans);color:${t.ink3}`,d.fest?"清明":"停课");
  });
  const yb=y0+28+5*rh+14;
  A(p,`left:12px;top:${yb}px;width:369px;height:0;border-top:1.6px solid ${t.pline}`);
  A(p,`left:16px;top:${yb+10}px;font:700 11px var(--sans);letter-spacing:2px;color:${t.ink2}`,"今天 · 04.07");
  TODAY.forEach((e,i)=>{const c=C[e.k],y=yb+32+i*30,done=e.st=="done",now=e.st=="now";
   A(p,`left:16px;top:${y}px;width:361px;display:flex;align-items:baseline;gap:12px`,`<span style="font:600 14px var(--mono);color:${done?t.ink3:t.ink}">${PERIODS[e.p[0]-1][0]}</span><span style="font:700 13.5px var(--sans);color:${done?t.ink3:t.ink};white-space:nowrap">${c.n}</span><span style="flex:1"></span><span style="font:600 11px var(--sans);color:${now?t.acc:done?t.ink3:t.ink2}">${done?"已结束":now?"进行中":e.st=="next"?"下一节":"晚上"}</span>`)});
 }
 tabBar(p,id,t,dark);homeBar(p,t);return p;
}
if(mode=="day-light")board("日视图 · 浅色","同一天：周三 11:05，上午第二门课正在上",ids.map(id=>col([caption(id),dayPhone(id,false)])));
if(mode=="day-dark")board("日视图 · 深色","",ids.map(id=>col([caption(id,"（深色）"),dayPhone(id,true)])));
if(mode=="month-dark")board("月视图 · 深色","",ids.map(id=>col([caption(id,"（深色）"),monthPhone(id,true)])));
if(mode=="month-light")board("月视图 · 浅色","2027 年 4 月：清明 4/3–4/5 放假，4/11 调休上班；农历按系统中国历计算",ids.map(id=>col([caption(id),monthPhone(id,false)])));

if(mode=="grid-set"){
 const cap=(b,sp)=>E("div","",`<b>${b}</b><span>${sp}</span>`,"cap");
 board("格子 · 方块","按旧版的格子风格整理：同一组示意数据（第 7 周，周一清明放假，周日调休上班，现在是周三 11:05）",[
  col([cap("周视图 · 浅色","节次轴写起止时间；上午、下午、晚上之间多留 8pt 缝；今天整列淡主题色底；放假那列换成虚线格子，竖排写「清明假期」。"),weekPhone("grid",false)]),
  col([cap("周视图 · 深色","空格子是 5.5% 白加 8.5% 白细边；课程底用同色深一档，字用同色浅一档，课名对比度不低于 9.8:1。"),weekPhone("grid",true)]),
  col([cap("日视图","同一套格子竖着排：没课的节次留空白格，课程格横跨节次，右侧直接写状态（已结束、还剩 35 分、2 小时 55 分后）。"),dayPhone("grid",false)]),
  col([cap("月视图","每天一个格子：日期、农历、课程色点、休/班角标；今天描主题色边；放假的格子垫一层淡红底。"),monthPhone("grid",false)])]);
}
