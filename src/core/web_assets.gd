class_name WebAssets
extends RefCounted
## The stylesheet, the script and the icons of the web pages the app serves (see ExportServer / WebPages). Kept as strings so they
## travel inside the app without any extra files in the export.

const VERSION := 4                         # bump when CSS / JS change: it is part of their address so browsers fetch the new ones

const LOGO := r"""<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 64 64"><defs><linearGradient id="g" x1="0" y1="0" x2="1" y2="1"><stop offset="0" stop-color="#6366f1"/><stop offset="1" stop-color="#8b5cf6"/></linearGradient></defs><rect width="64" height="64" rx="15" fill="url(#g)"/><path d="M14 40c6-14 11-14 14-4s8 10 12-4 6-8 10-2" fill="none" stroke="#fff" stroke-width="5" stroke-linecap="round" stroke-linejoin="round"/><circle cx="50" cy="19" r="4" fill="#fff" opacity=".85"/></svg>"""

const SPRITE := r"""<svg xmlns="http://www.w3.org/2000/svg" width="0" height="0" style="position:absolute" aria-hidden="true"><defs>
<symbol id="i-download" viewBox="0 0 24 24"><path d="M12 4v11"/><path d="m7 11 5 5 5-5"/><path d="M5 20h14"/></symbol>
<symbol id="i-upload" viewBox="0 0 24 24"><path d="M12 16V5"/><path d="m7 9 5-5 5 5"/><path d="M5 20h14"/></symbol>
<symbol id="i-trash" viewBox="0 0 24 24"><path d="M4 7h16"/><path d="M9 7V4h6v3"/><path d="M6 7l1 13h10l1-13"/><path d="M10 11v6M14 11v6"/></symbol>
<symbol id="i-eye" viewBox="0 0 24 24"><path d="M2 12s3.6-7 10-7 10 7 10 7-3.6 7-10 7S2 12 2 12Z"/><circle cx="12" cy="12" r="3"/></symbol>
<symbol id="i-pencil" viewBox="0 0 24 24"><path d="M4 20h4L19 9l-4-4L4 16v4Z"/><path d="m13.5 6.5 4 4"/></symbol>
<symbol id="i-x" viewBox="0 0 24 24"><path d="M6 6l12 12M18 6 6 18"/></symbol>
<symbol id="i-check" viewBox="0 0 24 24"><path d="m5 12 5 5 9-10"/></symbol>
<symbol id="i-refresh" viewBox="0 0 24 24"><path d="M20 11a8 8 0 1 0-2.3 5.7"/><path d="M20 5v6h-6"/></symbol>
<symbol id="i-logout" viewBox="0 0 24 24"><path d="M10 4H5v16h5"/><path d="m16 8 4 4-4 4"/><path d="M20 12H9"/></symbol>
<symbol id="i-file" viewBox="0 0 24 24"><path d="M7 3h7l5 5v13H7z"/><path d="M14 3v5h5"/></symbol>
<symbol id="i-grid" viewBox="0 0 24 24"><rect x="4" y="4" width="7" height="7" rx="1.5"/><rect x="13" y="4" width="7" height="7" rx="1.5"/><rect x="4" y="13" width="7" height="7" rx="1.5"/><rect x="13" y="13" width="7" height="7" rx="1.5"/></symbol>
<symbol id="i-room" viewBox="0 0 24 24"><path d="m4 11 8-7 8 7"/><path d="M6 10v10h12V10"/></symbol>
<symbol id="i-moon" viewBox="0 0 24 24"><path d="M20 14.5A8 8 0 0 1 9.5 4 8 8 0 1 0 20 14.5Z"/></symbol>
<symbol id="i-plus" viewBox="0 0 24 24"><path d="M12 5v14M5 12h14"/></symbol>
<symbol id="i-minus" viewBox="0 0 24 24"><path d="M5 12h14"/></symbol>
<symbol id="i-left" viewBox="0 0 24 24"><path d="m14 6-6 6 6 6"/></symbol>
<symbol id="i-right" viewBox="0 0 24 24"><path d="m10 6 6 6-6 6"/></symbol>
<symbol id="i-search" viewBox="0 0 24 24"><circle cx="11" cy="11" r="6.5"/><path d="m20 20-4.2-4.2"/></symbol>
<symbol id="i-lock" viewBox="0 0 24 24"><rect x="5" y="10" width="14" height="10" rx="2"/><path d="M8 10V7a4 4 0 0 1 8 0v3"/></symbol>
<symbol id="i-image" viewBox="0 0 24 24"><rect x="3.5" y="4.5" width="17" height="15" rx="2.5"/><circle cx="9" cy="10" r="1.8"/><path d="m4 17 5-4.5 4 3.5 3-2.5 4 3.5"/></symbol>
<symbol id="i-fit" viewBox="0 0 24 24"><path d="M4 9V4h5M20 9V4h-5M4 15v5h5M20 15v5h-5"/></symbol>
</defs></svg>"""

const CSS := r"""
:root{--bg:#f4f5f8;--surface:#fff;--surface-2:#eff1f6;--ink:#0f172a;--ink-2:#334155;--muted:#667085;--line:#e3e7ee;--line-2:#d0d7e2;
--brand:#4f46e5;--brand-hover:#4338ca;--brand-ink:#fff;--brand-soft:#eceeff;--good:#15803d;--good-soft:#e6f6ec;--bad:#d92d20;--bad-soft:#fdeceb;--warn:#b54708;--warn-soft:#fef3e2;
--shadow-1:0 1px 2px rgba(16,24,40,.05);--shadow-2:0 2px 4px -2px rgba(16,24,40,.06),0 14px 30px -10px rgba(16,24,40,.16);--r:14px;--r-sm:10px;--thumb:#fff;color-scheme:light}
@media(prefers-color-scheme:dark){:root:not([data-theme=light]){--bg:#0a0e19;--surface:#121827;--surface-2:#182034;--ink:#e8ecf6;--ink-2:#c5cddd;--muted:#8d98ad;--line:#222b41;--line-2:#303b58;
--brand:#818cf8;--brand-hover:#a5b4fc;--brand-ink:#0a0e19;--brand-soft:#1b2247;--good:#4ade80;--good-soft:#11301f;--bad:#f97066;--bad-soft:#381719;--warn:#fdb022;--warn-soft:#352610;--shadow-1:0 1px 2px rgba(0,0,0,.4);--shadow-2:0 2px 4px -2px rgba(0,0,0,.5),0 14px 30px -10px rgba(0,0,0,.6);color-scheme:dark}}
:root[data-theme=dark]{--bg:#0a0e19;--surface:#121827;--surface-2:#182034;--ink:#e8ecf6;--ink-2:#c5cddd;--muted:#8d98ad;--line:#222b41;--line-2:#303b58;
--brand:#818cf8;--brand-hover:#a5b4fc;--brand-ink:#0a0e19;--brand-soft:#1b2247;--good:#4ade80;--good-soft:#11301f;--bad:#f97066;--bad-soft:#381719;--warn:#fdb022;--warn-soft:#352610;--shadow-1:0 1px 2px rgba(0,0,0,.4);--shadow-2:0 2px 4px -2px rgba(0,0,0,.5),0 14px 30px -10px rgba(0,0,0,.6);color-scheme:dark}
*{box-sizing:border-box}
html{-webkit-text-size-adjust:100%}
body{margin:0;background:var(--bg);color:var(--ink);font:15px/1.5 Inter,ui-sans-serif,system-ui,-apple-system,"Segoe UI",Roboto,"Helvetica Neue",Arial,sans-serif;-webkit-font-smoothing:antialiased}
a{color:var(--brand);text-decoration:none}
a:hover{text-decoration:underline}
h1,h2,h3{margin:0;letter-spacing:-.015em;line-height:1.2}
h1{font-size:28px;font-weight:700}
h2{font-size:17px;font-weight:650}
button{font:inherit;color:inherit}
.ic{width:18px;height:18px;fill:none;stroke:currentColor;stroke-width:1.8;stroke-linecap:round;stroke-linejoin:round;flex:none}
.wrap{max-width:1240px;margin:0 auto;padding:28px 20px 80px}
.topbar{position:sticky;top:0;z-index:20;background:color-mix(in srgb,var(--bg) 82%,transparent);-webkit-backdrop-filter:saturate(1.4) blur(14px);backdrop-filter:saturate(1.4) blur(14px);border-bottom:1px solid var(--line)}
.topbar-in{max-width:1240px;margin:0 auto;padding:10px 20px;display:flex;align-items:center;gap:14px}
.brand{display:flex;align-items:center;gap:10px;font-weight:700;color:var(--ink);letter-spacing:-.01em}
.brand:hover{text-decoration:none}
.brand img{width:30px;height:30px;display:block}
.crumb{color:var(--muted);font-size:14px;white-space:nowrap;overflow:hidden;text-overflow:ellipsis;min-width:0}
.crumb b{color:var(--ink-2);font-weight:600}
.spacer{flex:1}
.live{display:inline-flex;align-items:center;gap:7px;font-size:13px;color:var(--muted);padding:5px 11px;border:1px solid var(--line);border-radius:99px;background:var(--surface)}
.live i{width:8px;height:8px;border-radius:50%;background:var(--good);box-shadow:0 0 0 0 color-mix(in srgb,var(--good) 55%,transparent);animation:pulse 2s infinite}
.live.off i{background:var(--bad);animation:none}
@keyframes pulse{70%{box-shadow:0 0 0 7px transparent}100%{box-shadow:0 0 0 0 transparent}}
.btn{display:inline-flex;align-items:center;justify-content:center;gap:8px;height:38px;padding:0 15px;border:1px solid var(--line-2);border-radius:var(--r-sm);background:var(--surface);color:var(--ink);font-weight:600;font-size:14px;cursor:pointer;box-shadow:var(--shadow-1);transition:background .12s,border-color .12s,transform .05s;white-space:nowrap}
.btn:hover{background:var(--surface-2);text-decoration:none}
.btn:active{transform:translateY(1px)}
.btn-primary{background:var(--brand);border-color:var(--brand);color:var(--brand-ink)}
.btn-primary:hover{background:var(--brand-hover);border-color:var(--brand-hover)}
.btn-danger{background:var(--bad);border-color:var(--bad);color:#fff}
.btn-danger:hover{background:var(--bad);filter:brightness(.92)}
.btn-ghost{background:transparent;border-color:transparent;box-shadow:none;color:var(--ink-2)}
.btn-ghost:hover{background:var(--surface-2)}
.btn-sm{height:32px;padding:0 11px;font-size:13px}
.btn[disabled]{opacity:.5;pointer-events:none}
.icon-btn{display:inline-grid;place-items:center;width:34px;height:34px;border:0;border-radius:9px;background:transparent;color:var(--ink-2);cursor:pointer}
.icon-btn:hover{background:var(--surface-2);color:var(--ink);text-decoration:none}
.icon-btn.danger:hover{background:var(--bad-soft);color:var(--bad)}
.head{display:flex;flex-wrap:wrap;gap:18px;align-items:flex-end;justify-content:space-between;margin-bottom:22px}
.eyebrow{margin:0 0 6px;font-size:12px;font-weight:650;letter-spacing:.08em;text-transform:uppercase;color:var(--brand)}
.stats{display:flex;flex-wrap:wrap;gap:8px;margin-top:12px}
.chip{display:inline-flex;align-items:center;gap:6px;padding:3px 11px;border-radius:99px;background:var(--surface);border:1px solid var(--line);font-size:13px;color:var(--ink-2)}
.chip b{color:var(--ink);font-weight:650}
.chip.here{background:var(--brand-soft);border-color:transparent;color:var(--brand);font-weight:600}
.actions{display:flex;flex-wrap:wrap;gap:10px}
.drop{display:flex;align-items:center;gap:16px;padding:20px 22px;margin-bottom:26px;border:1.5px dashed var(--line-2);border-radius:var(--r);background:var(--surface);cursor:pointer;transition:border-color .15s,background .15s}
.drop:hover,.drop.over{border-color:var(--brand);background:var(--brand-soft)}
.drop .badge{display:grid;place-items:center;width:46px;height:46px;border-radius:12px;background:var(--brand-soft);color:var(--brand);flex:none}
.drop .badge .ic{width:22px;height:22px}
.drop strong{display:block;font-size:15px}
.drop span{color:var(--muted);font-size:13.5px}
.drop input{display:none}
.uploads{display:grid;gap:8px;margin:-12px 0 24px}
.uploads:empty{display:none}
.up{display:flex;align-items:center;gap:12px;padding:10px 14px;border:1px solid var(--line);border-radius:var(--r-sm);background:var(--surface);font-size:14px}
.up .ic{color:var(--muted)}
.up.ok .ic{color:var(--good)}
.up.err{border-color:color-mix(in srgb,var(--bad) 40%,var(--line));background:var(--bad-soft)}
.up.err .ic{color:var(--bad)}
.up .nm{font-weight:600;overflow:hidden;text-overflow:ellipsis;white-space:nowrap;max-width:36%}
.up .msg{color:var(--muted);flex:1;min-width:0}
.up.err .msg{color:var(--bad)}
.spin{width:16px;height:16px;border:2px solid var(--line-2);border-top-color:var(--brand);border-radius:50%;animation:spin .7s linear infinite;flex:none}
@keyframes spin{to{transform:rotate(360deg)}}
.toolbar{display:flex;flex-wrap:wrap;align-items:center;gap:12px;margin-bottom:6px;position:sticky;top:56px;z-index:10;background:var(--bg);padding:8px 0}
.tabs{display:flex;gap:6px;flex-wrap:wrap}
.tab{border:1px solid var(--line);background:var(--surface);border-radius:99px;padding:5px 14px;font-size:13.5px;font-weight:600;color:var(--ink-2);cursor:pointer}
.tab:hover{border-color:var(--line-2)}
.tab.on{background:var(--ink);border-color:var(--ink);color:var(--bg)}
.tab small{opacity:.65;font-weight:600;margin-left:4px}
.search{position:relative;margin-left:auto}
.search .ic{position:absolute;left:11px;top:10px;color:var(--muted);width:16px;height:16px}
.search input{height:38px;width:240px;max-width:100%;padding:0 12px 0 34px;border:1px solid var(--line-2);border-radius:var(--r-sm);background:var(--surface);color:var(--ink);font:inherit;font-size:14px}
.search input:focus,.field:focus,.pin:focus{outline:2px solid var(--brand);outline-offset:1px;border-color:transparent}
.bulk{display:none;align-items:center;gap:10px;padding:9px 12px 9px 16px;margin:6px 0 14px;border:1px solid color-mix(in srgb,var(--brand) 35%,var(--line));background:var(--brand-soft);border-radius:var(--r-sm);font-weight:600;color:var(--brand)}
.bulk.on{display:flex}
.bulk .spacer{flex:1}
.room{margin-top:22px}
.room-h{display:flex;align-items:center;gap:10px;margin-bottom:12px}
.room-h .ic{color:var(--muted)}
.room-h .tag{font-size:11.5px;font-weight:650;padding:2px 9px;border-radius:99px;background:var(--brand-soft);color:var(--brand)}
.room-h .links{margin-left:auto;display:flex;gap:4px}
.grid{display:grid;grid-template-columns:repeat(auto-fill,minmax(250px,1fr));gap:16px}
.card{position:relative;display:flex;flex-direction:column;background:var(--surface);border:1px solid var(--line);border-radius:var(--r);overflow:hidden;box-shadow:var(--shadow-1);transition:box-shadow .15s,border-color .15s,transform .15s}
.card:hover{box-shadow:var(--shadow-2);border-color:var(--line-2);transform:translateY(-1px)}
.card.sel{border-color:var(--brand);box-shadow:0 0 0 2px color-mix(in srgb,var(--brand) 30%,transparent)}
.thumb{position:relative;display:block;aspect-ratio:3/2;background:var(--thumb);border-bottom:1px solid var(--line)}
.thumb img{position:absolute;inset:10px;width:calc(100% - 20px);height:calc(100% - 20px);object-fit:contain}
.thumb:hover{text-decoration:none}
.pick{position:absolute;top:10px;left:10px;z-index:2;width:24px;height:24px;cursor:pointer}
.pick input{position:absolute;inset:0;opacity:0;margin:0;cursor:pointer}
.pick span{position:absolute;inset:0;border-radius:7px;background:color-mix(in srgb,var(--surface) 92%,transparent);border:1.5px solid var(--line-2);display:grid;place-items:center;opacity:0;transition:opacity .12s;box-shadow:var(--shadow-1)}
.card:hover .pick span,.pick input:checked+span,.has-sel .pick span{opacity:1}
.pick input:checked+span{background:var(--brand);border-color:var(--brand)}
.pick input:checked+span::after{content:"";width:5px;height:10px;border:solid var(--brand-ink);border-width:0 2px 2px 0;transform:rotate(45deg) translate(-1px,-1px)}
.pick input:focus-visible+span{outline:2px solid var(--brand);outline-offset:2px}
.card-body{padding:12px 14px 4px;min-width:0}
.card-title{font-weight:650;white-space:nowrap;overflow:hidden;text-overflow:ellipsis}
.card-sub{color:var(--muted);font-size:13px}
.card-actions{display:flex;gap:2px;padding:6px 8px 8px}
.card-actions .spacer{flex:1}
.panel{margin-top:34px;background:var(--surface);border:1px solid var(--line);border-radius:var(--r);box-shadow:var(--shadow-1);overflow:hidden}
.panel-h{display:flex;align-items:center;gap:10px;padding:14px 18px;border-bottom:1px solid var(--line)}
.panel-h span{color:var(--muted);font-size:13.5px}
table{width:100%;border-collapse:collapse;font-size:14px}
th{text-align:left;font-size:12px;letter-spacing:.06em;text-transform:uppercase;color:var(--muted);font-weight:650;padding:9px 18px;background:var(--surface-2)}
td{padding:10px 18px;border-top:1px solid var(--line)}
td.num,th.num{text-align:right;white-space:nowrap}
td.acts{text-align:right;white-space:nowrap;width:1%}
.file{display:flex;align-items:center;gap:10px;min-width:0}
.file .ic{color:var(--muted)}
.ext{font-size:11px;font-weight:700;letter-spacing:.04em;padding:2px 7px;border-radius:6px;background:var(--surface-2);color:var(--ink-2);text-transform:uppercase}
.empty{display:grid;justify-items:center;gap:8px;text-align:center;padding:56px 20px;border:1.5px dashed var(--line-2);border-radius:var(--r);color:var(--muted);background:var(--surface)}
.empty .badge{display:grid;place-items:center;width:54px;height:54px;border-radius:16px;background:var(--brand-soft);color:var(--brand)}
.empty .badge .ic{width:26px;height:26px}
.empty h2{color:var(--ink)}
.banner{display:none;position:fixed;left:50%;bottom:22px;transform:translateX(-50%);z-index:40;align-items:center;gap:14px;padding:11px 12px 11px 18px;background:var(--ink);color:var(--bg);border-radius:99px;box-shadow:var(--shadow-2);font-weight:600;font-size:14px}
.banner.on{display:flex}
.banner .btn{height:30px;font-size:13px}
#toasts{position:fixed;right:18px;bottom:18px;z-index:60;display:grid;gap:10px;justify-items:end}
.toast{display:flex;align-items:center;gap:10px;max-width:min(92vw,420px);padding:11px 16px;border-radius:12px;background:var(--ink);color:var(--bg);box-shadow:var(--shadow-2);font-size:14px;font-weight:550;animation:rise .2s ease-out}
.toast.bad{background:var(--bad);color:#fff}
@keyframes rise{from{opacity:0;transform:translateY(8px)}}
.modal{position:fixed;inset:0;z-index:50;display:grid;place-items:center;padding:20px;background:rgba(8,12,24,.55);-webkit-backdrop-filter:blur(3px);backdrop-filter:blur(3px);animation:fade .15s}
@keyframes fade{from{opacity:0}}
.dialog{width:min(440px,100%);background:var(--surface);border:1px solid var(--line);border-radius:18px;padding:22px;box-shadow:var(--shadow-2)}
.dialog h2{font-size:18px;margin-bottom:6px}
.dialog p{margin:0 0 16px;color:var(--muted)}
.dialog .row{display:flex;justify-content:flex-end;gap:10px;margin-top:18px}
.field{width:100%;height:42px;padding:0 13px;border:1px solid var(--line-2);border-radius:var(--r-sm);background:var(--surface);color:var(--ink);font:inherit}
.auth{min-height:calc(100vh - 140px);display:grid;place-items:center}
.auth-card{width:min(420px,100%);padding:34px 30px 28px;background:var(--surface);border:1px solid var(--line);border-radius:20px;box-shadow:var(--shadow-2);text-align:center}
.auth-card .badge{display:grid;place-items:center;width:54px;height:54px;margin:0 auto 16px;border-radius:16px;background:var(--brand-soft);color:var(--brand)}
.auth-card .badge .ic{width:26px;height:26px}
.auth-card h1{font-size:22px;margin-bottom:6px}
.auth-card p{margin:0 0 22px;color:var(--muted)}
.pin{width:100%;height:60px;text-align:center;font:600 30px/1 ui-monospace,SFMono-Regular,Menlo,Consolas,monospace;letter-spacing:.4em;padding-left:.4em;border:1px solid var(--line-2);border-radius:14px;background:var(--surface);color:var(--ink)}
.auth-card .btn{width:100%;height:44px;margin-top:14px}
.err{margin:12px 0 0;padding:9px 12px;border-radius:var(--r-sm);background:var(--bad-soft);color:var(--bad);font-size:14px;font-weight:550}
.hint{margin-top:18px;font-size:13px;color:var(--muted)}
.vhead{display:flex;flex-wrap:wrap;gap:12px;align-items:center;margin:4px 0 16px}
.vhead h1{font-size:24px;margin-right:auto}
.back{display:inline-flex;align-items:center;gap:6px;color:var(--muted);font-weight:600;font-size:14px;margin-bottom:12px}
.back:hover{color:var(--ink);text-decoration:none}
.vbar{display:flex;flex-wrap:wrap;align-items:center;gap:10px;margin-bottom:14px}
.seg{display:inline-flex;padding:3px;border:1px solid var(--line);border-radius:11px;background:var(--surface-2)}
.seg a,.seg button{border:0;background:transparent;padding:5px 13px;border-radius:8px;font-size:13.5px;font-weight:600;color:var(--ink-2);cursor:pointer;display:inline-flex;align-items:center;gap:6px}
.seg a:hover,.seg button:hover{text-decoration:none;color:var(--ink)}
.seg .on{background:var(--surface);color:var(--ink);box-shadow:var(--shadow-1)}
.stage{border:1px solid var(--line);border-radius:var(--r);background:var(--surface);box-shadow:var(--shadow-1);overflow:auto;max-height:calc(100vh - 230px);min-height:300px;padding:16px}
.stage img{display:block;margin:0 auto;max-width:none;width:100%;height:auto;border-radius:6px;box-shadow:0 0 0 1px var(--line)}
.stage img.bg-white{background:#fff}
.stage img.bg-dark{background:#14181f}
.stage img.bg-none{background:conic-gradient(#d4d8e0 25%,#fff 0 50%,#d4d8e0 0 75%,#fff 0) 0 0/20px 20px}
.gal{display:grid;gap:22px}
.gal .card{box-shadow:var(--shadow-1)}
.gal .card:hover{transform:none}
.gal .full{padding:16px;background:var(--thumb)}
.gal .full img{display:block;max-width:100%;height:auto;margin:0 auto}
.gal-h{display:flex;align-items:center;gap:10px;padding:12px 16px;border-bottom:1px solid var(--line)}
.gal-h b{margin-right:auto}
.foot{margin-top:40px;text-align:center;color:var(--muted);font-size:13px}
@media(max-width:700px){.wrap{padding:20px 14px 70px}h1{font-size:23px}.crumb{display:none}.search{margin-left:0;width:100%}.search input{width:100%}.toolbar{position:static}.grid{grid-template-columns:repeat(auto-fill,minmax(150px,1fr));gap:12px}.up .nm{max-width:30%}th.hide,td.hide{display:none}.drop{padding:16px}.live span{display:none}}
@media(prefers-reduced-motion:reduce){*{animation:none!important;transition:none!important}}
"""

const JS := r"""
(function () {
  'use strict';
  var $ = function (s, r) { return (r || document).querySelector(s); };
  var $$ = function (s, r) { return Array.prototype.slice.call((r || document).querySelectorAll(s)); };
  var HEAD = { 'X-Requested-With': 'mrw' };
  var rev = document.body.getAttribute('data-rev') || '';
  var picked = {};

  function icon(n) { return '<svg class="ic"><use href="#i-' + n + '"/></svg>'; }
  function esc(s) { return String(s).replace(/[&<>"']/g, function (c) { return { '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;' }[c]; }); }

  function toast(msg, bad) {
    var box = $('#toasts'); if (!box) return;
    var t = document.createElement('div');
    t.className = 'toast' + (bad ? ' bad' : '');
    t.innerHTML = icon(bad ? 'x' : 'check') + '<span>' + esc(msg) + '</span>';
    box.appendChild(t);
    setTimeout(function () { t.remove(); }, bad ? 6000 : 3800);
  }

  function api(path, body) {
    return fetch(path, { method: 'POST', credentials: 'same-origin', headers: Object.assign({ 'Content-Type': 'application/json' }, HEAD), body: JSON.stringify(body || {}) })
      .then(function (r) {
        if (r.status === 401) { location.href = '/login'; throw new Error('Signed out'); }
        return r.json().catch(function () { return {}; }).then(function (j) {
          if (!r.ok || j.ok === false) throw new Error(j.message || 'The request failed (' + r.status + ')');
          if (j.rev) rev = j.rev;
          return j;
        });
      });
  }

  function dialog(o) {
    return new Promise(function (resolve) {
      var m = document.createElement('div');
      m.className = 'modal';
      m.innerHTML = '<form class="dialog" role="dialog" aria-modal="true"><h2>' + esc(o.title) + '</h2>' + (o.text ? '<p>' + esc(o.text) + '</p>' : '<p></p>') +
        (o.input ? '<input class="field" name="v" maxlength="80" autocomplete="off" value="' + esc(o.value || '') + '">' : '') +
        '<div class="row"><button type="button" class="btn" data-x>Cancel</button><button class="btn ' + (o.danger ? 'btn-danger' : 'btn-primary') + '">' + esc(o.ok || 'OK') + '</button></div></form>';
      document.body.appendChild(m);
      var f = $('form', m), inp = $('input', m);
      function close(v) { document.removeEventListener('keydown', key); m.remove(); resolve(v); }
      function key(e) { if (e.key === 'Escape') close(false); }
      document.addEventListener('keydown', key);
      m.addEventListener('mousedown', function (e) { if (e.target === m) close(false); });
      $('[data-x]', m).onclick = function () { close(false); };
      f.onsubmit = function (e) { e.preventDefault(); close(o.input ? inp.value.trim() : true); };
      if (inp) { inp.focus(); inp.select(); } else { $('.btn:last-child', m).focus(); }
    });
  }

  // ---- theme
  var tb = $('#theme');
  if (tb) tb.onclick = function () {
    var cur = document.documentElement.getAttribute('data-theme') || (matchMedia('(prefers-color-scheme:dark)').matches ? 'dark' : 'light');
    var next = cur === 'dark' ? 'light' : 'dark';
    document.documentElement.setAttribute('data-theme', next);
    try { localStorage.setItem('mrw-theme', next); } catch (e) {}
  };

  // ---- login
  var pin = $('#pin');
  if (pin) {
    pin.focus();
    pin.addEventListener('input', function () {
      pin.value = pin.value.replace(/\D/g, '').slice(0, 6);
      if (pin.value.length === 6) pin.form.submit();
    });
  }

  // ---- library: selection, filter, search
  function cards() { return $$('#library .card'); }
  function updateBulk() {
    var ids = Object.keys(picked), bar = $('#bulk');
    if (!bar) return;
    bar.classList.toggle('on', ids.length > 0);
    $('#bulk-n').textContent = ids.length + (ids.length === 1 ? ' canvas selected' : ' canvases selected');
    var lib = $('#library'); if (lib) lib.classList.toggle('has-sel', ids.length > 0);
  }
  function applyFilter() {
    var q = ($('#q') ? $('#q').value : '').trim().toLowerCase();
    var tab = $('.tab.on'), room = tab ? tab.getAttribute('data-room') : '';
    $$('#library .room').forEach(function (sec) {
      var any = false;
      $$('.card', sec).forEach(function (c) {
        var show = (!q || c.getAttribute('data-name').toLowerCase().indexOf(q) >= 0);
        c.style.display = show ? '' : 'none';
        if (show) any = true;
      });
      sec.style.display = (any && (!room || sec.getAttribute('data-room') === room)) ? '' : 'none';
    });
  }
  function bind() {
    $$('#library .pick input').forEach(function (cb) {
      var c = cb.closest('.card'), id = c.getAttribute('data-id');
      cb.checked = !!picked[id]; c.classList.toggle('sel', cb.checked);
      cb.onchange = function () { if (cb.checked) picked[id] = 1; else delete picked[id]; c.classList.toggle('sel', cb.checked); updateBulk(); };
    });
    $$('.tab').forEach(function (t) { t.onclick = function () { $$('.tab').forEach(function (x) { x.classList.remove('on'); }); t.classList.add('on'); applyFilter(); }; });
    var q = $('#q'); if (q) q.oninput = applyFilter;
    applyFilter(); updateBulk();
  }

  function refresh() {
    return fetch('/', { credentials: 'same-origin' }).then(function (r) {
      if (r.status === 401 || r.redirected) { location.href = '/login'; return; }
      return r.text();
    }).then(function (html) {
      if (!html) return;
      var d = new DOMParser().parseFromString(html, 'text/html');
      $$('[data-swap]').forEach(function (el) { var n = d.getElementById(el.id); if (n) el.replaceWith(n); });
      rev = d.body.getAttribute('data-rev') || rev;
      var keep = {}; cards().forEach(function (c) { keep[c.getAttribute('data-id')] = 1; });
      Object.keys(picked).forEach(function (k) { if (!keep[k]) delete picked[k]; });
      hideBanner(); bind();
    });
  }
  function hideBanner() { var b = $('#banner'); if (b) b.classList.remove('on'); }

  function selectedIds() { return Object.keys(picked); }
  function nameOf(id) { var c = $('.card[data-id="' + id + '"]'); return c ? c.getAttribute('data-name') : ''; }

  function afterChange(msg) {
    toast(msg);
    if ($('#library')) return refresh();
    location.href = '/';
  }

  function deleteCanvases(ids, label) {
    return dialog({
      title: ids.length === 1 ? 'Delete "' + label + '"?' : 'Delete ' + ids.length + ' canvases?',
      text: 'They are removed from the document on the headset. Undo in the headset brings the last ones back until the app is closed.',
      ok: 'Delete', danger: true
    }).then(function (yes) {
      if (!yes) return;
      return api('/api/delete', { ids: ids }).then(function (j) { picked = {}; return afterChange(j.message || 'Deleted'); }).catch(function (e) { toast(e.message, true); });
    });
  }

  function renameCanvas(id, cur) {
    return dialog({ title: 'Rename canvas', input: true, value: cur, ok: 'Save' }).then(function (v) {
      if (!v || v === cur) return;
      return api('/api/rename', { id: id, name: v }).then(function (j) {
        var h = $('#vtitle'); if (h) { h.textContent = j.name; document.title = j.name + ' · MR Whiteboard'; return; }
        return afterChange('Renamed to "' + j.name + '"');
      }).catch(function (e) { toast(e.message, true); });
    });
  }

  document.addEventListener('click', function (e) {
    var b = e.target.closest('[data-act]'); if (!b) return;
    var act = b.getAttribute('data-act'), card = b.closest('.card'), id = b.getAttribute('data-id') || (card && card.getAttribute('data-id'));
    if (act === 'delete') { e.preventDefault(); deleteCanvases([id], b.getAttribute('data-name') || nameOf(id)); }
    else if (act === 'rename') { e.preventDefault(); renameCanvas(id, b.getAttribute('data-name') || nameOf(id)); }
    else if (act === 'bulk-delete') { var ids = selectedIds(); if (ids.length) deleteCanvases(ids, nameOf(ids[0])); }
    else if (act === 'bulk-zip') { var s = selectedIds(); if (s.length) location.href = '/zip?ids=' + s.join(','); }
    else if (act === 'bulk-clear') { picked = {}; $$('#library .pick input').forEach(function (c) { c.checked = false; c.closest('.card').classList.remove('sel'); }); updateBulk(); }
    else if (act === 'select-all') { $$('#library .card').forEach(function (c) { if (c.style.display !== 'none' && c.closest('.room').style.display !== 'none') picked[c.getAttribute('data-id')] = 1; }); bind(); }
    else if (act === 'delete-file') {
      var rel = b.getAttribute('data-rel');
      dialog({ title: 'Delete "' + rel + '"?', text: 'The file is removed from the headset. This cannot be undone.', ok: 'Delete', danger: true }).then(function (yes) {
        if (!yes) return;
        api('/api/files/delete', { names: [rel] }).then(function (j) { afterChange(j.message || 'Deleted'); }).catch(function (err) { toast(err.message, true); });
      });
    }
    else if (act === 'refresh') { refresh(); }
  });

  // ---- upload
  var drop = $('#drop'), input = $('#file');
  function uploadAll(files) {
    var list = $('#uploads'), ok = 0, chain = Promise.resolve();
    files = Array.prototype.slice.call(files);
    files.forEach(function (f) {
      var row = document.createElement('div');
      row.className = 'up';
      var isSvg = /\.svg$/i.test(f.name) || f.type === 'image/svg+xml';
      row.innerHTML = (isSvg ? '<div class="spin"></div>' : icon('x')) + '<span class="nm">' + esc(f.name) + '</span><span class="msg">' + (isSvg ? 'Importing...' : 'Only .svg files can be imported') + '</span>';
      list.appendChild(row);
      if (!isSvg) { row.classList.add('err'); return; }
      chain = chain.then(function () {
        return fetch('/api/upload?name=' + encodeURIComponent(f.name), { method: 'POST', credentials: 'same-origin', headers: Object.assign({ 'Content-Type': 'image/svg+xml' }, HEAD), body: f })
          .then(function (r) {
            if (r.status === 401) { location.href = '/login'; throw new Error('Signed out'); }
            return r.json().catch(function () { return { ok: false, message: 'The headset sent an unexpected answer.' }; });
          })
          .then(function (j) {
            if (j.rev) rev = j.rev;
            row.className = 'up ' + (j.ok ? 'ok' : 'err');
            row.firstChild.outerHTML = icon(j.ok ? 'check' : 'x');
            $('.msg', row).textContent = j.message || (j.ok ? 'Imported' : 'Failed');
            if (j.ok) ok++;
          })
          .catch(function (e) { row.className = 'up err'; row.firstChild.outerHTML = icon('x'); $('.msg', row).textContent = e.message; });
      });
    });
    chain.then(function () { if (ok) { toast(ok + (ok === 1 ? ' canvas' : ' canvases') + ' added: they are in front of you in the headset'); refresh(); } });
  }
  if (drop && input) {
    drop.onclick = function (e) { if (e.target !== input) input.click(); };
    drop.onkeydown = function (e) { if (e.key === 'Enter' || e.key === ' ') { e.preventDefault(); input.click(); } };
    input.onchange = function () { if (input.files.length) uploadAll(input.files); input.value = ''; };
    ['dragenter', 'dragover'].forEach(function (n) { drop.addEventListener(n, function (e) { e.preventDefault(); drop.classList.add('over'); }); });
    ['dragleave', 'drop'].forEach(function (n) { drop.addEventListener(n, function (e) { e.preventDefault(); drop.classList.remove('over'); }); });
    drop.addEventListener('drop', function (e) { if (e.dataTransfer.files.length) uploadAll(e.dataTransfer.files); });
    window.addEventListener('dragover', function (e) { e.preventDefault(); });
    window.addEventListener('drop', function (e) { if (!drop.contains(e.target)) { e.preventDefault(); if (e.dataTransfer.files.length) uploadAll(e.dataTransfer.files); } });
  }

  // ---- viewer
  var img = $('#vimg');
  if (img) {
    var zoom = 1;
    var setZoom = function (z) { zoom = Math.max(0.25, Math.min(6, z)); img.style.width = (zoom * 100) + '%'; $('#zv').textContent = Math.round(zoom * 100) + '%'; };
    $('#zin').onclick = function () { setZoom(zoom * 1.25); };
    $('#zout').onclick = function () { setZoom(zoom / 1.25); };
    $('#zfit').onclick = function () { setZoom(1); };
    document.addEventListener('keydown', function (e) {
      if (e.target.closest('input,textarea')) return;
      if (e.key === 'ArrowLeft' && $('#prev')) location.href = $('#prev').href;
      else if (e.key === 'ArrowRight' && $('#next')) location.href = $('#next').href;
      else if (e.key === '+' || e.key === '=') setZoom(zoom * 1.25);
      else if (e.key === '-') setZoom(zoom / 1.25);
      else if (e.key === '0') setZoom(1);
    });
  }

  // ---- changes made in the headset
  var failures = 0;
  function poll() {
    fetch('/api/rev', { credentials: 'same-origin', cache: 'no-store' }).then(function (r) {
      if (r.status === 401) { location.href = '/login'; return null; }
      return r.json();
    }).then(function (j) {
      if (!j) return;
      failures = 0; var live = $('.live'); if (live) live.classList.remove('off');
      if (j.rev !== rev) { var b = $('#banner'); if (b) b.classList.add('on'); }
    }).catch(function () { if (++failures > 1) { var live = $('.live'); if (live) live.classList.add('off'); } });
  }
  if ($('.live')) setInterval(poll, 4000);
  var rb = $('#banner-refresh'); if (rb) rb.onclick = function () { if ($('#library')) refresh(); else location.reload(); };

  bind();
})();
"""
