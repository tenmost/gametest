#!/usr/bin/env python3
"""Layout check — run before every push that changes the look: python3 tools/check_layout.py
(needs playwright + Chrome/Chromium; works offline: the 3D scene and the server are blocked, the HTML layout is still checked)

Opens index.html at phone / tablet / computer sizes, on the lobby, OFFLINE and ONLINE pages, as a guest and as a
"logged-in" layout (🔔 / 📋 shown), and reports:
  OUT      something sticks out of its panel (player card, rank card, leaderboard, side panels, top menu, open windows)
  OFFGAME  something is outside the game frame
  CUT      text is cut off (hidden overflow without "…")
  OVERLAP  two buttons / texts in the same panel cover each other
Screenshots of every case go to /tmp/layout/ so you can look at them.
Exit code 1 when anything is found.  --only phone|tablet|desktop  limits the sizes.
"""
import asyncio, pathlib, sys, json
from playwright.async_api import async_playwright

ROOT = pathlib.Path(__file__).resolve().parent.parent
OUT = pathlib.Path('/tmp/layout'); OUT.mkdir(exist_ok=True)
SIZES = [  # name, w, h, touch
    ('phone-740x340', 740, 340, True), ('phone-844x390', 844, 390, True), ('phone-932x430', 932, 430, True),
    ('tablet-1024x768', 1024, 768, True), ('tablet-1180x820', 1180, 820, True),
    ('desktop-1000x600', 1000, 600, False), ('desktop-1280x720', 1280, 720, False), ('desktop-1920x1080', 1920, 1080, False),
]
MODES = ['gate', 'cpu', 'online']
CHROME = next((p for p in ['/usr/bin/google-chrome', '/usr/bin/chromium', '/usr/bin/chromium-browser'] if pathlib.Path(p).exists()), None)

PREP = r'''([mode,logged])=>{for(const id of ['sdBoot','sdNet','fsAsk','a2hs','rotateMsg'])document.getElementById(id)?.remove();
 document.querySelectorAll('dialog[open]').forEach(x=>x.close());
 const st=document.getElementById('stage');st.classList.add('selecting');st.dataset.mode=mode;
 if(logged){document.getElementById('playerCard')?.classList.remove('guest');for(const id of ['inboxBtn','dailyCardBtn']){const e=document.getElementById(id);if(e){e.hidden=false;e.removeAttribute('hidden')}}
  const n=document.querySelector('#playerCard .pcName');if(n)n.textContent='LongPlayerName99';const g=document.getElementById('demoGemBalance');if(g)g.textContent='💎 12345'}
 dispatchEvent(new Event('resize'))}'''

CHECK = r'''()=>{
 const R=e=>e.getBoundingClientRect(),vis=e=>{if(!e||!e.isConnected)return false;const s=getComputedStyle(e);if(s.display==='none'||s.visibility==='hidden'||+s.opacity===0)return false;const r=R(e);return r.width>1&&r.height>1};
 const name=e=>e.id?'#'+e.id:(e.tagName.toLowerCase()+(e.classList.length?'.'+[...e.classList].slice(0,2).join('.'):''));
 const path=e=>{const p=[];for(let x=e;x&&x!==document.body&&p.length<4;x=x.parentElement)p.unshift(name(x));return p.join(' > ')};
 const txt=e=>(e.innerText||e.getAttribute('aria-label')||'').trim().replace(/\s+/g,' ').slice(0,40);
 const stage=document.getElementById('stage'),S=R(stage),out=[];
 const PANELS=[...document.querySelectorAll('#playerCard,#rankCard,#howMini,#lobbyBoard,#heroPlate,#topNav,#eventCard,#cpuInfo,#selectionBottom,#onLeft,#online .onBox,#podium,#arenaSide.show,#heroPick.show,dialog[open]')].filter(vis);
 const BADGE=/\bibN\b|\blvB\b|\bsdShine\b|\brkB\b/;
 const clipAnc=(e,stop)=>{for(let x=e.parentElement;x&&x!==stop;x=x.parentElement){const s=getComputedStyle(x);if(/(auto|scroll|hidden|clip)/.test(s.overflowX+s.overflowY))return x}return null};
 for(const P of PANELS){const B=R(P);
  if(B.left<S.left-1||B.top<S.top-1||B.right>S.right+1||B.bottom>S.bottom+1)out.push(['OFFGAME',path(P),txt(P),[B.left-S.left,B.top-S.top,B.right-S.right,B.bottom-S.bottom].map(Math.round)]);
  for(const e of P.querySelectorAll('*')){if(!vis(e)||BADGE.test(e.className))continue;if(e.closest('dialog')!==P.closest('dialog'))continue;
   if(clipAnc(e,P))continue; /* inside a scroll list → may scroll */
   const r=R(e);if(r.left<B.left-1.5||r.top<B.top-1.5||r.right>B.right+1.5||r.bottom>B.bottom+1.5){out.push(['OUT',path(e),txt(e),'in '+name(P)+' by '+JSON.stringify([B.left-r.left,B.top-r.top,r.right-B.right,r.bottom-B.bottom].map(v=>Math.max(0,Math.round(v))))]);}
  }
  /* overlaps between buttons / leaf texts inside the same panel */
  const leaves=[...P.querySelectorAll('button,a,input,select,b,small,span,strong,h1,h2,h3,h4,p,label')].filter(e=>vis(e)&&!BADGE.test(e.className)&&!e.querySelector('button,b,small,span,strong,p,label,input')&&(e.tagName==='BUTTON'||e.tagName==='INPUT'||txt(e)));
  for(let i=0;i<leaves.length;i++)for(let j=i+1;j<leaves.length;j++){const a=leaves[i],b=leaves[j];if(a.contains(b)||b.contains(a))continue;
   const A=R(a),C=R(b),w=Math.min(A.right,C.right)-Math.max(A.left,C.left),h=Math.min(A.bottom,C.bottom)-Math.max(A.top,C.top);
   if(w>3&&h>3){const ca=clipAnc(a,P),cb=clipAnc(b,P);if(ca||cb)continue;out.push(['OVERLAP',path(a)+' ⟷ '+path(b),txt(a)+' ⟷ '+txt(b),[Math.round(w),Math.round(h)]])}}
  /* cut text */
  for(const e of P.querySelectorAll('*')){if(!vis(e)||e.children.length)continue;const s=getComputedStyle(e);if(!txt(e))continue;
   if(/(hidden|clip)/.test(s.overflowX)&&e.scrollWidth>e.clientWidth+2&&s.textOverflow!=='ellipsis')out.push(['CUT',path(e),txt(e),'width '+e.clientWidth+' < '+e.scrollWidth]);}
 }
 const seen=new Set();return out.filter(x=>{const k=x[0]+x[1];if(seen.has(k))return false;seen.add(k);return true})}'''

async def main():
    only = sys.argv[sys.argv.index('--only') + 1] if '--only' in sys.argv else None
    total = 0
    async with async_playwright() as p:
        b = await p.chromium.launch(**({'executable_path': CHROME} if CHROME else {}))
        for (n, w, h, t) in SIZES:
            if only and not n.startswith(only): continue
            for logged in (False, True):
                pg = await b.new_page(viewport={'width': w, 'height': h}, has_touch=t, is_mobile=t)
                await pg.add_init_script("for(const k of ['sd_tut_done','sd_wiz_seen','sd_a2hs'])localStorage.setItem(k,'1');localStorage.setItem('sd_seen_ver','9.9.9')")
                await pg.route('**/*', lambda r: r.continue_() if r.request.url.startswith('file') else r.abort())
                await pg.goto((ROOT / 'index.html').as_uri(), wait_until='domcontentloaded'); await pg.wait_for_timeout(2500)
                for mode in MODES:
                    await pg.evaluate(PREP, [mode, logged]); await pg.wait_for_timeout(700)
                    res = await pg.evaluate(CHECK)
                    tag = f"{n} {mode} {'logged-in' if logged else 'guest'}"
                    if res:
                        shot = OUT / (tag.replace(' ', '_') + '.png'); await pg.screenshot(path=str(shot))
                        print(f"\n✗ {tag}  ({shot})")
                        for r in res: print('   ', r[0].ljust(8), r[1], '·', repr(r[2]), r[3])
                        total += len(res)
                await pg.close()
        await b.close()
    print(f"\n{'✓ layout OK' if not total else f'✗ {total} layout problems'}")
    sys.exit(1 if total else 0)

asyncio.run(main())
