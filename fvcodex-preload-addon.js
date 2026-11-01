// OAIC usage preload addon (sandbox-safe: all network via IPC to main process).
;(()=>{
 try{
  const e=require('electron');
  const ipc=e.ipcRenderer, cb=e.contextBridge;
  try{ cb.exposeInMainWorld('oaicBridge',{fetchUsage:()=>ipc.invoke('oaic:usage'),openShop:()=>ipc.invoke('oaic:open-shop'),getSettings:()=>ipc.invoke('oaic:settings')}); }catch(_){}
  const ATTR='data-oaic-usage';
  const INFO_SVG='<svg viewBox="0 0 16 16" width="13" height="13" fill="none" stroke="currentColor" stroke-width="1.2" stroke-linecap="round" stroke-linejoin="round" aria-hidden="true"><circle cx="8" cy="8" r="6.5"/><path d="M8 5.5v2.5M8 12.5h.01"/></svg>';
  const ICON_SVG='<svg aria-hidden="true" width="16" height="16" viewBox="0 0 16 16" fill="none" stroke="currentColor" stroke-width="1.3" stroke-linecap="round" stroke-linejoin="round"><path d="M2.6 11.6a5.4 5.4 0 1 1 10.8 0"/><path d="M8 11.6 10.8 8.4"/><circle cx="8" cy="11.6" r="0.9" fill="currentColor" stroke="none"/></svg>';
  const EXT_SVG='<svg width="21" height="21" viewBox="0 0 21 21" fill="none" xmlns="http://www.w3.org/2000/svg" aria-hidden="true" class="icon-xs shrink-0 opacity-75 group-hover:opacity-100"><path d="M4.30164 12.197V8.53003C4.30164 7.84109 4.30099 7.28391 4.33777 6.83374C4.3752 6.37598 4.45451 5.9701 4.64636 5.59351L4.76843 5.37573C5.07254 4.8798 5.50895 4.47626 6.03015 4.21069L6.17273 4.14331C6.50897 3.99911 6.86981 3.93484 7.27039 3.9021C7.72063 3.86531 8.27758 3.86499 8.96668 3.86499H9.13367L9.26746 3.87866C9.57036 3.94067 9.79855 4.20883 9.79871 4.53003C9.79871 4.85133 9.5704 5.11932 9.26746 5.1814L9.13367 5.19507H8.96668C8.25564 5.19507 7.7623 5.19596 7.37878 5.22729C7.09678 5.25034 6.90733 5.28812 6.76355 5.3396L6.63367 5.39526C6.33147 5.54924 6.07854 5.7835 5.90222 6.07104L5.83191 6.19702C5.75142 6.35498 5.69465 6.56664 5.66394 6.94214C5.63261 7.3256 5.63171 7.81917 5.63171 8.53003V12.197C5.63171 12.9081 5.63261 13.4014 5.66394 13.7849C5.69464 14.1606 5.7514 14.372 5.83191 14.53L5.90222 14.656C6.07854 14.9436 6.33141 15.1778 6.63367 15.3318L6.76355 15.3884C6.9073 15.4399 7.09693 15.4767 7.37878 15.4998C7.7623 15.5311 8.25564 15.532 8.96668 15.532H12.6337C13.3445 15.532 13.8381 15.5311 14.2216 15.4998C14.5971 15.469 14.8087 15.4123 14.9667 15.3318L15.0927 15.2615C15.3802 15.0852 15.6145 14.8322 15.7684 14.53L15.8241 14.4001C15.8756 14.2564 15.9134 14.0669 15.9364 13.7849C15.9677 13.4014 15.9686 12.9081 15.9686 12.197V12.03C15.9688 11.6629 16.2665 11.365 16.6337 11.365C17.0007 11.3652 17.2985 11.663 17.2987 12.03V12.197C17.2987 12.8861 17.2984 13.4431 17.2616 13.8933C17.2289 14.2939 17.1646 14.6547 17.0204 14.991L16.953 15.1335C16.6874 15.6547 16.2839 16.0912 15.788 16.3953L15.5702 16.5173C15.1936 16.7092 14.7877 16.7885 14.33 16.8259C13.8798 16.8627 13.3226 16.8621 12.6337 16.8621H8.96668C8.27758 16.8621 7.72063 16.8627 7.27039 16.8259C6.86974 16.7932 6.50902 16.728 6.17273 16.5837L6.03015 16.5173C5.50912 16.2519 5.07253 15.848 4.76843 15.3523L4.64636 15.1335C4.45456 14.7569 4.37518 14.3511 4.33777 13.8933C4.30098 13.4431 4.30164 12.8861 4.30164 12.197ZM12.1034 10.0007C11.8437 10.2603 11.4226 10.2604 11.163 10.0007C10.9033 9.74109 10.9034 9.32001 11.163 9.0603L12.1034 10.0007ZM18.1317 7.86401C18.1315 8.23113 17.8338 8.52905 17.4667 8.52905C17.0995 8.52905 16.8018 8.23113 16.8016 7.86401V5.30249L12.1034 10.0007L11.6337 9.53003L11.163 9.0603L15.8602 4.36206H13.2997C12.9326 4.36188 12.6346 4.06418 12.6346 3.69702C12.6346 3.32986 12.9326 3.03216 13.2997 3.03198H17.4667L17.6005 3.04565C17.9036 3.10759 18.1317 3.37559 18.1317 3.69702V7.86401Z" fill="currentColor"></path></svg>';
  const css='['+ATTR+']{font-family:inherit;color:inherit;margin:0;padding:0;border:0;overflow:hidden}'
   +'['+ATTR+'] .oaic-body{display:none;padding:1px 0 3px}'
   +'['+ATTR+'].oaic-open .oaic-body{display:block}'
   +'['+ATTR+'] .oaic-row{display:flex;justify-content:space-between;gap:14px;padding:3px 14px 3px 30px;font-size:12.5px}'
   +'['+ATTR+'] .oaic-label{font-weight:600;color:inherit}'
   +'['+ATTR+'] .oaic-muted{opacity:.6;font-variant-numeric:tabular-nums}'
   +'['+ATTR+'] .oaic-info{display:inline-flex;align-items:center;justify-content:center;margin-left:6px;cursor:help;opacity:.6}'
   +'['+ATTR+'] .oaic-info svg{width:13px;height:13px;flex-shrink:0}'
   +'['+ATTR+'] .oaic-info:hover{opacity:1}'
   +'['+ATTR+'] .oaic-buy{display:none;justify-content:space-between;align-items:center;gap:10px;padding:7px 14px 7px 30px;margin:0 4px 4px;font-size:13px;cursor:pointer;border-radius:10px}'
   +'['+ATTR+'].oaic-open .oaic-buy{display:flex}'
   +'['+ATTR+'] .oaic-buy:hover{background:color-mix(in srgb,currentColor 8%,transparent)}'
   +'['+ATTR+'] .oaic-buy .oaic-ext{width:16px;height:16px;flex-shrink:0}'
   +'['+ATTR+'] .oaic-chev{display:inline-block;transition:transform .15s;opacity:.6;transform-origin:center}'
   +'['+ATTR+'].oaic-open .oaic-chev{transform:rotate(90deg)}'
   +'['+ATTR+']~.pointer-events-none.invisible.h-0.overflow-hidden{display:none!important}'
   +'.oaic-tip{position:fixed;z-index:2147483647;background:rgba(20,20,20,.9);color:#fff;font-size:11px;padding:4px 8px;border-radius:6px;white-space:nowrap;pointer-events:none;box-shadow:0 2px 10px rgba(0,0,0,.5)}';
  const esc=x=>String(x==null?'':x).replace(/[&<>"']/g,c=>({'&':'&amp;','<':'&lt;','>':'&gt;','"':'&quot;',"'":'&#39;'}[c]));
  const num=x=>{const n=Number(x);return Number.isFinite(n)?n:null};
  const pct=x=>Number.isFinite(x)?Math.max(0,Math.min(100,Math.round(x))):null;
  function compact(n){n=num(n);if(n==null)return '\u2014';const a=Math.abs(n);if(a>=1e9)return (n/1e9).toFixed(2)+'B';if(a>=1e6)return (n/1e6).toFixed(2)+'M';if(a>=1e3)return (n/1e3).toFixed(1)+'k';return String(Math.round(n));}
  function money(n){n=num(n);return n==null?'\u2014':'$'+(Math.abs(n)>=100?n.toFixed(0):n.toFixed(2));}
  function reset(v){if(v==null||v==='')return '';const d=new Date(typeof v==='number'?(v<1e12?v*1000:v):v);if(Number.isNaN(d.getTime()))return '';return d.getTime()-Date.now()<86400000?d.toLocaleTimeString([],{hour:'numeric',minute:'2-digit'}):d.toLocaleDateString([],{month:'short',day:'numeric'});}
  function style(){if(document.getElementById('oaic-usage-style'))return;const x=document.createElement('style');x.id='oaic-usage-style';x.textContent=css;(document.head||document.documentElement).appendChild(x);}

  function nativeRow(){
    const els=document.querySelectorAll('[role="menuitem"]');
    for(let i=0;i<els.length;i++){
      const t=(els[i].textContent||'').trim();
      if(t.length<40&&/^Usage remaining/i.test(t)) return els[i];
    }
    return null;
  }

  function prettyType(t){
    t=String(t||'').replace(/^total_/,'');
    const m={tokens:'Tokens',token:'Tokens',cost:'Costs',costs:'Costs',requests:'Requests',request:'Requests'};
    const k=t.toLowerCase();
    return m[k]||(t.charAt(0).toUpperCase()+t.slice(1));
  }

  function rowsFrom(v){
    const a=[];
    for(const x of (v&&v.limits)||[]) a.push({x,u:false});
    for(const x of (v&&v.upstream_limits)||[]) a.push({x,u:true});
    const rows=a.map(function(o){
      const x=o.x,max=num(x.max_value),rem=num(x.remaining_value),cur=num(x.current_value);
      let p=null;
      if(rem!=null&&max>0) p=rem/max*100;
      else if(cur!=null&&max>0) p=100-cur/max*100;
      const isLifetime = x.limit_window === 'lifetime';
      const label=[prettyType(x.limit_type), isLifetime ? null : x.limit_window].filter(Boolean).join(' / ')||'Limit';
      const info=(x.model_filter&&x.model_filter.length)?'<span class="oaic-info" data-tip="Models: '+esc(x.model_filter.join(', '))+'">'+INFO_SVG+'</span>':'';
      const resetPart = isLifetime ? '' : (reset(x.reset_at)?'  '+esc(reset(x.reset_at)):'');
      return '<div class="oaic-row"><span class="oaic-label">'+esc(label)+info+'</span><span class="oaic-muted">'+(p==null?'\u2014':Math.round(p)+'%')+resetPart+'</span></div>';
    });
    let badge=null;
    if(a.length){
      const ps=a.map(function(o){const x=o.x,max=num(x.max_value),rem=num(x.remaining_value),cur=num(x.current_value);if(rem!=null&&max>0)return rem/max*100;if(cur!=null&&max>0)return 100-cur/max*100;return null}).filter(Number.isFinite);
      if(ps.length) badge=Math.round(Math.min.apply(null,ps))+'%';
    } else {
      if(num(v&&v.request_count)!=null) rows.push('<div class="oaic-row"><span>Requests</span><span class="oaic-muted">'+esc(compact(v.request_count))+'</span></div>');
      if(num(v&&v.total_tokens)!=null) rows.push('<div class="oaic-row"><span>Tokens</span><span class="oaic-muted">'+esc(compact(v.total_tokens))+'</span></div>');
      if(num(v&&v.total_cost_usd)!=null) rows.push('<div class="oaic-row"><span>Spent</span><span class="oaic-muted">'+esc(money(v.total_cost_usd))+'</span></div>');
      if(num(v&&v.total_cost_usd)!=null) badge=money(v.total_cost_usd);
    }
    return {rows,badge};
  }

  function nativeIconSlot(){
    const els=document.querySelectorAll('[role="menuitem"] [data-leading-icon-slot]');
    for(let i=0;i<els.length;i++){
      const el=els[i];
      if(el.closest&&el.closest('['+ATTR+']')) continue;
      if(el.querySelector('svg,img')) return el;
    }
    return null;
  }
  function nativeChevron(){
    const svgs=document.querySelectorAll('[role="menuitem"] svg');
    for(let i=0;i<svgs.length;i++){
      const s=svgs[i];
      if(s.closest&&(s.closest('['+ATTR+']')||s.closest('[data-leading-icon-slot]'))) continue;
      const cls=String(s.getAttribute('class')||'');
      if(!/text-tertiary|Icon_/.test(cls)) continue;
      return s;
    }
    return null;
  }
  function buildHead(src){
    if(!src) return null;
    const head=document.createElement('div');
    for(const a of src.attributes){
      const n=a.name;
      if(n==='id'||n==='data-state'||n==='role'||n==='tabindex') continue;
      if(n.indexOf('data-radix')===0||n.indexOf('aria-')===0) continue;
      head.setAttribute(n,a.value);
    }
    head.style.cursor='pointer';
    const rc=document.createElement('div');
    rc.setAttribute('data-menu-row-content','true');
    rc.className='flex w-full min-w-0 items-center gap-[var(--spacing-menu-item-content,calc(var(--spacing)*1.5))]';
    const slot=nativeIconSlot();
    const icon=document.createElement('span');
    icon.setAttribute('data-leading-icon-slot','menu');
    icon.className=slot?String(slot.className):'inline-flex flex-none items-center justify-center';
    const iw=document.createElement('span');
    iw.className='inline-flex items-center justify-center leading-none icon-sm shrink-0 opacity-75 group-focus:opacity-100 group-hover:opacity-100';
    iw.innerHTML=ICON_SVG;
    icon.appendChild(iw);
    rc.appendChild(icon);
    const lab=document.createElement('span'); lab.className='flex-1 min-w-0 truncate';
    const inner=document.createElement('span'); inner.className='flex items-center gap-1';
    inner.appendChild(document.createTextNode('OAIC usage'));
    const badge=document.createElement('span');
    badge.className='whitespace-nowrap text-tertiary opacity-60 oaic-badge';
    badge.textContent='...';
    inner.appendChild(badge);
    lab.appendChild(inner);
    rc.appendChild(lab);
    const nat=nativeChevron();
    if(nat){
      const ch=nat.cloneNode(true); ch.removeAttribute('id'); ch.classList.add('oaic-chev'); rc.appendChild(ch);
    } else {
      const chev=document.createElementNS('http://www.w3.org/2000/svg','svg');
      chev.setAttribute('viewBox','0 0 16 16'); chev.setAttribute('width','16'); chev.setAttribute('height','16');
      chev.setAttribute('aria-hidden','true'); chev.setAttribute('class','text-tertiary oaic-chev');
      const p=document.createElementNS('http://www.w3.org/2000/svg','path');
      p.setAttribute('d','M6 3.5 10.5 8 6 12.5');
      p.setAttribute('fill','none'); p.setAttribute('stroke','currentColor'); p.setAttribute('stroke-width','1.4');
      p.setAttribute('stroke-linecap','round'); p.setAttribute('stroke-linejoin','round');
      chev.appendChild(p); rc.appendChild(chev);
    }
    head.appendChild(rc);
    return head;
  }

  function attachTips(sec){
    sec.querySelectorAll('.oaic-info').forEach(function(ic){
      ic.addEventListener('mouseenter',function(){
        if(ic._tip) return;
        const rect=ic.getBoundingClientRect();
        const tip=document.createElement('div'); tip.className='oaic-tip';
        tip.textContent=ic.getAttribute('data-tip')||'';
        document.body.appendChild(tip);
        const tr=tip.getBoundingClientRect();
        tip.style.left=(rect.left+rect.width/2-tr.width/2)+'px';
        tip.style.top=(rect.top-tr.height-7)+'px';
        ic._tip=tip;
      });
      ic.addEventListener('mouseleave',function(){
        if(ic._tip){ ic._tip.remove(); ic._tip=null; }
      });
    });
  }

  function headValue(sec,txt){
    const head=sec.firstElementChild;
    if(!head) return;
    const b=head.querySelector('.oaic-badge');
    if(b){ b.textContent=txt; return; }
    const spans=head.querySelectorAll('span');
    for(let i=spans.length-1;i>=0;i--){
      const s=spans[i];
      if(s.className&&s.className.indexOf('oaic-chev')>=0) continue;
      if(s.children.length===0){ s.textContent=txt; return; }
    }
  }

  function build(src){
    const s=document.createElement('div'); s.setAttribute(ATTR,''); s.className='oaic-open';
    const head=buildHead(src);
    if(head) s.appendChild(head);
    else {
      const fb=document.createElement('div');
      fb.style.cssText='display:flex;justify-content:space-between;align-items:center;padding:8px 12px;font-size:13px;font-weight:600';
      fb.innerHTML='<span>OAIC usage</span><span class="oaic-badge">...</span>';
      s.appendChild(fb);
    }
    const body=document.createElement('div'); body.className='oaic-body';
    body.innerHTML='<div class="oaic-row oaic-muted">Loading...</div>';
    s.appendChild(body);
    const buy=document.createElement('div'); buy.className='oaic-buy';
    buy.innerHTML='<span>Mua th\u00eam quota</span><span class="oaic-ext">'+EXT_SVG+'</span>';
    buy.addEventListener('click',function(ev){ev.preventDefault();ev.stopPropagation();ipc.invoke('oaic:open-shop')});
    s.appendChild(buy);
    const toggle=function(ev){ev.preventDefault();ev.stopPropagation();s.classList.toggle('oaic-open');};
    if(head) head.addEventListener('click',toggle);
    else s.firstChild.addEventListener('click',toggle);
    return s;
  }

  function render(sec,r){
    const body=sec.querySelector('.oaic-body');
    if(!r||!r.ok){
      headValue(sec,'off');
      body.innerHTML='<div class="oaic-row oaic-muted">'+esc((r&&r.error)||'Usage unavailable')+'</div>';
      return;
    }
    const out=rowsFrom(r.value||{});
    headValue(sec,out.badge||'\u2014');
    body.innerHTML=out.rows.join('')||'<div class="oaic-row oaic-muted">No data</div>';
    attachTips(sec);
  }

  let panel=null;
  function withMenu(el){
    let c=el;
    for(let i=0;i<8&&c;i++){
      const t=c.textContent||'';
      if(t.length<2500&&/Log out/i.test(t)&&/Settings/i.test(t)) return true;
      c=c.parentElement;
    }
    return false;
  }
  function findAnchor(){
    const els=document.querySelectorAll('[role="menuitem"]');
    let help=null;
    for(let i=0;i<els.length;i++){
      const el=els[i],t=(el.textContent||'').trim();
      // Never anchor to our own injected panel.
      if(el.closest&&el.closest('['+ATTR+']')) continue;
      if(!withMenu(el)) continue;
      if(/^Usage remaining/i.test(t)&&t.length<40){ el._oaicNativeUsage=true; return el; }
      if(/^Help$/i.test(t)) help=el;
    }
    // Newer profile menus omit Usage remaining. The panel is inserted just
    // above Help, using the same profile-menu row geometry.
    if(help) help._oaicHelpFallback=true;
    return help;
  }
  function isHelpFallback(el){ return !!(el&&el._oaicHelpFallback); }
  function load(p){
    ipc.invoke('oaic:usage').then(function(r){render(p,r)}).catch(function(err){render(p,{ok:false,error:String(err&&err.message||err)})});
  }
  function scan(){
    const a=findAnchor();
    if(!a){ if(panel&&panel.isConnected) panel.remove(); return; }
    if(!panel||!panel.isConnected) panel=build(a);
    const group=a.parentElement;
    const container=group?group.parentElement:null;
    // Radix profile menus wrap all rows in one flex column. In that layout
    // insert directly before Help inside the wrapper; inserting after the
    // wrapper would place OAIC below Log out. Older menus use one group per
    // row, where the sibling insertion remains correct.
    const wrappedRows=!!(group&&group.querySelectorAll&&group.querySelectorAll('[role="menuitem"]').length>1);
    if(wrappedRows){
      if(panel.parentElement!==group||panel.nextElementSibling!==a) group.insertBefore(panel,a);
    } else if(container&&(panel.parentElement!==container||panel.previousElementSibling!==group)){
      container.insertBefore(panel,group.nextSibling);
    }
    if(panel.getAttribute('data-loaded')!=='1'){
      panel.setAttribute('data-loaded','1');
      style();
      load(panel);
    }
  }

  function start(){
    try{
      style();scan();
      setInterval(function(){try{scan()}catch(_){}},600);
      new MutationObserver(function(){try{scan()}catch(_){}}).observe(document.documentElement,{childList:true,subtree:true});
    }catch(x){try{console.error('[oaic-usage]',x)}catch(_){}}
  }
  if(document.readyState==='loading')document.addEventListener('DOMContentLoaded',start,{once:true});else start();
 }catch(x){try{console.error('[oaic-usage preload]',x)}catch(_){} }
})();
