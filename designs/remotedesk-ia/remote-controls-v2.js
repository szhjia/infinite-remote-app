const q = (s) => document.querySelector(s);
const keys = [
  ["power","电源","⏻","关闭显示器",.315,.115,.166,.055],
  ["voice","语音","♩","按住听写",.685,.115,.166,.055],
  ["up","方向上","⌃","↑",.50,.192,.34,.049],
  ["left","方向左","‹","←",.274,.265,.141,.112],
  ["ok","确定","◎","Return",.50,.267,.311,.105],
  ["right","方向右","›","→",.726,.265,.141,.112],
  ["down","方向下","⌄","↓",.50,.341,.34,.049],
  ["back","返回","↶","Esc",.348,.415,.235,.078],
  ["plus","音量加","+","提高音量",.65,.415,.235,.078],
  ["home","主页","⌂","显示桌面",.348,.505,.235,.078],
  ["minus","音量减","−","降低音量",.65,.505,.235,.078],
  ["menu","菜单","≡","将 ChatGPT 切到前台",.348,.596,.235,.078],
  ["tv","直播","▣","媒体应用选择器",.65,.596,.235,.078]
];
const defaults = Object.fromEntries([...keys.map(([id,,,action]) => [id,action]),["power-long","锁定屏幕"]]);
const initialProfiles = [{name:"默认配置", actions:defaults, builtin:true},{name:"ChatGPT / Codex",actions:{...defaults,home:"新建对话 · ⌘N",ok:"发送当前草稿 · ⌘Return",back:"停止生成 · Esc"}}];
const load = (key, fallback) => { try { return JSON.parse(localStorage.getItem("remote-v2:"+key)) ?? fallback; } catch { return fallback; } };
const store = (key,value) => { try { localStorage.setItem("remote-v2:"+key, JSON.stringify(value)); } catch {} };
let windows = load("windows", {work:true,model:true});
let profiles = load("profiles",initialProfiles);
let active = Math.min(load("active",0),profiles.length-1);
let draft = null, selected = "ok", responsive = true, learning = false;
let mediaIDs = load("media",["qqmusic","youku","iqiyi","tencent"]);
let panelType = "", focusIndex = 0, mediaList = [], cols = 1, messageTimer;
const feedback = (message="") => q("#feedback").textContent = message;
function toast(message){
  q("#toast").textContent=message; q("#toast").hidden=false;
  clearTimeout(messageTimer); messageTimer=setTimeout(()=>q("#toast").hidden=true,2600);
}
function renderWindows(){
  q("#workspace").hidden=!windows.work;
  q("#model").hidden=!windows.model;
  q("#no-windows").hidden=windows.work||windows.model;
  q("#tray-workspace").ariaLabel=q("#tray-workspace").textContent=windows.work?"隐藏工作台":"显示工作台";
  q("#tray-model").ariaLabel=q("#tray-model").textContent=windows.model?"隐藏遥控器模型":"显示遥控器模型";
  q("#model-workspace").textContent=windows.work?"隐藏工作台":"显示工作台";
  q("#toolbar-model").setAttribute("aria-pressed",windows.model);
  q("#toolbar-model").ariaLabel=q("#toolbar-model").title=q("#tray-model").textContent;
}
function flip(which){ windows[which]=!windows[which]; store("windows",windows); renderWindows(); q("#tray").open=false; }
for(const [selector,which] of [["#tray-workspace","work"],["#tray-model","model"],["#model-workspace","work"],["#model-close","model"],["#toolbar-model","model"],["#traffic-close","work"]]){
  q(selector).onclick=()=>flip(which);
}
q("#response").onclick=()=>{
  responsive=!responsive;
  q("#response").setAttribute("aria-checked",responsive);
  q("#model-status").textContent=responsive?"已连接 · 正在响应":"已连接 · 响应已暂停";
};
q("#missing-permissions").onchange=(e)=>{ q("#permissions").hidden=!e.target.checked; };
document.querySelectorAll("[data-permission]").forEach(b=>b.onclick=()=>toast("预览：打开 macOS「"+b.dataset.permission+"」设置"));
function makeHotspots(){
  for(const [id,name,,,x,y,w,h] of keys){
    for(const live of [false,true]){
      const b=document.createElement("button");
      b.className="hot"; b.dataset.id=id;
      b.title=b.ariaLabel=live?name:name+" · 定位";
      Object.assign(b.style,{left:((x-w/2)*724-100)/524*100+"%",top:((y-h/2)*2172-106)/2001*100+"%",width:w*724/524*100+"%",height:h*2172/2001*100+"%"});
      b.onclick=()=>live?runVirtual(id):chooseKey(id);
      (live?q("#live-device"):q("#center-device")).append(b);
    }
  }
}
function chooseKey(id){
  selected=id;
  for(const row of document.querySelectorAll(".key")) row.setAttribute("aria-pressed",row.dataset.id===selected);
  for(const button of q("#center-device").querySelectorAll(".hot")) button.classList.toggle("selected",button.dataset.id===id);
  if(learning) { learning=false; feedback(draft?"有未保存的更改。":""); q("#learn").textContent="重新录入"; }
}
function runVirtual(id){
  if(learning){
    learning=false; q("#learn").textContent="重新录入";
    feedback("已收到按键信号。"); return;
  }
  if(!responsive) return toast("遥控器响应已暂停");
  const action=profiles[active].actions[id];
  if(action==="媒体应用选择器") return launchMedia();
  toast(action?"预览："+action:"此键未分配动作");
}
function makeSelect(id,current){
  const el=document.createElement("select");
  const base=id==="power-long"?"电源长按":keys.find(k=>k[0]===id)[1];
  el.ariaLabel=base+"的动作";
  const opts=new Set([defaults[id],current,"不分配动作","关闭显示器","锁定屏幕","将 ChatGPT 切到前台","媒体应用选择器","按住听写","Return","Esc","显示桌面","↑","↓","←","→","提高音量","降低音量","新建对话 · ⌘N","发送当前草稿 · ⌘Return","停止生成 · Esc"]);
  for(const label of opts) if(label) el.add(new Option(label,label,false,label===current));
  el.onchange=()=>{
    chooseKey(id==="power-long"?"power":id);
    draft={...(draft??profiles[active].actions),[id]:el.value};
    feedback(profiles[active].builtin?"默认配置只读，保存时请为副本命名。":"有未保存的更改。");
    q("#save").disabled=false;
  };
  return el;
}
function renderRows(){
  const actions=draft??profiles[active].actions, wrap=q("#rows");
  wrap.replaceChildren();
  for(const [id,name,symbol] of keys){
    const row=document.createElement("div"), key=document.createElement("button"), icon=document.createElement("i");
    row.className=id==="power"?"row power-row":"row";
    key.className="key"; key.dataset.id=id;
    icon.textContent=symbol; icon.setAttribute("aria-hidden","true");
    key.append(icon,name); key.onclick=()=>chooseKey(id);
    const assignments=document.createElement("div"); assignments.className="assigns";
    for(const [actionID,tag] of id==="power"?[["power","短按"],["power-long","长按"]]:[[id,""]]){
      const a=document.createElement("div"); a.className="assign";
      if(tag){ const label=document.createElement("small"); label.textContent=tag; a.append(label); }
      a.append(makeSelect(actionID,actions[actionID]??"不分配动作"));
      assignments.append(a);
    }
    row.append(key,assignments); wrap.append(row);
  }
  q("#active-label").textContent=profiles[active].name+(profiles[active].builtin?" · 只读":"");
  q("#save").disabled=!draft;
  chooseKey(selected);
}
function setActive(index){
  active=index; draft=null; feedback(); store("active",active); q("#panel").close(); renderRows();
}
function writeProfiles(){ store("profiles",profiles);store("active",active); }
function dialog(type,title,sub=""){
  panelType=type;
  q("#panel").dataset.mode=type;
  q("#tray").open=false;q("#config-menu").open=false;
  q("#panel-title").textContent=title;q("#panel-sub").textContent=sub;
  q("#panel-body").replaceChildren();
  if(!q("#panel").open) q("#panel").showModal();
  return q("#panel-body");
}
q("#panel-close").onclick=()=>q("#panel").close();
q("#panel").onclose=()=>panelType="";
function chooseProfile(index){
  if(index===active) {q("#panel").close();return;}
  if(!draft) return setActive(index);
  const b=dialog("dirty","要切换配置吗？","当前有未保存的更改。");
  const row=document.createElement("div");row.className="panel-foot";
  row.append(button("返回编辑",()=>q("#panel").close()),button("放弃更改并切换",()=>setActive(index),"primary"));b.append(row);
}
function button(label,action,kind=""){ const b=document.createElement("button");b.type="button";b.textContent=label;b.className=kind;b.onclick=action;return b; }
q("#show-profiles").onclick=()=>{
  const b=dialog("profiles","配置列表","切换后，遥控器使用该配置已保存的按键。");
  const list=document.createElement("div");list.className="profile-list";
  profiles.forEach((p,i)=>{
    const item=button(p.name,()=>chooseProfile(i),"profile-line"),meta=document.createElement("small");
    meta.textContent=(p.builtin?"只读 · ":"")+(i===active?"当前使用":"选择");
    item.append(meta);list.append(item);
  });
  b.append(list);
};
q("#restore").onclick=()=>{
  draft={...defaults};
  feedback("已载入默认值，保存后生效。");
  renderRows();
};
function saveAs(actions, suggested=""){
  const body=dialog("name","保存为自定义配置","默认配置始终可用，配置名称不能重复。");
  const form=document.createElement("form");form.className="dialog-form";
  const label=document.createElement("label");label.textContent="配置名称";label.htmlFor="profile-name";
  const name=document.createElement("input");name.id="profile-name";name.required=true;name.maxLength=36;name.value=suggested;
  const error=document.createElement("p");error.className="form-error";error.setAttribute("aria-live","polite");
  const save=document.createElement("button");save.className="primary";save.textContent="保存配置";
  form.append(label,name,error,save);body.append(form);name.focus();
  form.onsubmit=(event)=>{
    event.preventDefault();
    const value=name.value.trim();
    if(!value || profiles.some(p=>p.name.trim().normalize().toLowerCase()===value.normalize().toLowerCase())){
      error.textContent=value?"此名称已存在。":"请输入配置名称。";return;
    }
    profiles.push({name:value,actions});active=profiles.length-1;draft=null;writeProfiles();
    q("#panel").close();renderRows();feedback("配置已保存。");
  };
}
q("#save").onclick=()=>{
  if(!draft) return;
  if(profiles[active].builtin) return saveAs(draft);
  profiles[active].actions=draft;draft=null;writeProfiles();renderRows();feedback("配置已保存。");
};
q("#export").onclick=()=>{
  const p=profiles[active], url=URL.createObjectURL(new Blob([JSON.stringify({version:1,name:p.name,actions:p.actions},null,2)],{type:"application/json"}));
  const link=document.createElement("a");link.href=url;link.download=p.name.replaceAll("/","-")+".json";link.click();
  setTimeout(()=>URL.revokeObjectURL(url),1000);q("#config-menu").open=false;
};
q("#import").onclick=()=>{ q("#config-menu").open=false;q("#import-file").click(); };
q("#import-file").onchange=async(e)=>{
  const file=e.target.files[0];e.target.value="";if(!file)return;
  try{
    const data=JSON.parse(await file.text());
    if(data.version!==1||typeof data.name!=="string"||!data.actions||typeof data.actions!=="object")throw Error();
    const actions={...defaults};
    for(const key of Object.keys(defaults)) if(typeof data.actions[key]==="string")actions[key]=data.actions[key];
    saveAs(actions,data.name);
  }catch{toast("无法导入：请选用遥控台导出的 JSON。");}
};
q("#learn").onclick=()=>{
  learning=!learning;q("#learn").textContent=learning?"取消录入":"重新录入";
  feedback(learning?"请按一下遥控器对应按键。":draft?"有未保存的更改。":"");
};
function iconFor(id){
  const img=document.createElement("img");
  img.src="assets/media-launcher/"+apps.find(app=>app[0]===id)[4];img.alt="";return img;
}
function configMedia(){
  q("#global-settings").open=false;
  const b=dialog("media-settings","多媒体设置","本机扫描快照 · 选入最多 9 个已安装应用");
  const pending=new Set(mediaIDs), list=document.createElement("div");list.className="app-list";
  for(const [id,name,bundle,installed] of apps){
    const line=document.createElement("label");line.className="app-line"+(installed?"":" uninstalled");line.title=bundle;
    const checkbox=document.createElement("input");checkbox.type="checkbox";checkbox.checked=pending.has(id);checkbox.disabled=!installed;checkbox.ariaLabel=name;
    checkbox.onchange=()=>{if(checkbox.checked&&pending.size>=9){checkbox.checked=false;return;}checkbox.checked?pending.add(id):pending.delete(id);count.textContent="已选 "+pending.size+" / 9";};
    const status=document.createElement("small");status.textContent=installed?"已安装":"未检测到安装";
    line.append(checkbox,iconFor(id),name,status);list.append(line);
  }
  const foot=document.createElement("div");foot.className="panel-foot";
  const count=document.createElement("span");count.textContent="已选 "+pending.size+" / 9";
  foot.append(count,button("保存并预览",()=>{mediaIDs=[...pending];store("media",mediaIDs);launchMedia();},"primary"));b.append(list,foot);
}
function launchMedia(){
  mediaList=mediaIDs.map(id=>apps.find(a=>a[0]===id)).filter(a=>a?.[3]).slice(0,9);
  const n=mediaList.length;
  const body=dialog(n?"launcher":"launcher-empty","媒体应用");
  if(!n){
    const p=document.createElement("p");p.textContent="还没有选入已安装的应用。";body.append(p,button("多媒体设置…",configMedia));return;
  }
  cols=n===4?2:n<=2?n:3;
  q("#panel").style.setProperty("--launcher-cols",cols);
  const slots=n<=2?n:n===4?4:n<=6?6:9;
  const grid=document.createElement("div");grid.className="tiles";grid.style.setProperty("--cols",cols);grid.setAttribute("role","listbox");grid.ariaLabel="媒体应用";
  mediaList.forEach(([id,name],i)=>{
    const t=button(name,()=>openMedia(i),"tile");t.setAttribute("role","option");
    const label=document.createElement("span");
    label.className="tile-name";
    label.textContent=name;
    t.replaceChildren(iconFor(id),label);
    grid.append(t);
  });
  for(let i=n;i<slots;i++){const e=document.createElement("div");e.className="tile-empty";e.setAttribute("aria-hidden","true");grid.append(e);}
  body.append(grid);focusTile(0);
}
function focusTile(index){
  focusIndex=index;
  document.querySelectorAll(".tile").forEach((b,i)=>{b.tabIndex=i===index?0:-1;b.setAttribute("aria-selected",i===index);if(i===index)b.focus();});
}
function openMedia(index){
  if(!mediaList[index])return;
  const [,name]=mediaList[index];q("#panel").close();toast("预览：打开 "+name);
}
document.addEventListener("keydown",event=>{
  if(panelType!=="launcher" || !mediaList.length || event.key==="Escape")return;
  const dx={ArrowLeft:-1,ArrowRight:1}[event.key],dy={ArrowUp:-1,ArrowDown:1}[event.key];
  if(dx===undefined&&dy===undefined)return;
  event.preventDefault();
  const x=focusIndex%cols,y=Math.floor(focusIndex/cols),next=dy===undefined?focusIndex+dx:(y+dy)*cols+x;
  if(dy===undefined&&(x+dx<0||x+dx>=cols))return;
  if(next>=0&&next<mediaList.length)focusTile(next);
});
document.querySelectorAll("[data-open-media]").forEach(b=>b.onclick=launchMedia);
q("#configure-media").onclick=configMedia;
document.addEventListener("click",e=>document.querySelectorAll("details[open]").forEach(d=>{if(!d.contains(e.target))d.open=false;}));
makeHotspots();renderWindows();renderRows();
