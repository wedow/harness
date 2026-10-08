#!/usr/bin/env bash
# The HTTP frontend reads/submits durable events without launching an agent.
set -euo pipefail
root="$(cd "$(dirname "$0")/../../.." >/dev/null && pwd)"
tmp="$(mktemp -d)"
trap 'rm -rf "${tmp}"' EXIT
mkdir -p "${tmp}/root/lib" "${tmp}/root/plugins"
ln -s "${root}/plugins/web" "${tmp}/root/plugins/web"
export HARNESS_ROOT="${tmp}/root" HARNESS_DATA="${tmp}/chat"
cat > "${tmp}/root/lib/bootstrap.sh" <<'MOCK'
export HARNESS_DATA
MOCK
cat > "${tmp}/root/lib/store.sh" <<'MOCK'
store_init() { mkdir -p "${HARNESS_DATA}/submitted"; }
store_submit() {
  local text="$1" actor="$2" id="$3" seq
  [[ -n "${id}" ]] || id=generated
  if [[ ! -f "${HARNESS_DATA}/submitted/${id}" ]]; then
    seq="$(find "${HARNESS_DATA}/submitted" -type f | wc -l)"
    seq=$((seq+1))
    jq -cn --arg text "${text}" --arg actor "${actor}" --arg id "${id}" --argjson seq "${seq}" '{id:$id,seq:$seq,actor:$actor,data:{kind:"user",text:$text}}' > "${HARNESS_DATA}/submitted/${id}"
  fi
  jq -c '{id,seq}' "${HARNESS_DATA}/submitted/${id}"
}
store_feed() {
  printf '%s %s %s\n' "$1" "$2" "$3" > "${HARNESS_DATA}/feed-args"
  jq -cn '{events:[{seq:7,id:"reply",actor:"main",kind:"assistant",data:{text:"Full reply ✓"},date:"2026-01-01T00:00:00Z"}],cursor:7,has_more:false,status:{actors:[{id:"main",status:"idle"}],requests:{queued:0,running:0},jobs:{queued:0,running:0},components:{reactor:true}}}'
}
store_status() { printf '{"jobs":{"queued":2,"running":1}}\n'; }
store_cancel() { printf '%s\n' "$1" > "${HARNESS_DATA}/cancelled"; printf '{"id":"stop","seq":8}\n'; }
MOCK
handler="${root}/plugins/web/lib/handler"
response="${tmp}/response"
request() {
  local method="$1" path="$2" body="${3:-}" host="${4:-127.0.0.1:8080}" origin="${5:-http://127.0.0.1:8080}" length
  length="$(printf '%s' "${body}" | wc -c)"
  { printf '%s %s HTTP/1.1\r\nHost: %s\r\n' "${method}" "${path}" "${host}"
    [[ "${method}" != POST ]] || printf 'Origin: %s\r\nContent-Type: application/json\r\nContent-Length: %s\r\n' "${origin}" "${length}"
    printf '\r\n%s' "${body}"
  } | "${handler}" > "${response}"
}
expect_status() { grep -q "^HTTP/1.1 $1 " "${response}" || { cat "${response}"; exit 1; }; }
body() { sed '1,/^\r$/d' "${response}"; }
assert_length() {
  local declared actual
  declared="$(sed -n 's/^Content-Length: \([0-9]*\)\r$/\1/p' "${response}")"
  actual="$(body | wc -c | tr -d ' ')"
  [[ "${declared}" == "${actual}" ]] || { printf 'bad byte length: %s vs %s\n' "${declared}" "${actual}"; exit 1; }
}

request GET /
expect_status 200
grep -q 'One continuous chat' "${response}"
grep -q 'Cache-Control: no-store' "${response}"
assert_length
request GET /app.js
expect_status 200
grep -q 'text/javascript' "${response}"
request GET /style.css
expect_status 200
printf '%s\r\n' 'GET /app.js HTTP/1.1' 'Host: localhost:8080' 'Accept-Encoding: gzip' '' | "${handler}" > "${response}"
expect_status 200
grep -q '^Content-Encoding: gzip' "${response}"
assert_length
body | gzip -dc | grep -q 'const pendingKey'
request GET '/api/events?after=7&limit=20'
expect_status 200
[[ "$(cat "${HARNESS_DATA}/feed-args")" == '7 0 20' ]]
body | jq -e '.cursor==7 and .events[0].data.text=="Full reply ✓"' >/dev/null
assert_length
request GET '/api/events?before=7&limit=10'
expect_status 200
[[ "$(cat "${HARNESS_DATA}/feed-args")" == '0 7 10' ]]
for query in 'limit=201' 'limit=0' 'after=bad' 'after=1&after=2' 'after=1&before=2' 'unknown=2' 'after=1234567890123'; do
  request GET "/api/events?${query}"; expect_status 400
done

text=$'你好 <script>alert(1)</script>\n\n'
payload="$(jq -cn --arg text "${text}" '{text:$text,id:"stable-message"}')"
request POST /api/messages "${payload}"
expect_status 200
ack="$(body)"
[[ "$(jq -jr '.data.text' "${HARNESS_DATA}/submitted/stable-message"; printf x)" == "${text}x" ]]
request POST /api/messages "${payload}"
expect_status 200
[[ "$(body)" == "${ack}" ]]
[[ "$(find "${HARNESS_DATA}/submitted" -type f | wc -l)" == 1 ]]
for payload in '{"text":4}' '{"text":" "}' '{"text":"ok","id":"../escape"}' '{"text":"\u0000"}' '{"text":"one"}{"text":"two"}' 'not-json'; do
  request POST /api/messages "${payload}"; expect_status 400
done
request GET /api/status
expect_status 200
body | jq -e '.jobs.queued==2' >/dev/null
request POST /api/cancel '{}'
expect_status 200
[[ "$(cat "${HARNESS_DATA}/cancelled")" == main ]]

request GET / '' attacker.example:8080
expect_status 403
request POST /api/messages '{"text":"no","id":"foreign"}' 127.0.0.1:8080 https://evil.example
expect_status 403
[[ ! -f "${HARNESS_DATA}/submitted/foreign" ]]
export HARNESS_WEB_ALLOWED_ORIGINS=https://agent.example
request GET / '' agent.example
expect_status 200
request POST /api/messages '{"text":"proxy","id":"proxy"}' agent.example https://agent.example
expect_status 200
request POST /api/messages '{"text":"no"}' agent.example http://agent.example
expect_status 403
unset HARNESS_WEB_ALLOWED_ORIGINS
export HARNESS_WEB_ALLOWED_HOSTS=proxy.internal:8080
request POST /api/messages '{"text":"host","id":"host"}' proxy.internal:8080 http://proxy.internal:8080
expect_status 200
unset HARNESS_WEB_ALLOWED_HOSTS

printf '%s\r\n' 'POST /api/messages HTTP/1.1' 'Host: localhost:8080' 'Content-Length: 1048577' '' | "${handler}" > "${response}"
expect_status 413
marker="${tmp}/executed"
printf '%s\r\n' 'POST /api/messages HTTP/1.1' 'Host: localhost:8080' 'Content-Length: BODY[$(touch '"${marker}"')]' '' | "${handler}" > "${response}"
expect_status 400
[[ ! -e "${marker}" ]]
printf '%s\r\n' 'POST /api/messages HTTP/1.1' 'Host: localhost:8080' 'Content-Length: 20' '' '{}' | "${handler}" > "${response}"
expect_status 400
printf '%s\r\n' 'POST /api/messages HTTP/1.1' 'Host: localhost:8080' 'Content-Length: 0' 'Content-Length: 1' '' | "${handler}" > "${response}"
expect_status 400
printf '%s\r\n' 'POST /api/messages HTTP/1.1' 'Host: localhost:8080' 'Transfer-Encoding: chunked' '' | "${handler}" > "${response}"
expect_status 400
printf '%s\r\n' 'POST /api/cancel HTTP/1.1' 'Host: localhost:8080' 'Content-Type: text/plain' 'Content-Length: 0' '' | "${handler}" > "${response}"
expect_status 415
printf '%s\r\n' 'POST /api/cancel HTTP/1.1' 'Host: localhost:8080' 'Sec-Fetch-Site: cross-site' 'Content-Length: 0' '' | "${handler}" > "${response}"
expect_status 403
request GET /s/old-session
expect_status 404

printf 'PASS: web API, byte framing, idempotent submissions, and origin guards\n'

# Exercise publication failures and reconciliation against the real journal.
# Every handler invocation remains isolated from the user's data/configuration.
export HARNESS_ROOT="${root}" HARNESS_HOME="${tmp}/real-home" HARNESS_DATA="${tmp}/real-chat" HARNESS_CWD="${tmp}"
# shellcheck disable=SC1091
source "${root}/lib/bootstrap.sh"
# shellcheck disable=SC1091
source "${root}/lib/store.sh"
store_init
real_text=$'你好 <script>alert(1)</script>\n\n'
message_id=00000000-0000-4000-8000-000000000001
payload="$(jq -cn --arg text "${real_text}" --arg id "${message_id}" '{text:$text,id:$id}')"
request POST /api/messages "${payload}"
expect_status 200
ack="$(body)"
printf '%s' "${ack}" | jq -e --arg id "${message_id}" '.id==$id and .seq==1' >/dev/null
request POST /api/messages "${payload}"
expect_status 200
[[ "$(body)" == "${ack}" ]]
request GET /api/events
expect_status 200
body | jq -e --arg id "${message_id}" --arg text "${real_text}" '.events|length==1 and (.[0]|.id!=$id and .data.message_id==$id and .data.text==$text)' >/dev/null
assert_length
request POST /api/messages "$(jq -cn --arg id "${message_id}" '{text:"changed text",id:$id}')"
expect_status 409
grep -q '^HTTP/1.1 409 Conflict' "${response}"
body | jq -e '.error=="message id already used with different text"' >/dev/null
assert_length
for reserved in "client-$(printf '%064d' 0)" "$(jq -r '.id' "${HARNESS_DATA}/events/000000000001.json")"; do
  request POST /api/messages "$(jq -cn --arg id "${reserved}" '{text:"reserved identity",id:$id}')"
  expect_status 400
  body | jq -e '.error=="invalid or reserved message id"' >/dev/null
done
request POST /api/messages '{"text":"invalid identity","id":"../escape"}'
expect_status 400
[[ "$(cat "${HARNESS_DATA}/HEAD")" == 1 ]]

legacy="$(store_emit message main '{"kind":"user","text":"legacy text"}' legacy-raw-id | jq -c '{id,seq}')"
legacy_hash="$(sha256sum "${HARNESS_DATA}/events/000000000002.json")"
request POST /api/messages '{"text":"legacy text","id":"legacy-raw-id"}'
expect_status 200
[[ "$(body)" == "${legacy}" ]]
[[ "$(sha256sum "${HARNESS_DATA}/events/000000000002.json")" == "${legacy_hash}" ]]
request POST /api/messages '{"text":"changed legacy text","id":"legacy-raw-id"}'
expect_status 409
[[ "$(cat "${HARNESS_DATA}/HEAD")" == 2 ]]

store_emit assistant main '{"text":"existing runtime event"}' assistant-request-main-0-1 >/dev/null
request POST /api/messages '{"text":"client uses an internal-looking name","id":"assistant-request-main-0-1"}'
expect_status 200
body | jq -e '.id=="assistant-request-main-0-1" and .seq==4' >/dev/null
jq -e '.kind=="message" and .id!="assistant-request-main-0-1" and .data.message_id=="assistant-request-main-0-1"' "${HARNESS_DATA}/events/000000000004.json" >/dev/null
printf 'PASS: real-store UUID retries, client namespace, legacy history, and HTTP 400/409 errors\n'

# No runtime dependency on Node: when available, exercise the actual client
# against a small DOM/fetch harness, including a lost submission response.
if command -v node >/dev/null 2>&1; then
  node - "${root}/plugins/web/public/app.js" <<'JS'
const fs = require('node:fs');
const vm = require('node:vm');
const assert = require('node:assert/strict');
const {createHash} = require('node:crypto');
const source = fs.readFileSync(process.argv[2], 'utf8');
class Element {
  constructor() {
    this.children = []; this.listeners = {}; this.dataset = {};
    this.value = ''; this.textContent = ''; this.hidden = false;
    this.classList = {add() {}, remove() {}};
  }
  append(...children) { this.children.push(...children); }
  replaceChildren(...children) { this.children = children; }
  addEventListener(name, fn) { this.listeners[name] = fn; }
  focus() {}
  set innerHTML(value) { throw new Error('chat text must not become HTML'); }
}
const saved = new Map([['harness.chat.draft', 'draft survives']]);
const committed = [];
const calls = [];
let now = 0;
let online = false;
let hideFeed = true;
let lostAcks = 2;
let clientNumber = 0;
let mainStatus = 'idle';
let pendingJobs = 0;
class Clock extends Date { static now() { return now; } }
function client() {
  const elements = new Map();
  const timers = new Map();
  let timerId = 0;
  const get = id => {
    if (!elements.has(id)) elements.set(id, new Element());
    return elements.get(id);
  };
  const sandbox = {
    document: {getElementById: get, createElement: () => new Element(), documentElement: {scrollHeight: 100}},
    window: {innerHeight: 100, scrollY: 0, scrollTo() {}},
    localStorage: {getItem: key => saved.get(key) ?? null, setItem: (key, value) => saved.set(key, value)},
    Date: Clock, AbortController, crypto: {randomUUID: () => `client-${++clientNumber}`},
    setTimeout: (fn, delay) => { const id = ++timerId; timers.set(id, {fn, delay}); return id; },
    clearTimeout: id => timers.delete(id),
    fetch: async (path, options) => {
      calls.push({path, body: options.body});
      if (!online) throw new Error('server down');
      if (path === '/api/messages') {
        const data = JSON.parse(options.body);
        let event = committed.find(event => event.data.message_id === data.id);
        if (!event) {
          const journalId = `client-${createHash('sha256').update(`main:${data.id}`).digest('hex')}`;
          event = {id: journalId, seq: committed.length + 1, actor: 'main', kind: 'message', data: {kind: 'user', text: data.text, message_id: data.id}};
          committed.push(event);
        }
        if (lostAcks > 0) { lostAcks--; throw new Error('response lost after commit'); }
        return {ok: true, json: async () => ({id: data.id, seq: event.seq})};
      }
      const url = new URL(path, 'http://localhost');
      const before = Number(url.searchParams.get('before'));
      const after = Number(url.searchParams.get('after'));
      let events = hideFeed ? [] : committed.filter(event => before ? event.seq < before : event.seq > after);
      const more = !after && events.length > 2;
      if (!after) events = events.slice(-2);
      return {ok: true, json: async () => ({events, cursor: hideFeed ? 0 : committed.length, has_more: more, status: {actors: [{id: 'main', status: mainStatus, pending_jobs: pendingJobs}]}})};
    }
  };
  vm.runInNewContext(source, sandbox);
  return {get, timers};
}
async function flush() { for (let i = 0; i < 40; i++) await Promise.resolve(); }
async function tick(browser) {
  const timer = [...browser.timers].find(([, timer]) => timer.fn.name === 'poll');
  assert.ok(timer, 'client keeps a reconnect poll scheduled');
  browser.timers.delete(timer[0]);
  timer[1].fn(); await flush();
}
function text(element) { return element.textContent + element.children.map(text).join(''); }
(async () => {
  const browser = client(); await flush();
  assert.equal(browser.get('draft').value, 'draft survives');
  assert.equal(browser.get('connection').textContent, 'Reconnecting…');
  browser.get('draft').value = '<script>literal user text</script>\n';
  browser.get('compose').listeners.submit({preventDefault() {}}); await flush();
  assert.match(text(browser.get('messages')), /<script>literal user text<\/script>/);
  assert.equal(committed.length, 0);
  browser.get('draft').value = 'new draft'; browser.get('draft').listeners.input();
  online = true; now = 10000;
  await tick(browser);
  assert.equal(committed.length, 1, 'lost response still committed exactly once');
  now = 20000;
  await tick(browser);
  const submits = calls.filter(call => call.path === '/api/messages' && call.body).map(call => JSON.parse(call.body));
  assert.equal(submits.length, 3, 'offline send, lost response, retry');
  assert.ok(submits.every(submit => submit.id === 'client-1'), 'every retry reuses its ID');
  assert.equal(committed.length, 1);
  assert.match(committed[0].id, /^client-[a-f0-9]{64}$/);
  assert.notEqual(committed[0].id, committed[0].data.message_id);
  assert.equal(JSON.parse(saved.get('harness.chat.pending'))[0].seq, undefined, 'no acknowledgement reached the browser');
  hideFeed = false;
  await tick(browser);
  assert.deepEqual(JSON.parse(saved.get('harness.chat.pending')), []);
  assert.equal(calls.filter(call => call.path === '/api/messages').length, 3, 'feed reconciles the original client ID without another submission');
  committed.push({seq: 2, id: 'reply', actor: 'main', kind: 'assistant', data: {text: 'complete answer'}});
  committed.push({seq: 3, id: 'failure', actor: 'main', kind: 'error', data: {message: 'visible failure'}});
  const reload = client(); await flush();
  assert.equal(reload.get('draft').value, 'new draft', 'draft survives reconnect/reload');
  assert.equal(reload.get('older').hidden, false);
  assert.match(text(reload.get('messages')), /complete answer/);
  await reload.get('older').listeners.click(); await flush();
  assert.match(text(reload.get('messages')), /literal user text/);
  await tick(reload);
  assert.equal(calls.at(-1).path, '/api/events?after=3&limit=100', 'older paging preserves the live cursor');
  pendingJobs = 1;
  await tick(reload);
  assert.equal(reload.get('cancel').disabled, false, 'idle agent can stop background work');
  pendingJobs = 0;
  mainStatus = 'waiting_memory';
  await tick(reload);
  assert.match(reload.get('status').textContent, /Preparing memory/);
  mainStatus = 'blocked_memory';
  await tick(reload);
  assert.match(reload.get('status').textContent, /Memory failed.*retry/);
  console.log('PASS: browser reconnect, draft preservation, lost-ack retry, safe text, and paging');
})().catch(error => { console.error(error); process.exitCode = 1; });
JS
fi
