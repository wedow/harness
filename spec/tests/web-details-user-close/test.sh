#!/usr/bin/env bash
# A user-closed error result stays closed when a transcript morph renders it open.
set -euo pipefail
source "${SPEC_DIR}/helpers.sh"
setup

export HARNESS_SESSIONS="${_tmpdir}/sessions"
mkdir -p "${HARNESS_SESSIONS}/details/messages"
cat > "${HARNESS_SESSIONS}/details/messages/0001-tool_result.md" <<'M'
---
role: tool_result
seq: 0001
error: true
tool: bash
---
failed
M

source "${HARNESS_ROOT}/plugins/web/lib/http.sh"
source "${HARNESS_ROOT}/plugins/web/lib/pages.sh"
_session_page details '' > "${_tmpdir}/page.html"

node - "${_tmpdir}/page.html" <<'JS'
const fs = require('fs');
const vm = require('vm');
const html = fs.readFileSync(process.argv[2], 'utf8');
if (!html.includes('id="m0001" open')) throw new Error('error result is not initially open');
const start = html.indexOf('// <details> open state survives morphs.');
const scriptStart = html.indexOf('(() => {', start);
const scriptEnd = html.indexOf('})();', scriptStart) + 5;
if (start < 0 || scriptStart < 0 || scriptEnd < 5) throw new Error('missing details state script');

let click;
let onMutation;
const transcript = { addEventListener(type, handler) { if (type === 'click') click = handler; } };
class MutationObserver {
  constructor(handler) { onMutation = handler; }
  observe() {}
}
vm.runInNewContext(html.slice(scriptStart, scriptEnd), {
  document: { getElementById() { return transcript; } },
  MutationObserver, queueMicrotask, setTimeout,
});
if (!click || !onMutation) throw new Error('details handlers were not installed');

(async () => {
  const detail = { id: 'm0001', open: true };
  click({ target: { closest() { return { parentElement: detail }; } } });
  await Promise.resolve(); // a microtask checkpoint can precede default activation
  detail.open = false; // browser's default summary activation
  onMutation([{ target: detail }]); // native open-attribute change
  await new Promise(resolve => setTimeout(resolve, 5));
  if (detail.open) throw new Error('click to close was immediately undone');
  detail.open = true; // server reasserts error: true during morph
  onMutation([{ target: detail }]);
  await new Promise(resolve => setTimeout(resolve, 5));
  if (detail.open) throw new Error('morph reopened a user-closed error result');

  const collapsed = { id: 'm0002', open: false };
  click({ target: { closest() { return { parentElement: collapsed }; } } });
  await Promise.resolve();
  collapsed.open = true;
  onMutation([{ target: collapsed }]);
  await new Promise(resolve => setTimeout(resolve, 5));
  if (!collapsed.open) throw new Error('click to expand was immediately undone');
  collapsed.open = false;
  onMutation([{ target: collapsed }]);
  await new Promise(resolve => setTimeout(resolve, 5));
  if (!collapsed.open) throw new Error('morph closed a user-expanded result');
})().catch(error => { console.error(`FAIL: ${error.message}`); process.exitCode = 1; });
JS
