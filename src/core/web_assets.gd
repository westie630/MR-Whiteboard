class_name WebAssets
extends RefCounted
## The stylesheet, the script and the icons of the web pages the app serves (see ExportServer / WebPages). Kept as strings so they
## travel inside the app without any extra files in the export.

const VERSION := 9                      # bump when CSS / JS change: it is part of their address so browsers fetch the new ones

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
<symbol id="i-spark" viewBox="0 0 24 24"><path d="M12 3.5 13.9 9.6 20 11.5 13.9 13.4 12 19.5 10.1 13.4 4 11.5 10.1 9.6Z"/><path d="M19 3v3M17.5 4.5h3"/></symbol>
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
[hidden]{display:none!important}
.lv:fullscreen{background:var(--bg);overflow:auto;padding:20px}
.lv-bar{display:flex;flex-wrap:wrap;gap:14px;align-items:flex-end;justify-content:space-between;margin-bottom:18px}
.lv-ctl{display:flex;flex-wrap:wrap;gap:10px;align-items:center}
.lv-note{margin:-6px 0 14px;font-size:13px;color:var(--muted)}
.lv-note.bad{color:var(--bad)}
.lv-follow{display:none;align-items:center;gap:7px;font-size:13.5px;font-weight:600;color:var(--ink-2);cursor:pointer}
.lv[data-mode=focus] .lv-follow{display:inline-flex}
.lv-nav{display:none;align-items:center;gap:12px;margin-bottom:12px}
.lv[data-mode=focus] .lv-nav{display:flex}
.lv-nav b{margin-right:auto;font-size:17px}
.lv-nav .btn[disabled]{opacity:.35}
.lv-grid{display:grid;grid-template-columns:repeat(auto-fill,minmax(min(340px,100%),1fr));gap:16px}
.lv[data-mode=focus] .lv-grid{grid-template-columns:1fr}
.lv[data-mode=focus] .tile:not(.cur),.lv[data-mode=focus] .room-h{display:none}
.tile{margin:0;background:var(--surface);border:1px solid var(--line);border-radius:var(--r);overflow:hidden;box-shadow:var(--shadow-1);transition:box-shadow .5s,border-color .3s}
.tile figcaption{display:flex;align-items:center;gap:8px;padding:10px 14px;border-bottom:1px solid var(--line);min-width:0}
.tile figcaption b{overflow:hidden;text-overflow:ellipsis;white-space:nowrap;margin-right:auto}
.tile .pen{display:none;align-items:center;gap:6px;font-size:11.5px;font-weight:650;padding:2px 9px;border-radius:99px;background:var(--brand-soft);color:var(--brand);flex:none}
.tile .pen::before{content:"";width:7px;height:7px;border-radius:50%;background:var(--brand)}
.tile.active{border-color:var(--brand)}
.tile.active .pen{display:inline-flex}
.tile.fresh{box-shadow:0 0 0 3px color-mix(in srgb,var(--brand) 38%,transparent);transition:none}
.shot{position:relative;aspect-ratio:3/2;background:var(--thumb);cursor:zoom-in}
.shot img{position:absolute;inset:10px;width:calc(100% - 20px);height:calc(100% - 20px);object-fit:contain}
.shot.bg-dark{background:#14181f}
.shot.bg-none{background:conic-gradient(#d4d8e0 25%,#fff 0 50%,#d4d8e0 0 75%,#fff 0) 0 0/20px 20px}
.lv[data-mode=focus] .shot{aspect-ratio:auto;height:calc(100vh - 250px);min-height:280px;cursor:default}
.lv:fullscreen[data-mode=focus] .shot{height:calc(100vh - 170px)}
.ai-grid{display:grid;grid-template-columns:minmax(0,1.2fr) minmax(0,1fr);gap:22px;align-items:start}
.ai .panel{margin-top:0}
.ai-body{padding:16px 18px;display:grid;gap:12px}
.lbl{font-size:12px;font-weight:650;letter-spacing:.06em;text-transform:uppercase;color:var(--muted);margin-bottom:-6px}
.ai-acts{display:flex;flex-wrap:wrap;gap:8px}
.field.ta{height:auto;padding:10px 13px;resize:vertical;line-height:1.45}
select.field{padding:0 10px;min-width:0;max-width:100%;text-overflow:ellipsis}
.ai-row{display:flex;align-items:flex-end;gap:8px;flex-wrap:wrap}
.ai-row .spacer{flex:1}
.ai-status{display:flex;gap:10px;align-items:center;color:var(--muted);font-size:14px;min-height:20px}
.ai-status.bad{color:var(--bad)}
.ai-reply{border:1px solid var(--line);border-radius:var(--r-sm);background:var(--surface-2);padding:12px 14px}
.ai-meta{font-size:12.5px;color:var(--muted);margin-bottom:6px}
.ai-say{white-space:pre-wrap;line-height:1.55}
.ai-layers{display:grid;gap:8px}
.ai-layers:empty{display:none}
.layer{display:flex;flex-wrap:wrap;align-items:center;gap:10px;padding:12px 14px;border:1px solid color-mix(in srgb,var(--brand) 40%,var(--line));border-radius:var(--r-sm);background:var(--brand-soft)}
.layer>div{flex:1;min-width:200px;display:grid}
.layer span{font-size:13px;color:var(--muted)}
.ai-provs{display:grid;gap:12px}
.prov{min-width:0;border:1px solid var(--line);border-radius:var(--r-sm);padding:12px 14px;display:grid;gap:10px;background:var(--surface)}
.prov.on{border-color:var(--brand);box-shadow:0 0 0 2px color-mix(in srgb,var(--brand) 25%,transparent)}
.prov-h{display:flex;flex-wrap:wrap;align-items:center;gap:10px}
.prov-h .use{display:flex;align-items:center;gap:8px;cursor:pointer;margin-right:auto}
.prov-h .get{font-size:13px;white-space:nowrap}
.prov .key{flex:1 1 160px;min-width:0}
.sel{display:grid;gap:3px;flex:1 1 150px;min-width:0}
.sel span{font-size:12px;color:var(--muted);font-weight:600}
.note{font-size:13px;color:var(--muted)}
.note.bad{color:var(--bad)}
.chk{display:flex;gap:8px;align-items:flex-start;font-size:14px;color:var(--ink-2);cursor:pointer}
.chk input{margin-top:3px}
@media(max-width:900px){.ai-grid{grid-template-columns:minmax(0,1fr)}}
@media(max-width:700px){.topbar-in .btn span{display:none}.topbar-in{gap:6px}}
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
    else if (act === 'pdf-show') {
      api('/api/pdf/show', { id: b.getAttribute('data-id') }).then(function () { toast('It is in front of you in the headset'); }).catch(function (err) { toast(err.message, true); });
    }
    else if (act === 'pdf-delete') {
      var pid = b.getAttribute('data-id'), pname = b.getAttribute('data-name');
      dialog({ title: 'Delete "' + pname + '"?', text: 'The PDF is removed from the headset. Canvases that show it keep their drawings but lose the pages until it is uploaded again.', ok: 'Delete', danger: true }).then(function (yes) {
        if (!yes) return;
        api('/api/pdf/delete', { ids: [pid] }).then(function (j) { afterChange(j.message || 'Deleted'); }).catch(function (err) { toast(err.message, true); });
      });
    }
    else if (act === 'pdf-rename') {
      var rid = b.getAttribute('data-id'), rcur = b.getAttribute('data-name');
      dialog({ title: 'Rename PDF', input: true, value: rcur, ok: 'Save' }).then(function (v) {
        if (!v || v === rcur) return;
        api('/api/pdf/rename', { id: rid, name: v }).then(function () { afterChange('Renamed'); }).catch(function (err) { toast(err.message, true); });
      });
    }
    else if (act === 'refresh') { refresh(); }
  });

  // ---- upload
  var drop = $('#drop'), input = $('#file');
  function uploadAll(files) {
    var list = $('#uploads'), ok = 0, pdfs = 0, chain = Promise.resolve();
    files = Array.prototype.slice.call(files);
    files.forEach(function (f) {
      var row = document.createElement('div');
      row.className = 'up';
      var isSvg = /\.svg$/i.test(f.name) || f.type === 'image/svg+xml';
      var isPdf = /\.pdf$/i.test(f.name) || f.type === 'application/pdf';
      var okType = isSvg || isPdf;
      row.innerHTML = (okType ? '<div class="spin"></div>' : icon('x')) + '<span class="nm">' + esc(f.name) + '</span><span class="msg">' + (okType ? (isPdf ? 'Sending to the headset...' : 'Importing...') : 'Only .pdf and .svg files can be added') + '</span>';
      list.appendChild(row);
      if (!okType) { row.classList.add('err'); return; }
      chain = chain.then(function () {
        var url = isPdf ? '/api/pdf?name=' + encodeURIComponent(f.name) : '/api/upload?name=' + encodeURIComponent(f.name);
        return fetch(url, { method: 'POST', credentials: 'same-origin', headers: Object.assign({ 'Content-Type': isPdf ? 'application/pdf' : 'image/svg+xml' }, HEAD), body: f })
          .then(function (r) {
            if (r.status === 401) { location.href = '/login'; throw new Error('Signed out'); }
            return r.json().catch(function () { return { ok: false, message: 'The headset sent an unexpected answer.' }; });
          })
          .then(function (j) {
            if (j.rev) rev = j.rev;
            row.className = 'up ' + (j.ok ? 'ok' : 'err');
            row.firstChild.outerHTML = icon(j.ok ? 'check' : 'x');
            $('.msg', row).textContent = j.message || (j.ok ? 'Done' : 'Failed');
            if (j.ok) { ok++; if (isPdf) pdfs++; }
          })
          .catch(function (e) { row.className = 'up err'; row.firstChild.outerHTML = icon('x'); $('.msg', row).textContent = e.message; });
      });
    });
    chain.then(function () { if (ok) { toast(ok + (ok === 1 ? ' file' : ' files') + ' added: ' + (pdfs ? 'it is in front of you in the headset' : 'they are in front of you in the headset')); refresh(); } });
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
  var livePage = document.body.getAttribute('data-page') === 'live' || document.body.getAttribute('data-page') === 'ai';
  if ($('.live') && !livePage) setInterval(poll, 4000);
  var rb = $('#banner-refresh'); if (rb) rb.onclick = function () { if ($('#library')) refresh(); else location.reload(); };

  // ---- live view: the canvases of the open document, redrawn when the headset changes them
  var lv = $('#lv');
  if (lv) {
    var lvBody = $('#lv-body'), tiles = {}, sections = {}, sectionOrder = [], docId = null, since = '', active = '', here = '';
    var lvFails = 0, lvTimer = null, firstDraw = true, total = 0, order = [], focusId = '';
    var keep = function (k, v) { try { if (v === undefined) return localStorage.getItem(k); localStorage.setItem(k, v); } catch (e) {} return null; };
    var mode = keep('mrw-lv-mode') === 'focus' ? 'focus' : 'grid';
    var bg = ['auto', 'white', 'dark', 'none'].indexOf(keep('mrw-lv-bg')) >= 0 ? keep('mrw-lv-bg') : 'auto';
    var follow = keep('mrw-lv-follow') === '1';

    var setConn = function (ok) { var live = $('.live'); if (live) { live.classList.toggle('off', !ok); $('span', live).textContent = ok ? 'Connected' : 'Reconnecting...'; } };
    var lookOf = function (f) { return bg === 'auto' ? (f.look || 'dark') : bg; };
    var shotUrl = function (f) { return '/svg/' + encodeURIComponent(f.id) + '.svg?bg=' + lookOf(f) + '&v=' + encodeURIComponent(f.rev); };

    // ---- translation: the browser's own on-device translator (Translator, LanguageDetector). The text is translated in this browser on
    // this PC and nothing is sent anywhere. Each text on a canvas is translated from the language it is detected to be in.
    var LANGS = { es: 'Spanish', eu: 'Basque', fr: 'French' }, NAMES = { en: 'English', es: 'Spanish', eu: 'Basque', fr: 'French', ca: 'Catalan', gl: 'Galician', de: 'German', it: 'Italian', pt: 'Portuguese' };
    var lang = keep('mrw-lv-lang');
    if (!LANGS[lang]) lang = '';
    var trNote = $('#lv-tr-note'), translators = {}, trCache = {}, trMissing = {}, detector = null, trBusy = 0;
    var note = function (msg, bad) { trNote.textContent = msg || ''; trNote.hidden = !msg; trNote.classList.toggle('bad', !!bad); };
    var langName = function (c) { return NAMES[c] || c; };
    var unsupported = function () {
      if (!window.isSecureContext) return 'Chrome only translates on https or localhost pages. Open this page as http://localhost:' + (location.port || '80') + ' after running "adb forward tcp:' + (location.port || '80') + ' tcp:' + (location.port || '80') + '", or allow this address in chrome://flags/#unsafely-treat-insecure-origin-as-secure.';
      if (!('Translator' in self)) return 'Translation needs Chrome or Edge 138 or newer on a PC.';
      return '';
    };
    var refreshNote = function () {
      var miss = Object.keys(trMissing).filter(function (k) { return k.split('>')[1] === lang; });
      if (!lang) note('');
      else if (miss.length) note('This browser has no ' + langName(miss[0].split('>')[0]) + ' to ' + langName(lang) + ' translator, so some text is left as it is.', true);
      else note('Translated on this PC by your browser. Nothing is sent anywhere.');
    };

    var getTranslator = function (src, tgt) {
      var k = src + '>' + tgt;
      if (!translators[k]) {
        translators[k] = Translator.availability({ sourceLanguage: src, targetLanguage: tgt }).then(function (a) {
          if (a === 'unavailable') { trMissing[k] = 1; return null; }
          return Translator.create({ sourceLanguage: src, targetLanguage: tgt, monitor: function (m) {
            m.addEventListener('downloadprogress', function (e) { note('Downloading the ' + langName(src) + ' to ' + langName(tgt) + ' language pack: ' + Math.round(e.loaded * 100) + '%'); });
          } });
        }).catch(function (e) { delete translators[k]; throw e; });
      }
      return translators[k];
    };

    // The language a text is in, or null when the detector is not sure.
    var detect = function (text) {
      if (!detector) return Promise.resolve(null);
      return detector.detect(text).then(function (r) {
        return r && r[0] && r[0].confidence >= 0.6 && r[0].detectedLanguage !== 'und' ? r[0].detectedLanguage : null;
      }).catch(function () { return null; });
    };

    // fallback: the language of the whole canvas, for short labels the detector cannot place by themselves
    var translateText = function (text, fallback) {
      var key = lang + '|' + fallback + '|' + text;
      if (trCache[key] !== undefined) return Promise.resolve(trCache[key]);
      var tgt = lang;
      return detect(text).then(function (src) {
        src = src || fallback;
        if (src === tgt) return text;
        return getTranslator(src, tgt).then(function (tr) { return tr ? tr.translate(text) : text; });
      }).then(function (out) { trCache[key] = out; return out; });
    };

    var widest = function (s) { return s.split('\n').reduce(function (m, l) { return Math.max(m, l.length); }, 1); };

    // Puts translated lines into a <text> of the exported SVG (centred on the same point, as the exporter writes it), shrunk to the
    // width of the original when the translation is longer.
    var refit = function (doc, el, orig, out) {
      if (out === orig) return;
      var spans = el.getElementsByTagName('tspan'), size = parseFloat(el.getAttribute('font-size')) || 12;
      var x = spans[0].getAttribute('x'), cy = parseFloat(spans[0].getAttribute('y')) + (0.6 * spans.length - 0.95) * size;
      var lines = out.split('\n'), n = lines.length, y0 = cy - (0.6 * n - 0.95) * size;
      while (el.firstChild) el.removeChild(el.firstChild);
      lines.forEach(function (ln, i) {
        var s = doc.createElementNS(el.namespaceURI, 'tspan');
        s.setAttribute('x', x); s.setAttribute('y', (y0 + i * 1.2 * size).toFixed(2)); s.textContent = ln;
        el.appendChild(s);
      });
      var w0 = widest(orig), w1 = widest(out);
      if (w1 > w0 * 1.05) {
        var k = Math.max(0.55, w0 * 1.05 / w1);
        el.setAttribute('transform', ((el.getAttribute('transform') || '') + ' translate(' + x + ' ' + cy.toFixed(2) + ') scale(' + k.toFixed(3) + ') translate(-' + x + ' -' + cy.toFixed(2) + ')').trim());
      }
    };

    // SVG text in, SVG text out with every text on the canvas translated.
    var translateSvg = function (svg) {
      var doc = new DOMParser().parseFromString(svg, 'image/svg+xml');
      if (doc.getElementsByTagName('parsererror').length) return Promise.resolve(svg);
      var els = $$('text', doc).filter(function (el) { return el.getElementsByTagName('tspan').length; });
      var texts = els.map(function (el) { return $$('tspan', el).map(function (s) { return s.textContent; }).join('\n'); });
      var letters = /\p{L}/u;
      return detect(texts.join('\n')).then(function (dom) {
        return Promise.all(texts.map(function (t) { return letters.test(t) ? translateText(t, dom || 'en') : t; }));
      }).then(function (out) {
        els.forEach(function (el, i) { refit(doc, el, texts[i], out[i]); });
        return new XMLSerializer().serializeToString(doc);
      });
    };

    var onTranslateFail = function (e) {
      var denied = e && e.name === 'NotAllowedError';
      lang = ''; keep('mrw-lv-lang', '');
      note(denied ? 'The browser wants a click before it downloads a language pack: pick the language again.' : 'Translation failed: ' + ((e && e.message) || 'unknown error'), true);
      redrawAll(); syncView();
    };

    var setLang = function (l) {
      if (!l) { lang = ''; keep('mrw-lv-lang', ''); refreshNote(); redrawAll(); syncView(); return; }
      var why = unsupported();
      if (why) { note(why, true); return; }
      lang = l; keep('mrw-lv-lang', l); trMissing = {};
      note('Getting the ' + LANGS[l] + ' translator...');
      syncView();
      // started inside the click, so the browser may download a language pack
      var ready = [getTranslator('en', l)];
      if (!detector && 'LanguageDetector' in self) ready.push(LanguageDetector.create().then(function (d) { detector = d; }, function () {}));
      Promise.all(ready).then(function () { if (lang === l) redrawAll(); }).catch(onTranslateFail);
    };

    var makeTile = function (f) {
      var el = document.createElement('figure');
      el.className = 'tile';
      el.setAttribute('data-id', f.id);
      el.innerHTML = '<figcaption><b></b><span class="pen">Drawing here</span></figcaption><div class="shot bg-' + lookOf(f) + '" tabindex="0" title="Show this canvas large"><img alt=""></div>';
      var t = { el: el, name: $('b', el), shot: $('.shot', el), img: $('img', el), rev: null, want: null, bg: null, lang: '', f: f };
      tiles[f.id] = t;
      return t;
    };

    // The picture is loaded off screen first, so a redraw never flashes an empty frame.
    var showPicture = function (t) {
      var f = t.f, look = lookOf(f), tag = lang;
      if (t.rev === f.rev && t.bg === look && t.lang === tag) return;
      if (t.want === f.rev + look + tag) return;
      t.want = f.rev + look + tag;
      var want = t.want, pre = new Image();
      pre.onload = function () {
        if (t.want !== want) return;
        t.img.src = pre.src; t.img.alt = f.name;
        t.shot.className = 'shot bg-' + look;
        var redraw = t.rev !== null && t.rev !== f.rev;
        t.rev = f.rev; t.bg = look; t.lang = tag;
        if (redraw) {
          t.el.classList.add('fresh');
          setTimeout(function () { t.el.classList.remove('fresh'); }, 900);
        }
      };
      pre.onerror = function () { t.want = null; since = ''; };
      var url = shotUrl(f);
      if (!tag) { pre.src = url; return; }
      // translated: the exporter's SVG is fetched, its texts are replaced, and the result is shown as a data address
      trBusy++;
      fetch(url, { credentials: 'same-origin' }).then(function (r) {
        if (!r.ok) throw new Error(String(r.status));
        return r.text();
      }).then(translateSvg).then(function (svg) {
        return 'data:image/svg+xml;charset=utf-8,' + encodeURIComponent(svg);
      }).then(function (data) {
        if (t.want === want) pre.src = data;
      }, function (e) {
        if (t.want === want) { t.want = null; if (lang === tag) onTranslateFail(e); }
      }).then(function () { if (--trBusy === 0 && lang) refreshNote(); });
    };

    var redrawAll = function () { Object.keys(tiles).forEach(function (id) { showPicture(tiles[id]); }); };

    var sectionFor = function (g) {
      var s = sections[g.id];
      if (!s) {
        var el = document.createElement('section');
        el.className = 'room';
        el.innerHTML = '<div class="room-h">' + icon('room') + '<h2></h2><span class="tag" hidden>here now</span></div><div class="lv-grid"></div>';
        s = sections[g.id] = { el: el, title: $('h2', el), tag: $('.tag', el), grid: $('.lv-grid', el) };
      }
      return s;
    };

    var place = function (parent, el, i) { if (parent.children[i] !== el) parent.insertBefore(el, parent.children[i] || null); };

    var build = function (groups) {
      var seen = {}, seenSec = {}, gi = 0;
      order = []; total = 0;
      groups.forEach(function (g) {
        var s = sectionFor(g);
        seenSec[g.id] = 1;
        s.title.textContent = g.name;
        place(lvBody, s.el, gi++);
        g.frames.forEach(function (f, i) {
          var t = tiles[f.id] || makeTile(f);
          t.f = f; seen[f.id] = 1; total++;
          order.push(f.id);
          t.name.textContent = f.name;
          place(s.grid, t.el, i);
          showPicture(t);
        });
      });
      Object.keys(tiles).forEach(function (id) { if (!seen[id]) { tiles[id].el.remove(); delete tiles[id]; } });
      Object.keys(sections).forEach(function (id) { if (!seenSec[id]) { sections[id].el.remove(); delete sections[id]; } });
      $('#lv-empty').hidden = total > 0;
    };

    var syncView = function () {
      if (follow && mode === 'focus' && tiles[active]) focusId = active;
      if (!tiles[focusId]) focusId = order[0] || '';
      lv.setAttribute('data-mode', mode);
      $$('#lv-mode button').forEach(function (b) { b.classList.toggle('on', b.getAttribute('data-mode') === mode); });
      $$('#lv-bg button').forEach(function (b) { b.classList.toggle('on', b.getAttribute('data-bg') === bg); });
      $$('#lv-lang button').forEach(function (b) { b.classList.toggle('on', b.getAttribute('data-lang') === lang); });
      $('#lv-follow').checked = follow;
      Object.keys(tiles).forEach(function (id) {
        tiles[id].el.classList.toggle('active', id === active);
        tiles[id].el.classList.toggle('cur', id === focusId);
      });
      Object.keys(sections).forEach(function (id) {
        var s = sections[id];
        s.tag.hidden = id !== here;
        s.el.hidden = mode === 'focus' && !$('.cur', s.el);
      });
      var at = order.indexOf(focusId);
      $('#lv-prev').disabled = at <= 0;
      $('#lv-next').disabled = at < 0 || at >= order.length - 1;
      $('#lv-cur').textContent = tiles[focusId] ? tiles[focusId].f.name : '';
      $('#lv-stat').textContent = total === 0 ? 'No canvases' : total + (total === 1 ? ' canvas' : ' canvases') + ' · updated live';
    };

    var apply = function (j) {
      if (docId !== j.doc.id) {
        docId = j.doc.id; since = '';
        Object.keys(tiles).forEach(function (id) { tiles[id].el.remove(); });
        Object.keys(sections).forEach(function (id) { sections[id].el.remove(); });
        tiles = {}; sections = {}; order = []; focusId = ''; firstDraw = true;
      }
      $('#lv-name').textContent = j.doc.name;
      document.title = j.doc.name + ' · Live · MR Whiteboard';
      active = j.active; here = j.here;
      if (j.groups) build(j.groups);
      since = j.seq;
      syncView();
    };

    var tick = function () {
      fetch('/api/live?since=' + encodeURIComponent(since), { credentials: 'same-origin', cache: 'no-store' }).then(function (r) {
        if (r.status === 401) { location.href = '/login'; return null; }
        if (!r.ok) throw new Error(String(r.status));
        return r.json();
      }).then(function (j) {
        if (!j) return;
        lvFails = 0; setConn(true); apply(j);
      }).catch(function () {
        if (++lvFails > 1) setConn(false);
      }).then(function () {
        clearTimeout(lvTimer);
        lvTimer = setTimeout(tick, document.hidden ? 3000 : Math.min(8000, 600 + lvFails * 1200));
      });
    };

    var setMode = function (m) { mode = m; keep('mrw-lv-mode', m); syncView(); };
    var step = function (d) { var at = order.indexOf(focusId) + d; if (at >= 0 && at < order.length) { focusId = order[at]; follow = false; keep('mrw-lv-follow', '0'); syncView(); } };

    lv.addEventListener('click', function (e) {
      var m = e.target.closest('#lv-mode button'), b = e.target.closest('#lv-bg button'), shot = e.target.closest('.shot'), tl = e.target.closest('#lv-lang button');
      if (tl) setLang(tl.getAttribute('data-lang'));
      else if (m) setMode(m.getAttribute('data-mode'));
      else if (b) {
        bg = b.getAttribute('data-bg'); keep('mrw-lv-bg', bg);
        Object.keys(tiles).forEach(function (id) { showPicture(tiles[id]); });
        syncView();
      }
      else if (shot && mode === 'grid') { focusId = shot.closest('.tile').getAttribute('data-id'); follow = false; keep('mrw-lv-follow', '0'); setMode('focus'); }
      else if (e.target.closest('#lv-prev')) step(-1);
      else if (e.target.closest('#lv-next')) step(1);
      else if (e.target.closest('#lv-full')) {
        if (document.fullscreenElement) document.exitFullscreen();
        else if (lv.requestFullscreen) lv.requestFullscreen();
      }
    });
    $('#lv-follow').onchange = function () { follow = this.checked; keep('mrw-lv-follow', follow ? '1' : '0'); syncView(); };
    lv.addEventListener('keydown', function (e) { if (e.key === 'Enter' && e.target.classList.contains('shot') && mode === 'grid') e.target.click(); });
    document.addEventListener('keydown', function (e) {
      if (e.target.closest && e.target.closest('input,textarea')) return;
      if (e.key === 'Escape' && mode === 'focus' && !document.fullscreenElement) setMode('grid');
      else if (mode === 'focus' && e.key === 'ArrowLeft') step(-1);
      else if (mode === 'focus' && e.key === 'ArrowRight') step(1);
    });
    document.addEventListener('visibilitychange', function () { if (!document.hidden) { clearTimeout(lvTimer); tick(); } });
    // a language kept from last time is used again if the browser can do it without a click (the pack is already downloaded)
    if (lang) {
      var saved = lang;
      lang = '';
      if (!unsupported()) {
        Translator.availability({ sourceLanguage: 'en', targetLanguage: saved }).then(function (a) {
          if (a !== 'available') return;
          var ready = 'LanguageDetector' in self ? LanguageDetector.create().then(function (d) { detector = d; }, function () {}) : Promise.resolve();
          return ready.then(function () { lang = saved; refreshNote(); syncView(); redrawAll(); });
        }).catch(function () {});
      }
    }
    syncView();
    tick();
  }

  // ---- AI assistant: keys, models and thinking levels per provider, asking about a canvas, its suggestion layers
  var ai = $('#ai');
  if (ai) {
    var st = null, aiTimer = null, aiFails = 0, built = false, canvasPick = '';
    var provBox = $('#ai-provs');
    var post = function (cmd, body) { return api('/api/ai/' + cmd, body); };
    var fail = function (e) { toast(e.message, true); };
    var curName = function (id) { var c = st.canvases.filter(function (x) { return x.id === id; })[0]; return c ? c.name : ''; };
    var modelName = function (p) { var m = p.models.filter(function (x) { return x.id === p.model; })[0]; return m ? m.name : p.model; };

    var buildProviders = function (list) {
      provBox.innerHTML = '';
      list.forEach(function (p) {
        var el = document.createElement('div');
        el.className = 'prov';
        el.setAttribute('data-p', p.id);
        el.innerHTML = '<div class="prov-h"><label class="use"><input type="radio" name="ai-use" value="' + esc(p.id) + '"><b>' + esc(p.name) + '</b></label>' +
          '<span class="chip keyhint"></span><a class="get" target="_blank" rel="noopener" href="' + esc(p.keys_url) + '">Get a key</a></div>' +
          '<div class="ai-row"><input class="field key" type="password" autocomplete="off" spellcheck="false" placeholder="Paste your ' + esc(p.name) + ' API key">' +
          '<button class="btn" data-k="save">Save</button><button class="icon-btn danger" data-k="remove" title="Remove the key">' + icon('trash') + '</button></div>' +
          '<div class="ai-row"><label class="sel"><span>Model</span><select class="field model"></select></label>' +
          '<label class="sel"><span>Thinking</span><select class="field mode"></select></label>' +
          '<button class="icon-btn" data-k="refresh" title="Fetch the model list again">' + icon('refresh') + '</button></div>' +
          '<div class="note"></div>';
        provBox.appendChild(el);
      });
      built = true;
    };

    // a <select> is only rebuilt when its options change, and never while it is open
    var fillSelect = function (sel, opts, cur) {
      if (document.activeElement === sel) return;
      var sig = JSON.stringify(opts) + '|' + cur;
      if (sel.getAttribute('data-sig') === sig) return;
      sel.setAttribute('data-sig', sig);
      sel.innerHTML = opts.map(function (o) { return '<option value="' + esc(o[0]) + '">' + esc(o[1]) + '</option>'; }).join('');
      sel.value = cur;
    };

    var render = function () {
      if (!built) buildProviders(st.providers);
      st.providers.forEach(function (p) {
        var el = $('.prov[data-p="' + p.id + '"]');
        if (!el) return;
        el.classList.toggle('on', st.provider === p.id);
        $('input[type=radio]', el).checked = st.provider === p.id;
        var kh = $('.keyhint', el);
        kh.textContent = p.has_key ? 'Key ' + p.key_hint : 'No key';
        kh.classList.toggle('here', p.has_key);
        var models = p.models.map(function (m) { return [m.id, m.name === m.id ? m.id : m.name + ' (' + m.id + ')']; });
        if (!models.some(function (m) { return m[0] === p.model; })) models.unshift([p.model, p.model === '' ? (p.has_key ? 'Fetch the list (button on the right)' : 'Add a key to list the models') : p.model + (p.models.length ? ' (not in the list)' : '')]);
        fillSelect($('.model', el), models, p.model);
        fillSelect($('.mode', el), p.modes, p.mode);
        var note = $('.note', el);
        note.className = 'note' + (p.error && !p.fetching ? ' bad' : '');
        note.textContent = p.fetching ? 'Fetching the model list...' : p.error ? p.error : !p.has_key ? 'Paste a key to fetch the models.' :
          p.exact_modes ? 'Thinking levels as ' + p.name + ' reports them for this model.' : 'Thinking levels are the documented ones for this model family; one the model refuses is left out.';
      });
      var cs = $('#ai-canvas');
      var here = curName(st.target);
      fillSelect(cs, [['', 'The one in front of you' + (here ? ' (' + here + ')' : '')]].concat(st.canvases.map(function (c) { return [c.id, c.name + ' · ' + c.items + ' items']; })), canvasPick);
      var acts = $('#ai-acts');
      if (!acts.childElementCount) acts.innerHTML = st.actions.map(function (a) { return '<button class="btn" data-ai="' + esc(a[0]) + '" title="' + (a[2] ? 'Draws a suggestion you accept or discard' : 'Answers in words') + '">' + esc(a[1]) + '</button>'; }).join('');
      $$('#ai-acts .btn, #ai-send').forEach(function (b) { b.disabled = st.busy; });
      $('#ai-picture').checked = st.picture;
      $('#ai-note').checked = st.note;
      var cur = st.providers.filter(function (p) { return p.id === st.provider; })[0];
      $('#ai-stat').textContent = cur ? (cur.has_key ? cur.name + ' · ' + modelName(cur) : 'Add a ' + cur.name + ' key to start') : '';
      var stat = $('#ai-status');
      stat.className = 'ai-status' + (st.last && st.last.error && !st.busy ? ' bad' : '');
      stat.innerHTML = (st.busy ? '<div class="spin"></div>' : '') + '<span>' + esc(st.status || '') + '</span>';
      var rep = $('#ai-reply');
      rep.hidden = !(st.last && st.last.say);
      if (!rep.hidden) {
        $('#ai-meta').textContent = st.last.model + ' · ' + st.last.label + (st.last.seconds ? ' · ' + st.last.seconds + ' s' : '');
        $('#ai-say').textContent = st.last.say;
      }
      var lay = $('#ai-layers'), sig = JSON.stringify(st.layers);
      if (lay.getAttribute('data-sig') !== sig) {
        lay.setAttribute('data-sig', sig);
        lay.innerHTML = st.layers.map(function (l) {
          return '<div class="layer" data-f="' + esc(l.frame) + '"><div><b>Suggestion on ' + esc(l.name) + '</b><span>' + esc(l.counts) + ' · ' + esc(l.model) + ' · ' + esc(l.label) + '</span></div>' +
            '<label class="chk"><input type="checkbox" data-l="show"' + (l.visible ? ' checked' : '') + '> Shown in the headset</label>' +
            '<button class="btn btn-primary btn-sm" data-l="accept">' + icon('check') + ' Accept</button><button class="btn btn-sm" data-l="discard">' + icon('x') + ' Discard</button></div>';
        }).join('');
      }
    };

    var load = function () {
      fetch('/api/ai/state', { credentials: 'same-origin', cache: 'no-store' }).then(function (r) {
        if (r.status === 401) { location.href = '/login'; return null; }
        if (!r.ok) throw new Error(String(r.status));
        return r.json();
      }).then(function (j) {
        if (!j) return;
        aiFails = 0; st = j; render();
        var live = $('.live'); if (live) live.classList.remove('off');
      }).catch(function () {
        if (++aiFails > 1) { var live = $('.live'); if (live) live.classList.add('off'); }
      }).then(function () {
        clearTimeout(aiTimer);
        var waiting = st && (st.busy || st.providers.some(function (p) { return p.fetching; }));
        aiTimer = setTimeout(load, waiting ? 1000 : (document.hidden ? 8000 : 3000));
      });
    };
    var soon = function () { clearTimeout(aiTimer); aiTimer = setTimeout(load, 250); };
    var ask = function (action, text) {
      post('ask', { action: action, text: text, frame: canvasPick }).then(function () { if (action === 'ask') $('#ai-q').value = ''; soon(); }).catch(function (e) { fail(e); soon(); });
    };
    var saveKey = function (prov) {
      var inp = $('.key', prov), v = inp.value.trim();
      if (!v) { inp.focus(); return; }
      post('key', { provider: prov.getAttribute('data-p'), key: v, use: '1' }).then(function (j) { inp.value = ''; toast(j.message); soon(); }).catch(fail);
    };

    ai.addEventListener('click', function (e) {
      var b = e.target.closest('button'); if (!b) return;
      var prov = b.closest('.prov'), p = prov && prov.getAttribute('data-p'), k = b.getAttribute('data-k');
      if (k === 'save') saveKey(prov);
      else if (k === 'remove') {
        dialog({ title: 'Remove the ' + $('b', prov).textContent + ' key?', text: 'The headset forgets this API key.', ok: 'Remove', danger: true }).then(function (yes) {
          if (yes) post('key', { provider: p, key: '' }).then(function (j) { toast(j.message); soon(); }).catch(fail);
        });
      }
      else if (k === 'refresh') post('refresh', { provider: p }).then(soon).catch(fail);
      else if (b.hasAttribute('data-ai')) ask(b.getAttribute('data-ai'), '');
      else if (b.id === 'ai-send') { var q = $('#ai-q').value.trim(); if (!q) { $('#ai-q').focus(); return; } ask('ask', q); }
      else if (b.id === 'ai-forget') post('forget', { frame: canvasPick }).then(function (j) { toast(j.message); soon(); }).catch(fail);
      else if (b.hasAttribute('data-l')) post(b.getAttribute('data-l'), { frame: b.closest('.layer').getAttribute('data-f') }).then(function (j) { toast(j.message || 'Done'); soon(); }).catch(fail);
    });
    ai.addEventListener('change', function (e) {
      var t = e.target, prov = t.closest('.prov'), p = prov && prov.getAttribute('data-p');
      if (t.name === 'ai-use') post('select', { provider: p, use: true }).then(soon).catch(fail);
      else if (t.classList.contains('model')) post('select', { provider: p, model: t.value }).then(soon).catch(fail);
      else if (t.classList.contains('mode')) post('select', { provider: p, mode: t.value }).then(soon).catch(fail);
      else if (t.id === 'ai-picture') post('select', { picture: t.checked }).catch(fail);
      else if (t.id === 'ai-note') post('select', { note: t.checked }).catch(fail);
      else if (t.id === 'ai-canvas') canvasPick = t.value;
      else if (t.getAttribute('data-l') === 'show') post('show', { frame: t.closest('.layer').getAttribute('data-f'), visible: t.checked }).then(soon).catch(fail);
    });
    ai.addEventListener('keydown', function (e) {
      if (e.key === 'Enter' && e.target.classList.contains('key')) { e.preventDefault(); saveKey(e.target.closest('.prov')); }
      else if (e.key === 'Enter' && (e.ctrlKey || e.metaKey) && e.target.id === 'ai-q') { e.preventDefault(); $('#ai-send').click(); }
    });
    document.addEventListener('visibilitychange', function () { if (!document.hidden) soon(); });
    load();
  }

  // ---- API keys: one box per service (the AI providers and Wit.ai); a saved key is only ever shown as its last four characters
  var keysPage = $('#keys');
  if (keysPage) {
    var kBox = $('#keys-list'), kTimer = null, kFails = 0, kBuilt = false, kList = [];
    var kSoon = function (ms) { clearTimeout(kTimer); kTimer = setTimeout(kLoad, ms || 250); };
    var kRender = function () {
      if (!kBuilt) {
        kBox.innerHTML = '';
        kList.forEach(function (s) {
          var el = document.createElement('div');
          el.className = 'prov';
          el.setAttribute('data-s', s.id);
          el.innerHTML = '<div class="prov-h"><b>' + esc(s.name) + '</b><span class="chip">' + esc(s.what) + '</span><span class="chip keyhint"></span>' +
            '<a class="get" target="_blank" rel="noopener" href="' + esc(s.keys_url) + '">Get a key</a></div>' +
            '<div class="ai-row"><input class="field key" type="password" autocomplete="off" spellcheck="false" placeholder="Paste your ' + esc(s.name) + (s.id === 'wit' ? ' server access token' : ' API key') + '">' +
            '<button class="btn" data-k="save">Save</button><button class="icon-btn danger" data-k="remove" title="Remove the key">' + icon('trash') + '</button></div>' +
            '<div class="note"></div>';
          kBox.appendChild(el);
        });
        kBuilt = true;
      }
      kList.forEach(function (s) {
        var el = $('.prov[data-s="' + s.id + '"]', kBox);
        if (!el) return;
        var kh = $('.keyhint', el);
        kh.textContent = s.has_key ? 'Key ' + s.key_hint : 'No key';
        kh.classList.toggle('here', s.has_key);
        $('.note', el).textContent = s.note;
        $('[data-k=remove]', el).hidden = !s.has_key;
      });
      var n = kList.filter(function (s) { return s.has_key; }).length;
      $('#keys-stat').textContent = n + ' of ' + kList.length + ' keys saved';
    };
    var kLoad = function () {
      fetch('/api/keys/state', { credentials: 'same-origin', cache: 'no-store' }).then(function (r) {
        if (r.status === 401) { location.href = '/login'; return null; }
        if (!r.ok) throw new Error(String(r.status));
        return r.json();
      }).then(function (j) {
        if (!j) return;
        kFails = 0; kList = j.services; kRender();
        var live = $('.live'); if (live) live.classList.remove('off');
      }).catch(function () {
        if (++kFails > 1) { var live = $('.live'); if (live) live.classList.add('off'); }
      }).then(function () { kSoon(document.hidden ? 8000 : 4000); });
    };
    var kSave = function (el) {
      var inp = $('.key', el), v = inp.value.trim();
      if (!v) { inp.focus(); return; }
      api('/api/keys/set', { service: el.getAttribute('data-s'), key: v, use: '1' }).then(function (j) { inp.value = ''; toast(j.message); kSoon(); }).catch(function (e) { toast(e.message, true); });
    };
    keysPage.addEventListener('click', function (e) {
      var b = e.target.closest('button'); if (!b) return;
      var el = b.closest('.prov'), k = b.getAttribute('data-k');
      if (k === 'save') kSave(el);
      else if (k === 'remove') {
        dialog({ title: 'Remove the ' + $('b', el).textContent + ' key?', text: 'The headset forgets it.', ok: 'Remove', danger: true }).then(function (yes) {
          if (yes) api('/api/keys/set', { service: el.getAttribute('data-s'), key: '' }).then(function (j) { toast(j.message); kSoon(); }).catch(function (err) { toast(err.message, true); });
        });
      }
    });
    keysPage.addEventListener('keydown', function (e) {
      if (e.key === 'Enter' && e.target.classList.contains('key')) { e.preventDefault(); kSave(e.target.closest('.prov')); }
    });
    document.addEventListener('visibilitychange', function () { if (!document.hidden) kSoon(); });
    kLoad();
  }

  bind();
})();
"""
