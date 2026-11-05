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
 const c=SKIN_WAVE[name]||SKIN_WAVE.onair;
 const s0=$('gw0'),s1=$('gw1');if(s0)s0.setAttribute('stop-color',c[0]);if(s1)s1.setAttribute('stop-color',c[1]);
 const h1=document.querySelector('.logo h1');if(h1)h1.textContent='Radiofy';
 paintSkinBtn();
 try{localStorage.setItem('radiofy.skin',name)}catch(e){}
 requestAnimationFrame(()=>{try{drawDial()}catch(e){}});
}
window.radiofySetSkin=setSkin;
try{
 if(localStorage.getItem('radiofy.skinMig')!=='onair-2.25'){
  setSkin('onair');localStorage.setItem('radiofy.skinMig','onair-2.25');
 }else{
  const s=localStorage.getItem('radiofy.skin');if(s)setSkin(s);else setSkin('onair');
 }
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

// ----- onda: 22 FM Static (Wave Lab v2) detrás del logo -----
(function(){
 const stage=$('wstage'),logo=$('logo');
 if(!stage||!logo)return;
 const a=$('wvf'),b=$('wvb'),orb=$('orb'),rays=$('rays');
 if(a)a.style.display='none';if(b)b.style.display='none';if(orb)orb.style.display='none';if(rays)rays.style.display='none';
 const cv=document.createElement('canvas');
 cv.setAttribute('aria-hidden','true');
 cv.style.cssText='position:absolute;inset:0;width:100%;height:100%;pointer-events:none';
 stage.appendChild(cv);
 const ctx=cv.getContext('2d');
 let t=0,dpr=1,w=0,h=0;
 const env=u=>Math.sin(Math.PI*Math.max(0,Math.min(1,u)));
 const resize=()=>{
  const r=stage.getBoundingClientRect();
  dpr=Math.min(2,window.devicePixelRatio||1);
  w=Math.max(1,r.width);h=Math.max(1,r.height);
  cv.width=Math.floor(w*dpr);cv.height=Math.floor(h*dpr);
  ctx.setTransform(dpr,0,0,dpr,0,0);
 };
 const grad=()=>{
  const c0=($('gw0')&&$('gw0').getAttribute('stop-color'))||'#3ee6ff';
  const c1=($('gw1')&&$('gw1').getAttribute('stop-color'))||'#a66bff';
  const g=ctx.createLinearGradient(0,0,w,0);g.addColorStop(0,c0);g.addColorStop(1,c1);return g;
 };
 const fadeDraw=fn=>{
  ctx.save();fn();
  ctx.globalCompositeOperation='destination-in';
  const m=ctx.createLinearGradient(0,0,w,0);
  m.addColorStop(0,'rgba(0,0,0,0)');m.addColorStop(.1,'#000');m.addColorStop(.9,'#000');m.addColorStop(1,'rgba(0,0,0,0)');
  ctx.fillStyle=m;ctx.fillRect(0,0,w,h);ctx.restore();
 };
 const tick=()=>{
  if(panelOpen){
   if(!w)resize();
   t++;
   ctx.clearRect(0,0,w,h);
   fadeDraw(()=>{
    const order=(Math.sin(t*.02)+1)/2;
    const g=grad();
    for(let x=0;x<w;x+=3){
     const u=x/w;
     const chaos=(Math.sin(x*12.9898+t)*.5+Math.sin(x*78.233+t*.7)*.5)*14;
     const wave=Math.sin(u*Math.PI*2.5+t*.05)*10*env(u);
     const y=h/2+wave*(.3+order*.7)+chaos*(1-order)*env(u);
     ctx.fillStyle=g;ctx.globalAlpha=.5;ctx.fillRect(x,y,2,2);
    }
    ctx.globalAlpha=1;
   });
  }
  requestAnimationFrame(tick);
 };
 resize();
 requestAnimationFrame(tick);
 logo.addEventListener('click',ev=>{ev.stopPropagation();toggleOver()});
 addEventListener('resize',()=>{w=0});
 addEventListener('radiofy-layout',()=>{w=0;requestAnimationFrame(resize)});
})();

// El “efecto radio” (mitad de tema / next) vive en Spotify.app, no ruido en Radiofy
function playStatic(){}


const dial=$('dial'),sc=$('sc'),nd=$('nd');let DW=0;
function clampFreq(f){return Math.max(88,Math.min(108,Math.round(f*10)/10))}
function freqFromX(x){const r=dial.getBoundingClientRect(),pad=22,w=Math.max(1,DW-44);return clampFreq(88+((x-r.left-pad)/w)*20)}
const fx=f=>22+(f-88)/20*(DW-44);
function drawDial(){DW=dial.clientWidth||312;const pad=22,w=DW-pad*2,H=dial.clientHeight||52;let h='';
 // Escala ticks al alto real del dial (studio es bajo; neon/classic más altos)
 const top=Math.max(3,Math.round(H*0.14));
 const botMj=Math.max(top+6,Math.round(H*(curSkin==='studio'?0.62:0.48)));
 const botMid=Math.max(top+4,Math.round(H*(curSkin==='studio'?0.52:0.42)));
 const botSm=Math.max(top+3,Math.round(H*(curSkin==='studio'?0.44:0.36)));
 const ty=H-Math.max(4,Math.round(H*0.12));
 const step=curSkin==='studio'?1:0.5; // LCD denser majors, fewer micro-ticks
 for(let f=88;f<=108.001;f+=step){const x=pad+(f-88)/20*w,mj=f%4==0,mid=Math.abs(f%1)<0.01;
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
 if(landingArt)showArt(landingArt,true);
 else if(primedArt)showArt(primedArt,true);
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
 tuneWatch=setTimeout(()=>{if(busy){unlock();post({a:'unlock'})}},7000);
}
function tune(opts){
 opts=opts||{};
 if(!st.auth)return;
 if(busy&&!opts.parallel)return;
 if(busy&&opts.parallel&&dialTuneSent)return;
 busy=true;setPhase('tuning');$('cam').classList.add('busy');setMsg('');playStatic();lastPos=-1;
 coversLocked=false;landingArt='';
 const gen=++tuneGen;
 if(primedArt){pinLandingArt(primedArt);primedArt=''}
 armTuneWatch();
 post({a:'tune',radio:true,gen:gen});
}

function doInicio(){
 const p=$('ini'),m=$('miniIni');
 if(p){p.classList.remove('go');void p.offsetWidth;p.classList.add('go')}
 if(m){m.classList.remove('go');void m.offsetWidth;m.classList.add('go')}
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
 if(!s.id){
  if(busy||dialTravel||phase==='tuning'||lastId)return;
  meta('Sin reproducción','Pulsa Cambiar para sintonizar');art('');prog(0,0);durSec=0;setPlaying(false);return
 }
 durSec=(s.dur||0)/1000;const pos=s.pos||0,same=s.id==lastId,playing=s.st=='playing';
 setPlaying(playing);
 const smooth=!instant&&same&&playing&&lastPos>=0&&pos>=lastPos&&pos-lastPos<2.5;
 // Spotify.app = fuente de verdad: si el tema cambió, la UI sigue SIEMPRE
 if(!same||s.force){
  meta(s.name||'',s.artist||'');
  // Solo nueva carátula si cambió el tema (evita flash AS→oEmbed→poll)
  if(s.art&&!same){rememberArt(s.art);art(s.art,true)}
  else if(s.art&&!curArt){rememberArt(s.art);art(s.art,true)}
 }else if(!busy&&!dialTravel){
  meta(s.name||'',s.artist||'');
  if(s.art&&!curArt)art(s.art,!!instant);
 }
 if(smooth)prog(Math.min(durSec,pos+1),durSec,true);else prog(pos,durSec,false);
 lastId=s.id;lastPos=pos}

function applyTuned(m){
 primedArt='';
 coversLocked=true;
 meta(m.name||'',m.artist||'');
 if(m.art){landingArt=m.art;rememberArt(m.art);art(m.art,false)}
 durSec=(m.dur||0)/1000;const pos=m.pos||0;prog(pos,durSec,false);lastPos=pos;lastId=m.uri||'';
 S=Object.assign({},S||{},{id:m.uri,name:m.name,artist:m.artist,art:m.art,dur:m.dur,pos:pos,st:'playing'});
 setPlaying(true);setPhase('playing');
}
function onTuned(m){
 if(m.art)pinLandingArt(m.art);
 else coversLocked=true;
 bufferedTuned=null;
 applyTuned(m);
}

function unlock(){
 clearTimeout(tuneWatch);tuneWatch=0;
 busy=false;$('cam').classList.remove('busy');dialTuneSent=false;
 setPhase(lastId?'playing':'idle');
 if(!dialAnim){dialTravel=false;bufferedTuned=null}
}

window.onNative=function(m){
 if(m.t=='state')applyTrack(m,false);
 else if(m.t=='tuned')onTuned(m);
 else if(m.t=='art'){
  // oEmbed solo si aún no hay carátula (no reemplazar una buena)
  if(m.uri&&m.uri===lastId&&m.art&&!curArt){rememberArt(m.art);art(m.art,true);landingArt=m.art;coversLocked=true}
 }
 else if(m.t=='tuning'){
  if(!busy){busy=true;setPhase('tuning');$('cam').classList.add('busy')}
  if(m.flip===false)return;
  playStatic();
  if(primedArt)pinLandingArt(primedArt);
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
 else if(m.t=='err'){unlock();if(!st.auth){const n=$('snt');n.textContent=m.msg;n.classList.add('msg2')}else setMsg(m.msg)}
 else if(m.t=='wait')setWait(m.on);
 else if(m.t=='authed'){pls=null;setMsg('');meta('Conectado','Pulsa Cambiar para sintonizar')}
 else if(m.t=='playlists'){
  // No pisar lista buena con [] vacío si ya había items
  if(Array.isArray(m.items)&&m.items.length){pls=m.items;plErr=m.err||''}
  else if(pls==null){pls=Array.isArray(m.items)?m.items:[];plErr=m.err||''}
  else if(m.err)plErr=m.err;
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
}

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
 if(mi.hasAttribute('data-act')){const k=mi.getAttribute('data-act');closeMenu();if(k=='web')post({a:'openWeb'});else if(k=='here'){webWait=true;paintDev();setMsg('Pulsa play una vez en open.spotify.com; Radiofy pasará la música a este Mac sola.');post({a:'thisMac'})}return}
 if(mi.hasAttribute('data-dev')){closeMenu();const dv={id:mi.getAttribute('data-dev'),name:mi.getAttribute('data-n'),type:mi.getAttribute('data-ty')};webWait=false;paintDev(dv);
  if(pick){busy=true;setPhase('tuning');$('cam').classList.add('busy');playStatic();if(primedArt)pinLandingArt(primedArt);armTuneWatch();post(Object.assign({a:'useDevice',radio:true},dv))}else post(Object.assign({a:'transfer'},dv));return}
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
