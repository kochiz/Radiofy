'use strict';
(function(){
const $=id=>document.getElementById(id);
const post=o=>{try{window.webkit.messageHandlers.radio.postMessage(o)}catch(e){}};
const esc=s=>String(s==null?'':s).replace(/[&<>"']/g,c=>({'&':'&amp;','<':'&lt;','>':'&gt;','"':'&quot;',"'":'&#39;'}[c]));
const fmt=s=>{s=Math.max(0,Math.floor(s||0));return Math.floor(s/60)+':'+String(s%60).padStart(2,'0')};
const I={check:'<svg class="ck" viewBox="0 0 24 24"><path d="m5 12.5 4.5 4.5L19 7.5"/></svg>',dot:'<svg viewBox="0 0 24 24"></svg>',
 heart:'<svg viewBox="0 0 24 24"><path d="M12 20s-7-4.4-8.6-9C2.3 7.8 4.3 5 7.3 5c1.9 0 3.1 1 4.7 2.8C13.6 6 14.8 5 16.7 5c3 0 5 2.8 3.9 6-1.6 4.6-8.6 9-8.6 9z"/></svg>',
 list:'<svg viewBox="0 0 24 24"><path d="M4 7h16M4 12h16M4 17h10"/></svg>'};
let st={cur:'liked',curName:'Liked Songs',radio:true,auth:false,clientId:''},S=null,lastId='',freq=98,busy=false,msgT=0,pls=null,plErr='';
let panelOpen=true,durSec=0,seekDrag=false,dialDrag=false,acx=null,lastPos=-1,arts=[];
let dialAnim=0,lastStation=-1,artFront='A',curArt='';

const SKINS=['onair','neon','classic','vinyl','studio'];
const SKIN_LABEL={onair:'On Air',neon:'Neon',classic:'Classic',vinyl:'Vinyl',studio:'Studio'};
const SKIN_WAVE={onair:['#ff3b4a','#ff6b3b'],neon:['#3ee6ff','#b44cff'],classic:['#e8a04a','#c8792a'],vinyl:['#ff7a3a','#e040a0'],studio:['#2ee6ff','#3dffb5']};
let curSkin='onair';
function paintSkinBtn(){
 const t='Skin: '+(SKIN_LABEL[curSkin]||'On Air');
 ['skinBtn'].forEach(id=>{
  const b=$(id);if(!b)return;
  b.title=t;b.setAttribute('aria-label',t);
 });
}
function setSkinBtnOn(on){
 ['skinBtn'].forEach(id=>{const b=$(id);if(b)b.classList.toggle('on',!!on)});
}
function setSkin(name){
 if(SKINS.indexOf(name)<0)name='onair';
 curSkin=name;
 document.body.dataset.skin=name;
 paintSkinBtn();
 try{localStorage.setItem('radiofy.skin',name)}catch(e){}
 requestAnimationFrame(()=>{try{drawDial()}catch(e){}});
}
window.radiofySetSkin=setSkin;
 try{
 localStorage.setItem('radiofy.skin','onair');
 localStorage.setItem('radiofy.skinMig','multiverse-onair');
 setSkin('onair');
}catch(e){setSkin('onair')}

// studio waveform cosmético
(function(){
 const cv=$('studioWave');if(!cv)return;
 const ctx=cv.getContext('2d');let t=0;
 const tick=()=>{
  if(panelOpen&&curSkin==='studio'&&!document.body.classList.contains('over')){
   t+=.08;const w=cv.width,h=cv.height;ctx.clearRect(0,0,w,h);
   for(let layer=0;layer<3;layer++){
    ctx.beginPath();ctx.lineWidth=1.4+layer*.3;
    ctx.strokeStyle=layer===0?'#2ee6ff':layer===1?'#3dffb5':'#b8ff5a';
    ctx.globalAlpha=.35+layer*.25;
    for(let x=0;x<=w;x++){
     const u=x/w;
     const y=h/2+Math.sin(u*Math.PI*(2.2+layer)+t*(.9+layer*.2))*((18-layer*4)*(.5+.5*Math.sin(u*Math.PI)))
      +Math.sin(u*Math.PI*8+t*1.4+layer)*3;
     x?ctx.lineTo(x,y):ctx.moveTo(x,y);
    }
    ctx.stroke();
   }
   ctx.globalAlpha=1;
  }
  requestAnimationFrame(tick);
 };
 requestAnimationFrame(tick);
})();

function toggleOver(){post({a:'overscreen',on:!document.body.classList.contains('over')})}
function paintHz(){
 const v=freq.toFixed(1);
 $('hz').textContent=v;
 const led=$('ledHz');if(led)led.textContent=v;
}

// ----- brand mark animado: header + mini + about (mismo motor que el mock) -----
let logoBoost=0;
(function(){
 const C={
  barCount:6,barW:22,barGap:7,midY:120,
  heights:[52,96,138,138,96,52],
  bellyRx:16,bellyRy:20,bellyPulse:0.14,bellyDrift:3,
  amp:22,speed:2.8,phase:0.75,wobble:0.5,breath:0.06,
  playSize:1.05,playRound:14
 };
 const NS='http://www.w3.org/2000/svg';
 const totalW=C.barCount*C.barW+(C.barCount-1)*C.barGap,x0=160-totalW/2;
 function el(tag){return document.createElementNS(NS,tag)}
 function roundedPlay(cx,cy,size,round){
  const w=54*size,h=64*size;
  const pts=[[cx-w*.42,cy-h/2],[cx-w*.42,cy+h/2],[cx+w*.55,cy]];
  const r=Math.max(1,Math.min(round,(w+h)*0.08));
  const corner=(P,V,N)=>{
   const v1x=P[0]-V[0],v1y=P[1]-V[1],v2x=N[0]-V[0],v2y=N[1]-V[1];
   const L1=Math.hypot(v1x,v1y)||1,L2=Math.hypot(v2x,v2y)||1;
   const r1=Math.min(r,L1*.42),r2=Math.min(r,L2*.42);
   return{a:[V[0]+v1x/L1*r1,V[1]+v1y/L1*r1],b:[V[0]+v2x/L2*r2,V[1]+v2y/L2*r2],c:V};
  };
  const k0=corner(pts[2],pts[0],pts[1]),k1=corner(pts[0],pts[1],pts[2]),k2=corner(pts[1],pts[2],pts[0]);
  const f=n=>n.toFixed(2);
  return `M ${f(k0.b[0])} ${f(k0.b[1])} L ${f(k1.a[0])} ${f(k1.a[1])} Q ${f(k1.c[0])} ${f(k1.c[1])} ${f(k1.b[0])} ${f(k1.b[1])} L ${f(k2.a[0])} ${f(k2.a[1])} Q ${f(k2.c[0])} ${f(k2.c[1])} ${f(k2.b[0])} ${f(k2.b[1])} L ${f(k0.a[0])} ${f(k0.a[1])} Q ${f(k0.c[0])} ${f(k0.c[1])} ${f(k0.b[0])} ${f(k0.b[1])} Z`;
 }
 function mountBrand(svgOrHost,uid){
  if(!svgOrHost)return null;
  let svg=svgOrHost;
  if(svg.tagName.toLowerCase()!=='svg'){
   svg=el('svg');
   svg.setAttribute('viewBox','0 0 52 44');
   svg.setAttribute('overflow','visible');
   svg.classList.add('brand');
   svgOrHost.appendChild(svg);
  }else if(!svg.getAttribute('viewBox'))svg.setAttribute('viewBox','0 0 52 44');
  const gid=uid+'Grad',fid=uid+'Goo',wid=uid+'W',pid=uid+'P';
  svg.innerHTML=`<defs>
   <linearGradient id="${gid}" gradientUnits="userSpaceOnUse" x1="86" y1="0" x2="234" y2="0">
    <stop offset="0%" stop-color="#5B2BFF"/><stop offset="16%" stop-color="#C12BFF"/>
    <stop offset="56%" stop-color="#FF2D7A"/><stop offset="89%" stop-color="#FF7A18"/>
    <stop offset="100%" stop-color="#FFD000"/>
   </linearGradient>
   <filter id="${fid}" x="-50%" y="-50%" width="200%" height="200%" color-interpolation-filters="sRGB">
    <feGaussianBlur in="SourceGraphic" stdDeviation="4.2" result="blur"/>
    <feColorMatrix in="blur" mode="matrix" values="1 0 0 0 0  0 1 0 0 0  0 0 1 0 0  0 0 0 18 -7"/>
   </filter></defs>
   <g transform="translate(-22,-14) scale(0.30)">
    <g id="${wid}" filter="url(#${fid})" fill="url(#${gid})"></g>
    <path id="${pid}" fill="#fff"/>
   </g>`;
  const wave=svg.querySelector('#'+wid),play=svg.querySelector('#'+pid),grad=svg.querySelector('#'+gid);
  grad.setAttribute('x1',x0);grad.setAttribute('x2',x0+totalW);
  const bars=[],bellies=[];
  for(let i=0;i<C.barCount;i++){
   const r=el('rect');
   r.setAttribute('x',(x0+i*(C.barW+C.barGap)).toFixed(2));
   r.setAttribute('width',C.barW);
   r.setAttribute('rx',C.barW/2);r.setAttribute('ry',C.barW/2);
   wave.appendChild(r);bars.push(r);
  }
  for(let i=0;i<C.barCount-1;i++){
   const e=el('ellipse');
   e.setAttribute('cx',(x0+(i+1)*(C.barW+C.barGap)-C.barGap/2).toFixed(2));
   e.setAttribute('cy',C.midY);
   wave.appendChild(e);bellies.push(e);
  }
  play.setAttribute('d',roundedPlay(160,C.midY,C.playSize,C.playRound));
  return {bars,bellies};
 }
 const instances=[
  mountBrand($('brand'),'brand'),
  mountBrand($('miniBrand'),'miniBrand'),
  mountBrand($('aboutBrand'),'aboutBrand')
 ].filter(Boolean);
 const t0=performance.now();
 const ease=u=>Math.sin(u)*(0.82+0.18*Math.sin(u*0.5));
 (function tick(now){
  if(logoBoost>0)logoBoost*=.94;
  const t=(now-t0)/1000,hMax=Math.max(...C.heights);
  const pump=1+Math.min(0.45,logoBoost*0.07);
  for(const inst of instances){
   const {bars,bellies}=inst,heights=[];
   for(let i=0;i<bars.length;i++){
    const s=C.speed*(1+(i%3)*0.14),a=C.amp*pump*(0.6+0.4*(C.heights[i]/hMax)),ph=i*C.phase;
    let h=(C.heights[i]+ease(t*s+ph)*a+Math.sin(t*s*0.37+ph*1.7)*a*C.wobble)*(1+Math.sin(t*0.55)*C.breath);
    h=Math.max(C.barW*1.4,Math.min(160,h));heights.push(h);
    bars[i].setAttribute('y',(C.midY-h/2).toFixed(2));
    bars[i].setAttribute('height',h.toFixed(2));
   }
   for(let i=0;i<bellies.length;i++){
    const overlap=Math.min(heights[i],heights[i+1]),pulse=1+Math.sin(t*1.2+i*0.85)*C.bellyPulse;
    bellies[i].setAttribute('rx',(C.bellyRx*(0.85+0.25*(overlap/hMax))*pulse).toFixed(2));
    bellies[i].setAttribute('ry',(C.bellyRy*(0.85+0.35*(overlap/hMax))*pulse).toFixed(2));
    bellies[i].setAttribute('cy',(C.midY+Math.sin(t*0.75+i)*C.bellyDrift*0.4).toFixed(2));
   }
  }
  requestAnimationFrame(tick);
 })(t0);
 const logo=$('logo');
 if(logo)logo.addEventListener('click',ev=>{ev.stopPropagation();toggleOver()});
})();

// Sintonía: estático radio en la tapa (partículas del skin). Sin spin en Cambiar, sin gradiente, sin fuegos.
let tuneOn=false,tuneParts=[],tuneRaf=0;
function skinCols(){return SKIN_WAVE[curSkin]||SKIN_WAVE.onair}
function resizeTuneFx(){
 const cv=$('tuneFx'),w=$('artw');if(!cv||!w)return null;
 const r=w.getBoundingClientRect(),dpr=Math.min(2,window.devicePixelRatio||1);
 const W=Math.max(1,r.width),H=Math.max(1,r.height);
 cv.width=Math.floor(W*dpr);cv.height=Math.floor(H*dpr);
 cv.style.width=W+'px';cv.style.height=H+'px';
 const ctx=cv.getContext('2d');ctx.setTransform(dpr,0,0,dpr,0,0);return {cv,ctx,W,H};
}
function spawnTune(n,W,H){
 const cols=skinCols();
 for(let i=0;i<n;i++){
  const edge=Math.random()<.55;
  let x,y;
  if(edge){
   const s=Math.floor(Math.random()*4);
   if(s===0){x=Math.random()*W;y=Math.random()*10}
   else if(s===1){x=Math.random()*W;y=H-Math.random()*10}
   else if(s===2){x=Math.random()*10;y=Math.random()*H}
   else{x=W-Math.random()*10;y=Math.random()*H}
  }else{x=Math.random()*W;y=Math.random()*H}
  tuneParts.push({
   x,y,vx:(Math.random()-.5)*.35,vy:(Math.random()-.5)*.35,
   life:.55+Math.random()*.7,age:0,sz:1+Math.random()*1.6,
   c:cols[Math.random()<.5?0:1]
  });
 }
}
function tickTune(){
 tuneRaf=0;
 if(!tuneOn)return;
 const g=resizeTuneFx();if(!g){tuneRaf=requestAnimationFrame(tickTune);return}
 const {ctx,W,H}=g;
 ctx.clearRect(0,0,W,H);
 if(tuneParts.length<48)spawnTune(3,W,H);
 const next=[];
 for(let i=0;i<tuneParts.length;i++){
  const p=tuneParts[i];
  p.age+=.016;p.x+=p.vx;p.y+=p.vy;
  const u=p.age/p.life;if(u>=1)continue;
  const a=(u<.2?u/.2:1-((u-.2)/.8))*.55;
  ctx.globalAlpha=a;ctx.fillStyle=p.c;
  ctx.fillRect(p.x,p.y,p.sz,p.sz);
  next.push(p);
 }
 tuneParts=next;ctx.globalAlpha=1;
 tuneRaf=requestAnimationFrame(tickTune);
}
function startTuneFx(){
 const artw=$('artw');if(artw)artw.classList.add('tuning');
 tuneOn=true;tuneParts=[];
 const g=resizeTuneFx();if(g)spawnTune(56,g.W,g.H);
 if(!tuneRaf)tuneRaf=requestAnimationFrame(tickTune);
}
function stopTuneFx(){
 tuneOn=false;tuneParts=[];
 const artw=$('artw');if(artw)artw.classList.remove('tuning');
 const cv=$('tuneFx');if(cv){const c=cv.getContext('2d');if(c)c.clearRect(0,0,cv.width,cv.height)}
 if(tuneRaf){cancelAnimationFrame(tuneRaf);tuneRaf=0}
}
function playStatic(){
 logoBoost=8;
 startTuneFx();
}


const dial=$('dial'),sc=$('sc'),nd=$('nd');let DW=0;
function clampFreq(f){return Math.max(88,Math.min(108,Math.round(f*10)/10))}
function freqFromX(x){const r=dial.getBoundingClientRect(),pad=14,w=Math.max(1,DW-28);return clampFreq(88+((x-r.left-pad)/w)*20)}
const fx=f=>14+(f-88)/20*(DW-28);
function drawDial(){DW=dial.clientWidth||312;const pad=14,w=DW-pad*2,H=dial.clientHeight||36;let h='';
 const top=Math.max(2,Math.round(H*0.1));
 const botMj=Math.max(top+6,Math.round(H*(curSkin==='studio'?0.55:0.42)));
 const botMid=Math.max(top+4,Math.round(H*(curSkin==='studio'?0.46:0.34)));
 const botSm=Math.max(top+3,Math.round(H*(curSkin==='studio'?0.4:0.26)));
 const ty=H-Math.max(4,Math.round(H*0.14));
 const step=curSkin==='studio'?1:0.5;
 for(let f=88;f<=108.001;f+=step){const x=pad+(f-88)/20*w,mj=Math.abs(f%4)<0.01,mid=Math.abs(f%1)<0.01;
  if(curSkin==='studio'&&!mid)continue;
  h+=`<line class="${mj?'mj':''}" x1="${x.toFixed(1)}" x2="${x.toFixed(1)}" y1="${top}" y2="${mj?botMj:mid?botMid:botSm}"/>`;
  if(mj)h+=`<text x="${x.toFixed(1)}" y="${ty}">${f%1?f.toFixed(1):f}</text>`}
 sc.innerHTML=h;placeNeedle()}
function placeNeedle(){
 paintHz();
 nd.style.transform=`translate3d(${fx(freq).toFixed(1)}px,0,0)`;
}
function setFreq(f){freq=clampFreq(f);placeNeedle()}

let dialLastX=0,dialTravel=false,bufferedTuned=null,landingArt='',coversLocked=false,tuneGen=0;
let primedArt='',tuneWatch=0,phase='idle';
function setPhase(p){phase=p;document.body.dataset.phase=p}
function cancelDialAnim(){if(dialAnim){cancelAnimationFrame(dialAnim);dialAnim=0}}
function rememberArt(u){
 if(!u||arts.indexOf(u)>=0)return;
 arts.unshift(u);if(arts.length>40)arts.length=40;
 const im=new Image();im.src=u;
}
function pinLandingArt(u){
 if(!u)return;
 landingArt=u;rememberArt(u);coversLocked=true;showArt(u,true);
}
function showPendingArt(){
 // Solo carátula ya confirmada por tuned — nunca primed (suele ser otra pista).
 if(landingArt)showArt(landingArt,true);
}
function animateDialTo(target,done){
 cancelDialAnim();
 const from=freq,to=clampFreq(target);
 if(Math.abs(to-from)<.05){setFreq(to);if(done)done();return}
 showPendingArt();
 dialTravel=true;
 placeNeedle();
 const start=performance.now(),dur=Math.min(560,180+Math.abs(to-from)*22);
 const step=now=>{
  const u=Math.min(1,(now-start)/dur),e=1-Math.pow(1-u,3);
  freq=clampFreq(Math.round((from+(to-from)*e)*10)/10);
  if(landingArt&&curArt!==landingArt)showArt(landingArt,true);
  placeNeedle();
  if(u<1) dialAnim=requestAnimationFrame(step);
  else{
   dialAnim=0;setFreq(to);lastStation=-1;
   if(landingArt)showArt(landingArt,false);
   dialTravel=false;
   if(done)done();
  }
 };
 dialAnim=requestAnimationFrame(step);
}
function armTuneWatch(){
 clearTimeout(tuneWatch);
 // Solo liberar CTA a los 7s. NUNCA unlock()+post unlock: abría el gate con tapa vacía
 // y el nativo perdía busy → state viejo / nombre tarde.
 tuneWatch=setTimeout(()=>{
  if(!busy||phase!=='tuning')return;
  busy=false;$('cam').classList.remove('busy');dialTuneSent=false;
 },7000);
}
function tune(opts){
 opts=opts||{};
 if(!st.auth)return;
 if(busy&&!opts.parallel)return;
 if(busy&&opts.parallel&&dialTuneSent)return;
 busy=true;setPhase('tuning');$('cam').classList.add('busy');setMsg('');playStatic();lastPos=-1;
 // Mantener tapa/nombre anteriores hasta tuned (primed ≠ final; borrar = vacío + demora).
 primedArt='';
 if(curArt){landingArt=curArt;coversLocked=true}
 else{coversLocked=false;landingArt=''}
 const gen=++tuneGen;
 armTuneWatch();
 post({a:'tune',radio:true,gen:gen});
}

function doInicio(){
 // Clase "spin" (NO "go"): .go es el botón de login y revienta el layout del pill.
 const p=$('ini'),m=$('miniIni');
 if(p){p.classList.remove('spin');void p.offsetWidth;p.classList.add('spin')}
 if(m){m.classList.remove('spin');void m.offsetWidth;m.classList.add('spin')}
 lastPos=-1;post({a:'inicio'});
}
function doCambiar(){
 if(busy||!st.auth)return;
 const target=88+Math.random()*20;
 tune({fromDial:true,parallel:true});
 animateDialTo(target,null);
}

let quotaT=0,quotaLeft=0,quotaMeta='';
function fmtQuota(s){s=Math.max(0,Math.floor(s||0));const m=Math.floor(s/60),r=s%60;return m>0?(m+':'+String(r).padStart(2,'0')):(r+' s')}
function paintQuota(){
 const m=$('msg');if(!m)return;
 if(quotaLeft>0){
  m.textContent='Libre en '+fmtQuota(quotaLeft)+(quotaMeta?' · '+quotaMeta:'');
  m.classList.add('on','quota');
  return;
 }
 m.classList.remove('quota','on');
 m.textContent='';
}
function setQuota(sec, meta, silentClear){
 clearInterval(quotaT);quotaT=0;
 if(meta!=null)quotaMeta=meta;
 quotaLeft=Math.max(0,Math.ceil(Number(sec)||0));
 if(quotaLeft<=0){
  const m=$('msg');
  if(m&&m.classList.contains('quota')){m.classList.remove('quota','on');m.textContent='';}
  else if(!silentClear) paintQuota();
  return;
 }
 paintQuota();
 const end=Date.now()+quotaLeft*1000;
 quotaT=setInterval(()=>{
  quotaLeft=Math.max(0,Math.ceil((end-Date.now())/1000));
  if(quotaLeft<=0){clearInterval(quotaT);quotaT=0;quotaLeft=0;paintQuota();return}
  paintQuota();
 },1000);
}
function setMsg(t,opts){
 if(quotaLeft>0)return; // no tapar la cuenta regresiva
 const m=$('msg');if(!m)return;
 const soft=opts&&opts.soft;
 // soft = confirmaciones rutinarias → no molestar
 if(soft){m.classList.remove('on');clearTimeout(msgT);return}
 m.textContent=t||'';m.classList.remove('quota');m.classList.toggle('on',!!t);clearTimeout(msgT);
 if(t)msgT=setTimeout(()=>m.classList.remove('on'),opts&&opts.ms?opts.ms:2800);
}
function meta(t,a){
 const ti=$('ti'),ar=$('ar'),m=document.querySelector('.meta');
 const same=ti&&ar&&ti.textContent==t&&ar.textContent==a;
 if(ti)ti.textContent=t;if(ar)ar.textContent=a;
 const mt=$('miniTi'),ma=$('miniAr');
 if(mt)mt.textContent=t||'Radiofy';
 if(ma)ma.textContent=a||'—';
 if(same||!m)return;
 m.classList.remove('swp');void m.offsetWidth;m.classList.add('swp');
 clearTimeout(m._swpT);m._swpT=setTimeout(()=>m.classList.remove('swp'),500);
}
function prog(pos,dur,smooth){
 /* barra de progreso eliminada a pedido */
}

function syncMini(u){
 const m=$('miniImg');if(!m)return;
 if(!u){m.classList.remove('on');m.removeAttribute('src');delete m.dataset.u;return}
 if(m.dataset.u===u){m.classList.add('on');return}
 m.dataset.u=u;const n=new Image();n.onload=()=>{if(m.dataset.u!==u)return;m.src=u;m.classList.add('on')};n.src=u;
}

function showArt(u,instant){
 const g=$('glow'),a=$('imgA'),b=$('imgB');
 if(!u){a.className='ai';b.className='ai';g.classList.remove('on');curArt='';syncMini('');return}
 rememberArt(u);syncMini(u);
 if(u===curArt){g.classList.add('on');return}
 const front=artFront==='A'?a:b, back=artFront==='A'?b:a;
 const finish=()=>{
  clearTimeout(front._fadeT);clearTimeout(back._fadeT);
  back.src=u;back.className='ai on';
  void front.offsetWidth;
  if(front.src){front.classList.add('on');front.classList.add('out')}
  else front.className='ai';
  const leaving=front;
  leaving._fadeT=setTimeout(()=>{if(leaving.classList.contains('out'))leaving.className='ai'},1050);
  artFront=artFront==='A'?'B':'A';
  curArt=u;g.src=u;g.classList.add('on');
 };
 if(instant){
  clearTimeout(front._fadeT);clearTimeout(back._fadeT);
  back.dataset.u=u;back.src=u;back.className='ai on';
  front.className='ai';
  artFront=artFront==='A'?'B':'A';
  curArt=u;g.src=u;g.classList.add('on');
  return;
 }
 if(back.dataset.u===u&&back.complete){finish();return}
 back.dataset.u=u;
 const n=new Image();
 n.onload=()=>{if(back.dataset.u!==u)return;finish()};
 n.onerror=()=>{};
 n.src=u;
}
function art(u,instant){showArt(u,instant)}

function setPlaying(on){document.body.classList.toggle('playing',!!on)}

function applyTrack(s,instant){S=s;if(s.dev&&s.dev.id)paintDev(s.dev);
 if(s.sp=='err'){meta('Spotify no responde',s.msg||'Inténtalo de nuevo');setPlaying(false);return}
 // Durante sintonía / tapa locked el poll no pisa con otra canción.
 if(!instant&&(busy||phase==='tuning'||dialTravel))return;
 if(!instant&&coversLocked&&s.id&&lastId&&s.id!==lastId)return;
 if(!s.id){
  if(busy||dialTravel||phase==='tuning'||lastId)return;
  meta('Sin reproducción','Pulsa Cambiar para sintonizar');art('');prog(0,0);durSec=0;setPlaying(false);return
 }
 durSec=(s.dur||0)/1000;const pos=s.pos||0,same=s.id==lastId,playing=s.st=='playing';
 setPlaying(playing);
 const smooth=!instant&&same&&playing&&lastPos>=0&&pos>=lastPos&&pos-lastPos<2.5;
 if(same){
  if(coversLocked)coversLocked=false;
  meta(s.name||'',s.artist||'');
  if(s.art&&!curArt)art(s.art,!!instant);
 }else if(!coversLocked){
  meta(s.name||'',s.artist||'');
  if(s.art){rememberArt(s.art);art(s.art,true)}
 }
 if(smooth)prog(Math.min(durSec,pos+1),durSec,true);else prog(pos,durSec,false);
 lastId=s.id;lastPos=pos}

function applyTuned(m){
 primedArt='';
 coversLocked=true;
 stopTuneFx();
 meta(m.name||'',m.artist||'');
 // instant: el fade de 1s dejaba la carátula "a medias" y se sentía lenta
 if(m.art){landingArt=m.art;rememberArt(m.art);art(m.art,true)}
 durSec=(m.dur||0)/1000;const pos=m.pos||0;prog(pos,durSec,false);lastPos=pos;lastId=m.uri||'';
 S=Object.assign({},S||{},{id:m.uri,name:m.name,artist:m.artist,art:m.art,dur:m.dur,pos:pos,st:'playing'});
 setPlaying(true);setPhase('playing');
 logoBoost=Math.max(logoBoost,5);
}
function onTuned(m){
 bufferedTuned=null;
 applyTuned(m);
 unlock(); // tapa lista → quitar busy del CTA (sin esperar done)
}

function unlock(){
 clearTimeout(tuneWatch);tuneWatch=0;
 busy=false;$('cam').classList.remove('busy');dialTuneSent=false;
 stopTuneFx();
 // done/timeout no deben pasar a playing: abre applyTrack con state viejo.
 // applyTuned / err sí salen de tuning.
 if(phase!=='tuning') setPhase(lastId?'playing':'idle');
 if(!dialAnim){dialTravel=false;bufferedTuned=null}
}

window.onNative=function(m){
 if(m.t=='state')applyTrack(m,false);
 else if(m.t=='tuned')onTuned(m);
 else if(m.t=='art'){
  if(m.uri&&m.uri===lastId&&m.art){rememberArt(m.art);art(m.art,true);landingArt=m.art;coversLocked=true}
 }
 else if(m.t=='tuning'){
  if(!busy){busy=true;setPhase('tuning');$('cam').classList.add('busy')}
  if(m.flip===false)return;
  playStatic();
  // No borrar tapa: primed ≠ final, pero vaciar = flash vacío / carátula vieja tarde.
  primedArt='';
  if(curArt){landingArt=curArt;coversLocked=true}
  else{coversLocked=false;landingArt=''}
 }
 else if(m.t=='cacheCleared'){
  arts=[];primedArt='';landingArt='';coversLocked=false;
  if(Array.isArray(m.arts)&&m.arts.length)m.arts.forEach(rememberArt);
  else{art('');syncMini('')}
  if(!busy)setMsg('Memoria y carátulas reiniciadas');
 }
 else if(m.t=='about'){showAbout(m)}
 else if(m.t=='init'){st.cur=m.cur||'liked';st.curName=m.curName||'Liked Songs';st.radio=m.radio!==false;st.auth=!!m.auth;st.clientId=m.clientId||'';
  if(m.quotaSec>0)setQuota(m.quotaSec, m.quotaMeta||'');
  if(Array.isArray(m.arts))m.arts.forEach(rememberArt);
  if(m.redirect)$('ruri').textContent=m.redirect;if(m.dev)paintDev(m.dev);paintSrc();paintSw();paintSetup();setWait(!!m.waiting);
  if(m.last&&m.last.id)applyTrack(Object.assign({sp:'on'},m.last),true)}
 else if(m.t=='err'){setPhase(lastId?'playing':'idle');unlock();if(!st.auth){const n=$('snt');n.textContent=m.msg;n.classList.add('msg2')}else setMsg(m.msg)}
 else if(m.t=='wait')setWait(m.on);
 else if(m.t=='authed'){pls=null;setMsg('');meta('Conectado','Pulsa Cambiar para sintonizar')}
 else if(m.t=='playlists'){
  // No pisar lista buena con [] vacío si ya había items
  if(Array.isArray(m.items)&&m.items.length){pls=m.items;plErr=m.err||''}
  else if(pls==null){pls=Array.isArray(m.items)?m.items:[];plErr=m.err||''}
  else if(m.err)plErr=m.err;
  paintPlist();
  if(menu.classList.contains('on')&&mode=='src')renderMenu()
 }
 else if(m.t=='devices'){showDevices(Array.isArray(m.items)?m.items:[],!!m.pick,m.err)}
 else if(m.t=='webwait'){webWait=!!m.on;paintDev(curDev)}
 else if(m.t=='primed'){if(m.art){rememberArt(m.art);primedArt=m.art}}
 else if(m.t=='note')setMsg(m.msg);
 else if(m.t=='quota'){
  if(m.clear||m.sec===0){setQuota(0,'',true);return}
  const bits=[];
  if(m.src==='radiofy-default')bits.push('sin Retry-After → default Radiofy '+Math.round(m.armed||120)+'s');
  else if(m.raw!=null)bits.push('Retry-After Spotify: '+m.raw+(m.armed!=null?' → armado '+Math.round(m.armed)+'s':''));
  setQuota(m.sec, bits.join(' '));
 }
 else if(m.t=='done')unlock();
 else if(m.t=='over'){document.body.classList.toggle('over',!!m.on);drawDial();paintHz();dispatchEvent(new Event('radiofy-layout'))}
 else if(m.t=='shown'){document.body.classList.remove('paused');panelOpen=true;lastPos=-1;drawDial()}
 else if(m.t=='hidden'){document.body.classList.add('paused');panelOpen=false;closeMenu();cancelDialAnim()}};

function paintSetup(){$('setup').classList.toggle('on',!st.auth);const c=$('cid');if(!c.value)c.value=st.clientId;
 const n=$('snt');n.textContent='Necesitas Spotify Premium para controlar la reproducción.';n.classList.remove('msg2');if(!st.auth)setTimeout(()=>{if(!c.value)c.focus()},60)}
function setWait(on){$('setup').classList.toggle('wait',!!on);$('go').classList.toggle('dis',!!on)}
$('cp').onclick=()=>{post({a:'copy',text:$('ruri').textContent});const b=$('cp');b.classList.remove('ok');void b.offsetWidth;b.classList.add('ok');setTimeout(()=>b.classList.remove('ok'),1400)};
$('dash').onclick=()=>post({a:'openDash'});
$('go').onclick=()=>{const v=$('cid').value.trim();const n=$('snt');n.classList.remove('msg2');n.textContent='Necesitas Spotify Premium para controlar la reproducción.';
 if(!/^[A-Za-z0-9]{16,64}$/.test(v)){n.textContent='Pega el Client ID de tu app (32 letras y números).';n.classList.add('msg2');$('cid').focus();return}
 post({a:'setClient',id:v,login:true})};
$('cid').onkeydown=e=>{if(e.key=='Enter')$('go').onclick()};
$('cx').onclick=()=>post({a:'cancelLogin'});

$('cam').onclick=()=>doCambiar();
$('ini').onclick=()=>doInicio();
$('miniCam').onclick=ev=>{ev.stopPropagation();doCambiar()};
$('miniIni').onclick=ev=>{ev.stopPropagation();doInicio()};
function expandFromMini(ev){if(ev)ev.stopPropagation();post({a:'overscreen',on:false})}
$('miniLogo')&&($('miniLogo').onclick=expandFromMini);
$('miniArtHit')&&($('miniArtHit').onclick=expandFromMini);
$('miniInfoHit')&&($('miniInfoHit').onclick=expandFromMini);
$('ov').onclick=ev=>{ev.stopPropagation();toggleOver()};
$('resetMem').onclick=ev=>{
 ev.stopPropagation();
 unlock();
 post({a:'unlock'});
 post({a:'clearCache'});
};
function showAbout(m){
 const a=$('about');if(!a)return;
 if(m&&m.ver)$('aboutVer').textContent=m.ver;
 a.hidden=false;
}
function hideAbout(){const a=$('about');if(a)a.hidden=true}
$('aboutBtn').onclick=ev=>{ev.stopPropagation();post({a:'about'})};
$('aboutOk').onclick=ev=>{ev.stopPropagation();hideAbout()};
$('about').onclick=ev=>{if(ev.target.id==='about')hideAbout()};
function paintSw(){
 const s=$('sw');s.classList.toggle('on',st.radio);s.setAttribute('aria-checked',st.radio?'true':'false');
 s.title=st.radio?'ON: al terminar, la siguiente entra a mitad':'OFF: al terminar, la siguiente parte desde el inicio (recomendado si no quieres saltos)';
}
$('sw').onclick=ev=>{ev.preventDefault();st.radio=!st.radio;paintSw();save();
 setMsg('',{soft:true})};
const save=()=>post({a:'save',cur:st.cur,curName:st.curName,radio:st.radio});
function paintSrc(){
 const n=st.cur=='liked'?'Liked Songs':(st.curName||'Playlist');
 $('srcN').textContent=n;
 const h=$('hdrPl');if(h)h.textContent=n;
 paintPlist();
}
function paintPlist(){
 const box=$('plist');if(!box)return;
 let h='<div class="plist-title">Mis radios</div>';
 const likedOn=st.cur==='liked';
 h+=`<button type="button" class="mi${likedOn?' on':''}" data-u="liked" data-n="Liked Songs"><div class="thumb"></div><div class="txt"><div class="nm">Liked Songs</div><div class="cnt">Spotify</div></div><span class="st">${likedOn?'en aire':'usar'}</span></button>`;
 if(pls==null)h+='<div class="ld" style="padding:8px;color:rgba(255,255,255,.4)">Cargando…</div>';
 else{
  const list=pls.filter(p=>p.own!==false);
  h+=list.map(p=>{
   const on=st.cur===p.id;
   const art=p.art?`<img alt="" src="${esc(p.art)}">`:'';
   const n=Number(p.n);const cnt=(Number.isFinite(n)&&n>0)?(esc(String(n))+' · '):'';
   return `<button type="button" class="mi${on?' on':''}" data-u="${esc(p.id)}" data-n="${esc(p.name)}"><div class="thumb">${art}</div><div class="txt"><div class="nm">${esc(p.name)}</div><div class="cnt">${cnt}Spotify</div></div><span class="st">${on?'en aire':'usar'}</span></button>`;
  }).join('');
  if(!list.length)h+=`<div class="ld" style="padding:8px;color:rgba(255,255,255,.4)">${esc(plErr||'No hay playlists.')}</div>`;
 }
 box.innerHTML=h;
}
$('plist')&&$('plist').addEventListener('click',ev=>{
 const b=ev.target.closest('.mi');if(!b||!b.dataset.u)return;
 const next=b.dataset.u,name=b.dataset.n||'Playlist',changed=next!==st.cur;
 st.cur=next;st.curName=name;paintSrc();
 if(changed&&st.auth){
  busy=true;setPhase('tuning');$('cam').classList.add('busy');setMsg('');playStatic();lastPos=-1;
  arts=[];primedArt='';landingArt='';coversLocked=false;art('');syncMini('');
  armTuneWatch();
  post({a:'setSource',cur:next,curName:name});
 }else save();
});

let dialPtr=0,dialMoved=false,dialTuneSent=false;
function onDialDown(ev){
 if(busy||!st.auth)return;ev.preventDefault();
 cancelDialAnim();
 dialDrag=true;dialMoved=false;dialTuneSent=false;dialPtr=ev.clientX;dialLastX=ev.clientX;lastStation=-1;
 dial.setPointerCapture&&dial.setPointerCapture(ev.pointerId);
}
function onDialMove(ev){
 if(!dialDrag)return;
 dialLastX=ev.clientX;
 if(Math.abs(ev.clientX-dialPtr)>5){
  if(!dialMoved){
   dialMoved=true;dialTravel=true;bufferedTuned=null;showPendingArt();
   if(!dialTuneSent){dialTuneSent=true;tune({fromDial:true,parallel:true})}
  }
 }
 if(dialMoved){
  showPendingArt();
  setFreq(freqFromX(ev.clientX));
 }
}
function onDialUp(ev){
 if(!dialDrag)return;dialDrag=false;
 const target=freqFromX(ev.clientX);
 if(landingArt)showArt(landingArt,true);
 dialTravel=false;
 if(dialMoved){
  setFreq(target);
  if(bufferedTuned)flushBufferedTuned();
  else if(!dialTuneSent)tune({fromDial:true});
 }
 else{
  tune({fromDial:true,parallel:true});
  animateDialTo(target,null);
 }
}
dial.addEventListener('pointerdown',onDialDown);
dial.addEventListener('pointermove',onDialMove);
dial.addEventListener('pointerup',onDialUp);
dial.addEventListener('pointercancel',()=>{dialDrag=false;cancelDialAnim()});

/* seek/barra eliminados */
function seekFromX(){return 0}

const menu=$('menu');let mode='src';
const DV={Computer:'<svg viewBox="0 0 24 24"><rect x="3" y="5" width="18" height="11" rx="2"/><path d="M8 20h8M12 16v4"/></svg>',
 Smartphone:'<svg viewBox="0 0 24 24"><rect x="7" y="3" width="10" height="18" rx="2.5"/><path d="M11 18h2"/></svg>',
 Speaker:'<svg viewBox="0 0 24 24"><rect x="6" y="3" width="12" height="18" rx="2.5"/><circle cx="12" cy="14" r="3"/><path d="M12 7h.01"/></svg>'};
const SKIN_IC={
 onair:'<svg viewBox="0 0 24 24"><rect x="3" y="7" width="18" height="10" rx="2"/><path d="M7 12h2M11 10v4M15 11v2"/><circle cx="19" cy="6" r="2"/></svg>',
 neon:'<svg viewBox="0 0 24 24"><path d="M4 14c2-6 4-8 8-8s6 2 8 8"/><circle cx="12" cy="8" r="1.5"/></svg>',
 classic:'<svg viewBox="0 0 24 24"><rect x="3" y="6" width="18" height="12" rx="2"/><path d="M7 12h10M12 9v6"/></svg>',
 vinyl:'<svg viewBox="0 0 24 24"><circle cx="12" cy="12" r="8"/><circle cx="12" cy="12" r="2"/></svg>',
 studio:'<svg viewBox="0 0 24 24"><path d="M3 12h2l2-6 3 12 2-8 2 4h7"/></svg>'
};
function renderMenu(){mode='src';const row=(u,n,ic,sub)=>`<button class="mi" data-u="${esc(u)}" data-n="${esc(n)}">${st.cur==u?I.check:I.dot}${ic}<span class="nm">${esc(n)}</span>${sub!=null?`<span class="sub">${esc(sub)}</span>`:''}</button>`;
 let h=row('liked','Liked Songs',I.heart,null)+'<div class="mhr"></div>';
 if(pls==null)h+='<div class="ld">Cargando playlists…</div>';
 else{const list=pls.filter(p=>p.own!==false);h+=list.map(p=>row(p.id,p.name,I.list,p.n)).join('');
  if(!list.length)h+=`<div class="ld">${esc(plErr||'No hay playlists.')}</div>`}
 menu.innerHTML=h}
function renderSkinMenu(){
 mode='skin';
 let h='<div class="mt">Skin</div>';
 SKINS.forEach(id=>{
  h+=`<button class="mi" data-skin="${id}">${curSkin===id?I.check:I.dot}${SKIN_IC[id]}<span class="nm">${SKIN_LABEL[id]}</span></button>`;
 });
 h+='<div class="mhr"></div><button class="mi" data-act="resetMem">'+I.dot+'<span class="nm">Reiniciar sintonía</span></button>';
 menu.innerHTML=h;
}
function openMenu(){renderMenu();menu.classList.add('on');$('dv').classList.remove('on');setSkinBtnOn(false);$('chip').classList.add('on');post({a:'playlists',force:true})}
function openSkinMenu(){
 renderSkinMenu();menu.classList.add('on');
 $('chip').classList.remove('on');$('dv').classList.remove('on');setSkinBtnOn(true);
}
function closeMenu(){menu.classList.remove('on');$('chip').classList.remove('on');$('dv').classList.remove('on');setSkinBtnOn(false);mode='src'}
$('chip').onclick=ev=>{ev.stopPropagation();if(menu.classList.contains('on')&&mode=='src')closeMenu();else openMenu()};
const onSkinClick=ev=>{ev.stopPropagation();if(menu.classList.contains('on')&&mode=='skin')closeMenu();else openSkinMenu()};
$('skinBtn').onclick=onSkinClick;
let curDev={id:'',name:'',type:''},webWait=false,pick=false;
function paintDev(d){if(d)curDev=d;const b=$('dv');b.classList.toggle('wait',webWait);
 $('dvI').innerHTML=DV[curDev.type]||DV.Speaker;$('dvN').textContent=webWait?'Buscando reproductor web…':(curDev.name||'Elegir dispositivo')}
$('dv').onclick=ev=>{ev.stopPropagation();if(menu.classList.contains('on')&&mode=='dev'){closeMenu();return}
 menu.innerHTML='<div class="ld">Buscando dispositivos…</div>';mode='dev';menu.classList.add('on');$('dv').classList.add('on');$('chip').classList.remove('on');setSkinBtnOn(false);post({a:'devlist'})};
function showDevices(ds,pk,err){mode='dev';pick=pk;let h='<div class="mt">'+(pk?'¿Dónde suena?':'Salida')+'</div>'+`<button class="mi here" data-act="here">${I.dot}${DV.Computer}<span class="nm">Escuchar en este Mac</span></button><div class="mhr"></div>`;
 if(err)h+=`<div class="ld">${esc(err)}</div>`;
 if(ds.length){h+=ds.map(d=>`<button class="mi${d.restricted?' dis':''}" data-dev="${esc(d.id)}" data-n="${esc(d.name)}" data-ty="${esc(d.type)}">${d.active?I.check:I.dot}${DV[d.type]||DV.Speaker}<span class="nm">${esc(d.name)}</span>${d.active?'<span class="act">activo</span>':''}</button>`).join('')}
 else if(!err)h+='<div class="nd2">Abre open.spotify.com en Safari o Spotify en tu teléfono, dale play una vez y vuelve a pulsar Cambiar.<button class="b p" data-act="web" style="display:block">Abrir open.spotify.com</button></div>';
 menu.innerHTML=h;menu.classList.add('on');$('chip').classList.remove('on');setSkinBtnOn(false);$('dv').classList.add('on')}
menu.addEventListener('click',ev=>{ev.stopPropagation();
 // OJO: body tiene data-skin → NUNCA usar closest('[data-skin]') a pelo (siempre pega en body = "Skin Neon")
 const mi=ev.target.closest('button.mi');if(!mi||!menu.contains(mi))return;
 if(mi.hasAttribute('data-skin')){setSkin(mi.getAttribute('data-skin'));closeMenu();return}
 if(mi.hasAttribute('data-act')){const k=mi.getAttribute('data-act');closeMenu();if(k=='web')post({a:'openWeb'});else if(k=='here'){webWait=true;paintDev();setMsg('Pulsa play una vez en open.spotify.com; Radiofy pasará la música a este Mac sola.');post({a:'thisMac'})}else if(k=='resetMem'){const b=$('resetMem');if(b)b.click()}return}
 if(mi.hasAttribute('data-dev')){closeMenu();const dv={id:mi.getAttribute('data-dev'),name:mi.getAttribute('data-n'),type:mi.getAttribute('data-ty')};webWait=false;paintDev(dv);
  if(pick){busy=true;setPhase('tuning');$('cam').classList.add('busy');playStatic();primedArt='';armTuneWatch();post(Object.assign({a:'useDevice',radio:true},dv))}else post(Object.assign({a:'transfer'},dv));return}
 if(mi.hasAttribute('data-u')){
  const next=mi.getAttribute('data-u'),name=mi.getAttribute('data-n')||'Playlist',changed=next!==st.cur;
  st.cur=next;st.curName=name;paintSrc();closeMenu();
  if(changed&&st.auth){
   // Aunque busy: encolar setSource (nativo serializa); no perder el cambio
   busy=true;setPhase('tuning');$('cam').classList.add('busy');setMsg('');playStatic();lastPos=-1;
   // Limpiar carátulas YA: no mostrar covers de la playlist anterior
   arts=[];primedArt='';landingArt='';coversLocked=false;art('');syncMini('');
   armTuneWatch();
   post({a:'setSource',cur:next,curName:name});
  }else save();
 }
});
document.addEventListener('click',()=>{if(menu.classList.contains('on'))closeMenu()});
document.addEventListener('keydown',ev=>{if(ev.key=='Escape'){ev.preventDefault();if(!$('about').hidden)hideAbout();else if(menu.classList.contains('on'))closeMenu();else if(document.body.classList.contains('over'))post({a:'overscreen',on:false});else post({a:'close'})}});
document.addEventListener('contextmenu',ev=>{if(!ev.target.closest('input'))ev.preventDefault()});

freq=88+Math.round(Math.random()*200)/10;drawDial();paintHz();
post({a:'ready'});
})();
