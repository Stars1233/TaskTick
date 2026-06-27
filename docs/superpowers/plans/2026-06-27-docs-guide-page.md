# Docs Guide Page (Item A) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Ship a same-site, EN+简中 documentation page at `/guide/` (file `docs/guide/index.html`) covering CLI and Raycast (Script Notifications placeholder), plus a 「Docs」entry in the marketing site's nav and a deep-link from the Notifications feature card.

**Architecture:** A standalone hand-written static HTML page that copies `docs/index.html`'s CSS, but ships only `en` + `zh-Hans` translations, a two-item language menu, and a **textContent-only** i18n engine (no innerHTML, so no XSS surface and no markup inside translations). Single long page with a sticky table-of-contents. Code blocks are static HTML and carry no `data-i18n`, so commands/JSON are never translated. The marketing page (`docs/index.html`) is touched only to add links.

**Tech Stack:** Plain static HTML/CSS/JS. No framework, no build step. Served by GitHub Pages from the `docs/` folder (so `docs/guide/index.html` → `/guide/`).

**Scope note (this plan = Item A only):** Item B (editor inline hint) and C (release What's New) are out of scope and live in their own specs. Item D (notify directive feature) is unrelated to this plan; the Notifications section here is an intentional placeholder until D ships.

**Fact corrections baked into this plan (verified against source):**
- CLI exposes **11** user-facing subcommands: `list, status, logs, create, run, stop, restart, reveal, tail, wait, events`. `completion` is the hidden internal `__complete` (`shouldDisplay:false`) — **do not list it**.
- The Raycast extension has **no real command manifest in this repo** — the Raycast section is an overview + Store link, not a per-command table.
- `docs/index.html`'s Features grid has **no CLI card** — only a Notifications card. CLI is reachable via the nav「Docs」link; only the Notifications card gets a deep-link.

**i18n design note:** The guide page deliberately renders every translation with `textContent` only. All translated strings are plain text (flags like `--json` are written as plain text, not inline markup). This avoids the XSS surface of assigning HTML from a translation table and removes the need for any `data-i18n-html` path. Static `<code>`/`<pre>` blocks live directly in the HTML and are never touched by the i18n engine.

**Path convention:** Use **relative** paths everywhere (`guide/`, `../`, `../icon.svg`, `#cli`). The site may be served from a project-pages base path, so absolute `/guide/` is unsafe.

---

## File Structure

- **Create** `docs/guide/index.html` — the entire documentation page: `<head>` (copied CSS + fonts), nav (brand + back-to-site + 2-language menu), sticky TOC, `#cli` / `#raycast` / `#notifications` sections, footer, and `<script>` (T object with `en`+`zh-Hans`, `applyLang`/`setLang`/`initLang`, copied `toggleLangMenu`/`closeLangMenu`).
- **Modify** `docs/index.html` — add a「Docs」nav link (+ `nav_docs` translation in `en` and `zh-Hans`), and add a deep-link inside the Notifications feature card to `guide/#notifications`.

Local preview command used throughout: `open docs/guide/index.html` (opens `file://` in the default browser).

---

## Task 1: Guide page skeleton (head + nav + TOC + empty sections + footer)

**Files:**
- Create: `docs/guide/index.html`

- [ ] **Step 1: Create the page shell**

Create `docs/guide/index.html`. For the `<style>` block, **copy `docs/index.html` lines 14–189 verbatim** (the entire CSS: variables, nav, buttons, dark mode, responsive), then append the guide-specific CSS shown below. The `<head>` also copies the two font `<link>`s from `docs/index.html` lines 10–12 (change `<title>` and the icon `href` to `../icon.svg`).

```html
<!DOCTYPE html>
<html lang="en">
<head>
<meta charset="UTF-8">
<meta name="viewport" content="width=device-width, initial-scale=1.0">
<title>TaskTick — Docs</title>
<meta name="description" content="TaskTick documentation: CLI, Raycast, and script notifications.">
<link rel="icon" type="image/svg+xml" href="../icon.svg">
<link rel="apple-touch-icon" href="../icon.svg">
<link rel="preconnect" href="https://fonts.loli.net">
<link rel="preconnect" href="https://gstatic.loli.net" crossorigin>
<link href="https://fonts.loli.net/css2?family=Inter:wght@400;500;600;700;800&family=Noto+Sans+SC:wght@400;500;700&display=swap" rel="stylesheet">
<style>
/* PASTE docs/index.html lines 14-189 here verbatim (CSS vars, nav, buttons, dark mode, responsive) */

/* Guide-specific */
.doc-wrap{max-width:1120px;margin:0 auto;padding:96px 24px 80px;display:grid;grid-template-columns:220px 1fr;gap:48px;align-items:start}
.toc{position:sticky;top:80px;display:flex;flex-direction:column;gap:4px}
.toc a{color:var(--text2);text-decoration:none;font-size:.85rem;padding:6px 12px;border-radius:8px;transition:all .15s}
.toc a:hover{color:var(--text);background:var(--surface)}
.doc-main{min-width:0}
.doc-section{padding-bottom:56px;border-bottom:1px solid var(--border);margin-bottom:56px}
.doc-section:last-child{border-bottom:none}
.doc-section h2{font-size:1.6rem;font-weight:800;letter-spacing:-.03em;margin-bottom:10px;scroll-margin-top:80px}
.doc-section h3{font-size:1rem;font-weight:600;margin:28px 0 10px}
.doc-section p{color:var(--text2);font-size:.92rem;line-height:1.75;margin-bottom:14px}
.doc-table{width:100%;border-collapse:collapse;font-size:.84rem;margin:14px 0}
.doc-table th,.doc-table td{text-align:left;padding:9px 12px;border-bottom:1px solid var(--border);vertical-align:top}
.doc-table th{color:var(--text3);font-weight:600;text-transform:uppercase;font-size:.7rem;letter-spacing:.05em}
.doc-table td code{font-family:'SF Mono',Menlo,monospace;font-size:.82rem;color:var(--accent);white-space:nowrap}
pre{background:var(--surface);border:1px solid var(--border);border-radius:10px;padding:14px 16px;overflow-x:auto;margin:12px 0}
pre code{font-family:'SF Mono',Menlo,monospace;font-size:.82rem;color:var(--text);line-height:1.7;white-space:pre}
.doc-note{background:rgba(37,99,235,.05);border:1px solid rgba(37,99,235,.15);border-radius:10px;padding:14px 16px;font-size:.86rem;color:var(--text2)}
@media(max-width:768px){.doc-wrap{grid-template-columns:1fr;gap:24px}.toc{position:static;flex-direction:row;flex-wrap:wrap}}
</style>
</head>
<body>

<nav>
  <div class="nav-inner">
    <a href="../" class="nav-brand">
      <img src="../icon.svg" alt="TaskTick">
      TaskTick
    </a>
    <div class="nav-right">
      <a href="../" data-i18n="g_back">← Home</a>
      <a href="https://github.com/lifedever/TaskTick">GitHub</a>
      <div class="lang-wrap">
        <button class="lang-btn" onclick="toggleLangMenu()" aria-label="Language">
          <svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.5" stroke-linecap="round" stroke-linejoin="round"><circle cx="12" cy="12" r="10"/><line x1="2" y1="12" x2="22" y2="12"/><path d="M12 2a15.3 15.3 0 014 10 15.3 15.3 0 01-4 10 15.3 15.3 0 01-4-10 15.3 15.3 0 014-10z"/></svg>
        </button>
        <div class="lang-menu" id="langMenu">
          <button onclick="setLang('zh-Hans')">简体中文</button>
          <button onclick="setLang('en')">English</button>
        </div>
      </div>
    </div>
  </div>
</nav>

<div class="doc-wrap">
  <aside class="toc">
    <a href="#cli" data-i18n="toc_cli">CLI</a>
    <a href="#raycast" data-i18n="toc_raycast">Raycast</a>
    <a href="#notifications" data-i18n="toc_notifications">Notifications</a>
  </aside>
  <main class="doc-main">
    <section id="cli" class="doc-section"><h2 data-i18n="cli_h">Command Line (CLI)</h2></section>
    <section id="raycast" class="doc-section"><h2 data-i18n="raycast_h">Raycast</h2></section>
    <section id="notifications" class="doc-section"><h2 data-i18n="notif_h">Script Notifications</h2></section>
  </main>
</div>

<footer>
  <div class="container">
    <div class="left">&copy; 2026 <a href="https://github.com/lifedever">lifedever</a> &middot; GPL-3.0</div>
    <div class="right">
      <a href="../">Home</a>
      <a href="https://github.com/lifedever/TaskTick/issues">Issues</a>
    </div>
  </div>
</footer>

<script>
const T = { en: {}, 'zh-Hans': {} };
</script>
</body>
</html>
```

- [ ] **Step 2: Verify the page loads and is structurally complete**

Run: `open docs/guide/index.html`
Expected: page renders with nav, a left TOC (CLI / Raycast / Notifications), three empty section headings, footer. No console errors. Clicking a TOC item scrolls to its section.

Run: `grep -c 'class="doc-section"' docs/guide/index.html`
Expected: `3`

- [ ] **Step 3: Commit**

```bash
git add docs/guide/index.html
git commit -m "feat(docs): scaffold /guide/ page (head, nav, TOC, empty sections)"
```

---

## Task 2: i18n engine (en + zh-Hans, textContent-only, non-destructive fallback)

**Files:**
- Modify: `docs/guide/index.html` (the `<script>` block)

- [ ] **Step 1: Replace the `<script>` block with the full engine**

Replace `<script>const T = { en: {}, 'zh-Hans': {} };</script>` with:

```html
<script>
const T = {
  en: {
    g_back: '← Home',
    toc_cli: 'CLI', toc_raycast: 'Raycast', toc_notifications: 'Notifications',
    cli_h: 'Command Line (CLI)',
    raycast_h: 'Raycast',
    notif_h: 'Script Notifications',
  },
  'zh-Hans': {
    g_back: '← 首页',
    toc_cli: '命令行', toc_raycast: 'Raycast', toc_notifications: '脚本通知',
    cli_h: '命令行工具 (CLI)',
    raycast_h: 'Raycast',
    notif_h: '脚本通知',
  },
};

// Render only — plain text via textContent, never writes localStorage.
function applyLang(lang){
  if(!T[lang]) lang='en';
  document.querySelectorAll('[data-i18n]').forEach(el=>{
    const key=el.getAttribute('data-i18n');
    if(T[lang][key]!==undefined) el.textContent=T[lang][key];
  });
  document.documentElement.lang = lang.startsWith('zh') ? lang.split('-')[0] : lang;
  document.querySelectorAll('#langMenu button').forEach(function(btn){
    btn.classList.toggle('active', btn.getAttribute('onclick').indexOf("'"+lang+"'")!==-1);
  });
}

// User-initiated switch → persist so the choice carries back to the site.
function setLang(lang){
  if(!T[lang]) lang='en';
  applyLang(lang);
  localStorage.setItem('tasktick-lang', lang);
  document.getElementById('langMenu').classList.remove('show');
  document.querySelector('.lang-btn').classList.remove('active');
}

(function initLang(){
  const saved = localStorage.getItem('tasktick-lang');
  // Supported saved language → render it.
  if(saved && T[saved]){ applyLang(saved); return; }
  // Saved but unsupported here (e.g. 'ja' from the marketing site): show EN
  // but DO NOT overwrite the user's site-wide choice.
  if(saved && !T[saved]){ applyLang('en'); return; }
  // First visit, nothing saved: detect, render, but don't persist yet.
  const nav = navigator.language || '';
  applyLang(/^zh.*(CN|SG|Hans)/i.test(nav) ? 'zh-Hans' : 'en');
})();

// Copied verbatim from docs/index.html lines 1037-1058:
function toggleLangMenu() {
  var menu = document.getElementById('langMenu');
  var btn = document.querySelector('.lang-btn');
  var isOpen = menu.classList.contains('show');
  menu.classList.toggle('show');
  btn.classList.toggle('active');
  if (!isOpen) {
    setTimeout(function() {
      document.addEventListener('click', closeLangMenu, { once: true });
    }, 0);
  }
}
function closeLangMenu(e) {
  var wrap = document.querySelector('.lang-wrap');
  if (!wrap.contains(e.target)) {
    document.getElementById('langMenu').classList.remove('show');
    document.querySelector('.lang-btn').classList.remove('active');
  } else {
    document.addEventListener('click', closeLangMenu, { once: true });
  }
}
</script>
```

- [ ] **Step 2: Verify language switching + the no-overwrite guarantee**

Run: `open docs/guide/index.html`
In DevTools console:

```js
localStorage.setItem('tasktick-lang','ja'); location.reload();
// Expected after reload: page renders in ENGLISH (ja unsupported here).
localStorage.getItem('tasktick-lang')
// Expected: "ja"  ← NOT overwritten. This is the cross-page guarantee.
```

Then click the globe → 简体中文. Expected: TOC + headings switch to Chinese, and `localStorage.getItem('tasktick-lang')` is now `"zh-Hans"`.

- [ ] **Step 3: Commit**

```bash
git add docs/guide/index.html
git commit -m "feat(docs): textContent-only i18n engine for /guide/ (en+zh-Hans, non-destructive fallback)"
```

---

## Task 3: CLI section (install + 11-command table + examples)

**Files:**
- Modify: `docs/guide/index.html` (the `#cli` section + T entries)

- [ ] **Step 1: Fill the `#cli` section**

Replace `<section id="cli" class="doc-section"><h2 data-i18n="cli_h">Command Line (CLI)</h2></section>` with the block below. The command column and the `<pre>` blocks are static HTML (never translated). Description cells carry `data-i18n` and are plain text.

```html
<section id="cli" class="doc-section">
  <h2 data-i18n="cli_h">Command Line (CLI)</h2>
  <p data-i18n="cli_intro">TaskTick ships a "tasktick" command-line tool to list, run, and watch your tasks from the terminal. Most commands target a task by a flexible identifier — a name, a serial number, or a (partial) UUID all work.</p>

  <h3 data-i18n="cli_install_h">Install</h3>
  <p data-i18n="cli_install_p">Open TaskTick → Settings → CLI and click Install, or symlink it yourself:</p>
  <pre><code>ln -s "/Applications/TaskTick.app/Contents/cli/tasktick" /usr/local/bin/tasktick
tasktick list</code></pre>

  <h3 data-i18n="cli_cmds_h">Commands</h3>
  <table class="doc-table">
    <thead><tr><th data-i18n="cli_th_cmd">Command</th><th data-i18n="cli_th_desc">Description</th></tr></thead>
    <tbody>
      <tr><td><code>tasktick list</code></td><td data-i18n="cli_d_list">List tasks. Flags: --filter all|manual|scheduled|running, --json.</td></tr>
      <tr><td><code>tasktick status [task]</code></td><td data-i18n="cli_d_status">Global summary, or one task's status when given an identifier. Flag: --json.</td></tr>
      <tr><td><code>tasktick logs &lt;task&gt;</code></td><td data-i18n="cli_d_logs">Show the most recent execution log. Flags: --lines N (0 = all), --json.</td></tr>
      <tr><td><code>tasktick create &lt;name&gt;</code></td><td data-i18n="cli_d_create">Create a task from a script file. --script PATH is required, plus --shell, --cwd, --timeout, --manual, --repeat, --at HH:MM.</td></tr>
      <tr><td><code>tasktick run &lt;task&gt;</code></td><td data-i18n="cli_d_run">Start a task (wakes the app if needed). --wait streams output and mirrors the exit code.</td></tr>
      <tr><td><code>tasktick stop &lt;task&gt;</code></td><td data-i18n="cli_d_stop">Stop a running task.</td></tr>
      <tr><td><code>tasktick restart &lt;task&gt;</code></td><td data-i18n="cli_d_restart">Stop and immediately re-run a task.</td></tr>
      <tr><td><code>tasktick reveal &lt;task&gt;</code></td><td data-i18n="cli_d_reveal">Open the main window with the task selected.</td></tr>
      <tr><td><code>tasktick tail &lt;task&gt;</code></td><td data-i18n="cli_d_tail">Stream a running task's stdout/stderr live.</td></tr>
      <tr><td><code>tasktick wait &lt;task&gt;</code></td><td data-i18n="cli_d_wait">Block until a task finishes; exit code mirrors the task (124 on --timeout).</td></tr>
      <tr><td><code>tasktick events</code></td><td data-i18n="cli_d_events">Stream task lifecycle events as NDJSON.</td></tr>
    </tbody>
  </table>

  <h3 data-i18n="cli_ex_h">Examples</h3>
  <pre><code>tasktick list --filter running --json
tasktick create "Backup" --script ~/backup.sh --repeat daily --at 02:00
tasktick run deploy --wait
tasktick wait deploy --timeout 300</code></pre>
</section>
```

- [ ] **Step 2: Add the CLI translations to the T object**

Add these keys inside `T.en` (all plain text — no markup):

```js
    cli_intro: 'TaskTick ships a "tasktick" command-line tool to list, run, and watch your tasks from the terminal. Most commands target a task by a flexible identifier — a name, a serial number, or a (partial) UUID all work.',
    cli_install_h: 'Install', cli_install_p: 'Open TaskTick → Settings → CLI and click Install, or symlink it yourself:',
    cli_cmds_h: 'Commands', cli_th_cmd: 'Command', cli_th_desc: 'Description',
    cli_d_list: 'List tasks. Flags: --filter all|manual|scheduled|running, --json.',
    cli_d_status: "Global summary, or one task's status when given an identifier. Flag: --json.",
    cli_d_logs: 'Show the most recent execution log. Flags: --lines N (0 = all), --json.',
    cli_d_create: 'Create a task from a script file. --script PATH is required, plus --shell, --cwd, --timeout, --manual, --repeat, --at HH:MM.',
    cli_d_run: 'Start a task (wakes the app if needed). --wait streams output and mirrors the exit code.',
    cli_d_stop: 'Stop a running task.',
    cli_d_restart: 'Stop and immediately re-run a task.',
    cli_d_reveal: 'Open the main window with the task selected.',
    cli_d_tail: "Stream a running task's stdout/stderr live.",
    cli_d_wait: 'Block until a task finishes; exit code mirrors the task (124 on --timeout).',
    cli_d_events: 'Stream task lifecycle events as NDJSON.',
    cli_ex_h: 'Examples',
```

Add the matching keys inside `T['zh-Hans']`:

```js
    cli_intro: 'TaskTick 提供 “tasktick” 命令行工具，可在终端列出、运行和监看任务。大多数命令用一个灵活标识符指定任务——名称、序号或（部分）UUID 都可以。',
    cli_install_h: '安装', cli_install_p: '打开 TaskTick → 设置 → CLI 点击安装，或自行建立软链：',
    cli_cmds_h: '命令', cli_th_cmd: '命令', cli_th_desc: '说明',
    cli_d_list: '列出任务。选项：--filter all|manual|scheduled|running、--json。',
    cli_d_status: '全局摘要；带标识符时显示单个任务状态。选项：--json。',
    cli_d_logs: '显示最近一次执行日志。选项：--lines N（0 = 全部）、--json。',
    cli_d_create: '从脚本文件创建任务。--script PATH 必填，以及 --shell、--cwd、--timeout、--manual、--repeat、--at HH:MM。',
    cli_d_run: '启动任务（必要时唤醒 app）。--wait 实时输出并沿用退出码。',
    cli_d_stop: '停止运行中的任务。',
    cli_d_restart: '停止并立即重新运行任务。',
    cli_d_reveal: '打开主窗口并选中该任务。',
    cli_d_tail: '实时输出运行中任务的 stdout/stderr。',
    cli_d_wait: '阻塞直到任务结束；退出码沿用任务（--timeout 超时为 124）。',
    cli_d_events: '以 NDJSON 流式输出任务生命周期事件。',
    cli_ex_h: '示例',
```

All descriptions are plain text rendered via `textContent`. The command column holds static, untranslated `<code>` cells; flags appear as plain text (e.g. `--json`).

- [ ] **Step 3: Verify**

Run: `open docs/guide/index.html`
Expected: CLI section shows 11 rows (no `completion`); `<pre>`/`<code>` render monospace and do NOT change when you switch to 简体中文; prose + table descriptions DO change.

Run: `grep -c "completion\|__complete" docs/guide/index.html` → expect `0`.
Run: `grep -c "tasktick " docs/guide/index.html` → expect ≥ 15.

- [ ] **Step 4: Commit**

```bash
git add docs/guide/index.html
git commit -m "feat(docs): CLI section with 11-command reference (en+zh-Hans)"
```

---

## Task 4: Raycast section (overview + Store link)

**Files:**
- Modify: `docs/guide/index.html` (the `#raycast` section + T entries)

- [ ] **Step 1: Fill the `#raycast` section**

Replace the empty `#raycast` section with:

```html
<section id="raycast" class="doc-section">
  <h2 data-i18n="raycast_h">Raycast</h2>
  <p data-i18n="raycast_intro">Search, run, stop, and restart your scheduled tasks right from Raycast — without leaving your keyboard.</p>
  <h3 data-i18n="raycast_install_h">Install</h3>
  <p data-i18n="raycast_install_p">Install the official TaskTick extension from the Raycast Store, then type its name in Raycast to see the available commands.</p>
  <p><a href="https://www.raycast.com/lifedever/tasktick" class="btn btn-primary"><span data-i18n="raycast_btn">Get it on Raycast Store</span></a></p>
</section>
```

- [ ] **Step 2: Add Raycast translations**

In `T.en`:

```js
    raycast_intro: 'Search, run, stop, and restart your scheduled tasks right from Raycast — without leaving your keyboard.',
    raycast_install_h: 'Install',
    raycast_install_p: 'Install the official TaskTick extension from the Raycast Store, then type its name in Raycast to see the available commands.',
    raycast_btn: 'Get it on Raycast Store',
```

In `T['zh-Hans']`:

```js
    raycast_intro: '在 Raycast 中直接搜索、运行、停止和重启你的定时任务，双手不离键盘。',
    raycast_install_h: '安装',
    raycast_install_p: '从 Raycast Store 安装官方 TaskTick 扩展，然后在 Raycast 中输入其名称即可看到可用命令。',
    raycast_btn: '前往 Raycast Store 获取',
```

- [ ] **Step 3: Verify**

Run: `open docs/guide/index.html`
Expected: Raycast section shows the overview, an install paragraph, and a "Get it on Raycast Store" button linking to `https://www.raycast.com/lifedever/tasktick`. Switching to 简体中文 translates the prose. No invented command names appear.

- [ ] **Step 4: Commit**

```bash
git add docs/guide/index.html
git commit -m "feat(docs): Raycast section (overview + Store link)"
```

---

## Task 5: Script Notifications section (placeholder until feature D ships)

**Files:**
- Modify: `docs/guide/index.html` (the `#notifications` section + T entries)

- [ ] **Step 1: Fill the `#notifications` section**

Replace the empty `#notifications` section with:

```html
<section id="notifications" class="doc-section">
  <h2 data-i18n="notif_h">Script Notifications</h2>
  <p data-i18n="notif_intro">Per-task success/failure notifications are configured in the task editor today.</p>
  <div class="doc-note" data-i18n="notif_soon">Mid-run, script-driven notifications (a script printing a line to emit its own TaskTick notification) are coming in an upcoming release. This section will document the syntax once it ships.</div>
</section>
```

- [ ] **Step 2: Add Notifications translations**

In `T.en`:

```js
    notif_intro: 'Per-task success/failure notifications are configured in the task editor today.',
    notif_soon: 'Mid-run, script-driven notifications (a script printing a line to emit its own TaskTick notification) are coming in an upcoming release. This section will document the syntax once it ships.',
```

In `T['zh-Hans']`:

```js
    notif_intro: '当前可在任务编辑器中为每个任务配置成功/失败通知。',
    notif_soon: '由脚本驱动的运行中通知（脚本打印一行即可发出自己的 TaskTick 通知）将在后续版本推出。语法将在上线后补充到本节。',
```

- [ ] **Step 3: Verify & commit**

Run: `open docs/guide/index.html`
Expected: Notifications section shows the intro + a highlighted "coming soon" note; both translate.

```bash
git add docs/guide/index.html
git commit -m "feat(docs): Script Notifications placeholder section"
```

---

## Task 6: Marketing site — add 「Docs」nav link

**Files:**
- Modify: `docs/index.html` (nav-right around line 202; `en` + `zh-Hans` blocks of `T`)

- [ ] **Step 1: Add the nav link**

In `docs/index.html`, inside `<div class="nav-right">`, immediately after the `Install` link (`<a href="#install" data-i18n="nav_install">Install</a>`, line 202), add:

```html
      <a href="guide/" data-i18n="nav_docs">Docs</a>
```

- [ ] **Step 2: Translate `nav_docs` in en + zh-Hans**

In `docs/index.html`'s `T['zh-Hans']` block, after `nav_install: '安装',` add:

```js
    nav_docs: '文档',
```

In the `en` block, after `nav_install: 'Install',` add:

```js
    nav_docs: 'Docs',
```

(The other 9 locales intentionally fall back to the HTML default "Docs" — `setLang` skips keys missing from `T[lang]`. "Docs" is acceptable as-is for them; this keeps the change to links only.)

- [ ] **Step 3: Verify**

Run: `open docs/index.html`
Expected: nav shows "Docs" between Install and GitHub; clicking it navigates to the guide page. Switch to 简体中文 → nav shows "文档".

Run: `grep -c 'href="guide/"' docs/index.html` → expect `1`.

- [ ] **Step 4: Commit**

```bash
git add docs/index.html
git commit -m "feat(site): add Docs nav link to guide page"
```

---

## Task 7: Marketing site — deep-link the Notifications card to the guide

**Files:**
- Modify: `docs/index.html:363-367` (the Notifications feature card) + `en`/`zh-Hans` blocks of `T`

- [ ] **Step 1: Add a deep-link inside the Notifications card**

In `docs/index.html`, the Notifications feature card is at lines 363–367. Add an anchor right after its `<p>` (line 366), before the card's closing `</div>`:

Find:
```html
        <h3 data-i18n="feat_notify_title">Notifications</h3>
        <p data-i18n="feat_notify_desc">macOS native alerts on success or failure, per task.</p>
      </div>
```
Replace with:
```html
        <h3 data-i18n="feat_notify_title">Notifications</h3>
        <p data-i18n="feat_notify_desc">macOS native alerts on success or failure, per task.</p>
        <a href="guide/#notifications" style="display:inline-block;margin-top:10px;font-size:.78rem;font-weight:600;color:var(--accent);text-decoration:none" data-i18n="feat_notify_link">Learn more →</a>
      </div>
```

(Inline style only — no new CSS class, lowest-risk edit to the marketing page.)

- [ ] **Step 2: Translate `feat_notify_link`**

In `docs/index.html`'s `en` block, after `feat_notify_desc: ...,` add:
```js
    feat_notify_link: 'Learn more →',
```
In `T['zh-Hans']`, after its `feat_notify_desc: ...,` add:
```js
    feat_notify_link: '了解更多 →',
```

- [ ] **Step 3: Verify**

Run: `open docs/index.html`
Expected: the Notifications card shows a "Learn more →" link; clicking it opens `guide/#notifications` and scrolls to the Notifications section. Switch to 简体中文 → link reads "了解更多 →".

- [ ] **Step 4: Commit**

```bash
git add docs/index.html
git commit -m "feat(site): deep-link Notifications card to /guide/#notifications"
```

---

## Task 8: Final cross-page verification

**Files:** none (verification only)

- [ ] **Step 1: Verify the full round-trip in a browser**

Run: `open docs/index.html`
Checklist (all must pass):
- [ ] Click nav「Docs」→ lands on the guide page.
- [ ] On the guide page, TOC links jump to CLI / Raycast / Notifications.
- [ ] Switch guide page to 简体中文 → all prose translates, **all `<pre>`/`<code>` stay verbatim** (no Chinese inside `tasktick ...` commands).
- [ ] Click「← Home」→ returns to the marketing page, language still 简体中文 (carried via `tasktick-lang`).
- [ ] On the marketing page, the Notifications card「了解更多 →」opens `guide/#notifications`.

- [ ] **Step 2: Verify no English残留 when switched to Chinese**

On the guide page in 简体中文, scan every section: no English prose should remain (English left over = a missing `zh-Hans` key). If found, add the missing key and re-verify.

- [ ] **Step 3: Re-verify the ja-not-overwritten guarantee**

In the guide page console:
```js
localStorage.setItem('tasktick-lang','ja'); location.reload();
```
Expected: guide renders English, `localStorage.getItem('tasktick-lang')` is still `"ja"`. Open `docs/index.html` in the same browser → still Japanese.

- [ ] **Step 4: Final commit (only if fixes were made)**

```bash
git add docs/guide/index.html docs/index.html
git commit -m "fix(docs): close i18n key gaps found in cross-page verification"
```

---

## Self-Review (completed by plan author)

- **Spec coverage:** §A file/URL → Task 1; single-page + TOC → Task 1; first sections CLI/Raycast/Notifications → Tasks 3/4/5; i18n EN+ZH, code-not-translated, same `tasktick-lang` localStorage key → Task 2 + Task 3; site nav entry → Task 6; Features deep-link → Task 7 (Notifications card only — CLI card does not exist, flagged as a fact correction); no-CSS-extraction / minimal index.html edits → honored (links + one inline-styled anchor). B and C excluded (own specs); D unrelated.
- **Placeholder scan:** the only "placeholder" is the Notifications *content* (Task 5), an intentional fully-written "coming soon" block — not a plan placeholder. No TBD/TODO steps; all code blocks are concrete.
- **Type/name consistency:** `applyLang`/`setLang`/`initLang`, `T`, `tasktick-lang`, and all `data-i18n` keys (`g_back`, `toc_*`, `cli_*`, `raycast_*`, `notif_*`, `nav_docs`, `feat_notify_link`) are defined and referenced consistently. Every `data-i18n` key added to markup has a matching `en` and `zh-Hans` entry. No `innerHTML` / `data-i18n-html` anywhere — textContent-only.
```