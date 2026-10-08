#!/usr/bin/env bash
# Exercise browser state without services, credentials, or a live chat.
set -euo pipefail
root="$(cd "$(dirname "$0")/../../.." >/dev/null && pwd)"
if ! command -v node >/dev/null 2>&1; then
  printf 'SKIP: Node is unavailable for browser-client checks\n'
  exit 0
fi
node - "${root}/plugins/web/public/app.js" "${root}/plugins/web/public/index.html" <<'JS'
const fs = require('node:fs');
const vm = require('node:vm');
const assert = require('node:assert/strict');
const {createHash} = require('node:crypto');
const source = fs.readFileSync(process.argv[2], 'utf8');
const html = fs.readFileSync(process.argv[3], 'utf8');
assert.match(html, /data-on:chat-connect="@get\('\/api\/stream\?after='/);
assert.match(html, /data-effect="window\.harnessChat\.receive\(\$_chatFeed\)"/);
assert.match(html, /retry: 'always', retryMaxCount: Infinity/);
assert.ok(html.indexOf('src="/app.js"') < html.indexOf('src="/datastar.js"'));

class Events {
  constructor() { this.listeners = new Map(); }
  addEventListener(name, listener) {
    if (!this.listeners.has(name)) this.listeners.set(name, []);
    this.listeners.get(name).push(listener);
  }
  dispatchEvent(event) {
    for (const listener of this.listeners.get(event.type) || []) listener(event);
    return true;
  }
}
class Element extends Events {
  constructor() {
    super(); this.children = []; this.dataset = {}; this.value = '';
    this.textContent = ''; this.hidden = false;
    this.classList = {add() {}, remove() {}};
  }
  append(...children) { this.children.push(...children); }
  replaceChildren(...children) { this.children = children; }
  focus() {}
  set innerHTML(value) { throw new Error('chat text must not become HTML'); }
}
class Event {
  constructor(type, options = {}) { this.type = type; this.detail = options.detail; }
  preventDefault() {}
}
let now = 0;
let online = false;
let lostAck = true;
let clientNumber = 0;
const saved = new Map([['harness.chat.draft', 'draft survives']]);
const committed = [];
const calls = [];
class Clock extends Date { static now() { return now; } }
function client(hidden = false) {
  const elements = new Map();
  const timers = new Map();
  const streams = [];
  let timerId = 0;
  const get = id => {
    if (!elements.has(id)) elements.set(id, new Element());
    return elements.get(id);
  };
  const document = new Events();
  Object.assign(document, {
    hidden, getElementById: get, createElement: () => new Element(),
    documentElement: {scrollHeight: 100}
  });
  const window = new Events();
  Object.assign(window, {innerHeight: 100, scrollY: 0, scrollTo() {}});
  // Datastar's attribute action is represented here by its controller/cursor
  // boundary. Actual SSE parsing and reconnection require browser verification.
  get('chat').addEventListener('chat-connect', () => {
    streams.push({after: window.harnessChat.cursor(), controller: window.harnessChat.controller()});
  });
  const sandbox = {
    document, window, CustomEvent: Event, Date: Clock, AbortController,
    crypto: {randomUUID: () => `client-${++clientNumber}`}, queueMicrotask,
    localStorage: {getItem: key => saved.get(key) ?? null, setItem: (key, value) => saved.set(key, value)},
    setTimeout: (fn, delay) => { const id = ++timerId; timers.set(id, {fn, delay}); return id; },
    clearTimeout: id => timers.delete(id),
    fetch: async (path, options) => {
      calls.push({path, body: options.body});
      if (!online) throw new Error('server down');
      if (path === '/api/messages') {
        const data = JSON.parse(options.body);
        let event = committed.find(event => event.data.message_id === data.id);
        if (!event) {
          const id = `client-${createHash('sha256').update(`main:${data.id}`).digest('hex')}`;
          event = {id, seq: committed.length + 1, actor: 'main', kind: 'message', data: {kind: 'user', text: data.text, message_id: data.id}};
          committed.push(event);
        }
        if (lostAck) { lostAck = false; throw new Error('response lost after commit'); }
        return {ok: true, json: async () => ({id: data.id, seq: event.seq})};
      }
      if (path === '/api/cancel') return {ok: true, json: async () => ({id: 'stop', seq: committed.length + 1})};
      const url = new URL(path, 'http://localhost');
      assert.equal(url.pathname, '/api/events');
      assert.ok(url.searchParams.has('before'), 'only explicit history paging uses the feed endpoint');
      const before = Number(url.searchParams.get('before'));
      return {ok: true, json: async () => ({events: committed.filter(event => event.seq < before), cursor: committed.length, has_more: false})};
    }
  };
  vm.runInNewContext(source, sandbox);
  const api = window.harnessChat;
  return {
    get, timers, streams, api,
    ready() { document.dispatchEvent(new Event('datastar-ready')); },
    visible(value) { document.hidden = !value; document.dispatchEvent(new Event('visibilitychange')); },
    lifecycle(type) { document.dispatchEvent(new Event('datastar-fetch', {detail: {el: get('chat'), type}})); },
    feed(events, cursor, has_more = false, status = {actors: [{id: 'main', status: 'idle', pending_jobs: 0}]}) {
      this.lifecycle('datastar-patch-signals');
      api.receive(JSON.stringify({events, cursor, has_more, status}));
    }
  };
}
async function flush() { for (let i = 0; i < 40; i++) await Promise.resolve(); }
function text(element) { return element.textContent + element.children.map(text).join(''); }
function event(type) { return new Event(type); }
(async () => {
  const browser = client(true);
  browser.ready(); await flush();
  assert.equal(browser.streams.length, 0, 'initially hidden tabs make no stream request');
  assert.equal(browser.timers.size, 0);
  assert.equal(browser.get('draft').value, 'draft survives');
  browser.visible(true); await flush();
  assert.equal(browser.streams.length, 1);
  assert.equal(browser.streams[0].after, 0);
  assert.equal(calls.length, 0, 'visible idle clients do not poll');
  assert.equal(browser.timers.size, 0, 'visible idle clients schedule no application timer');

  browser.get('draft').value = '<script>literal user text</script>\n';
  browser.get('compose').dispatchEvent(event('submit')); await flush();
  assert.match(text(browser.get('messages')), /<script>literal user text<\/script>/);
  assert.equal(committed.length, 0);
  assert.equal(browser.timers.size, 1, 'only a pending submission needs a retry timer');
  browser.get('draft').value = 'new draft'; browser.get('draft').dispatchEvent(event('input'));
  browser.visible(false); await flush();
  assert.ok(browser.streams[0].controller.signal.aborted);
  assert.equal(browser.timers.size, 0, 'hidden tabs cancel pending retry timers');
  now = 60000; online = true;
  assert.equal(calls.length, 1, 'hidden time performs no request');

  browser.visible(true); await flush();
  assert.equal(browser.streams.length, 2);
  assert.equal(committed.length, 1, 'a lost acknowledgement still commits once');
  const submits = calls.filter(call => call.path === '/api/messages').map(call => JSON.parse(call.body));
  assert.equal(submits.length, 2);
  assert.ok(submits.every(submit => submit.id === 'client-1'));
  assert.notEqual(committed[0].id, committed[0].data.message_id);
  assert.equal(JSON.parse(saved.get('harness.chat.pending'))[0].seq, undefined);
  browser.feed([...committed], 1); await flush();
  assert.deepEqual(JSON.parse(saved.get('harness.chat.pending')), [], 'the feed reconciles the original client ID without an acknowledgement');
  assert.equal(calls.length, 2, 'feed reconciliation avoids another submission');
  assert.equal(browser.timers.size, 0);

  browser.lifecycle('retrying');
  assert.equal(browser.get('connection').textContent, 'Reconnecting…');
  assert.equal(browser.timers.size, 0, 'Datastar owns reconnects; the application does not poll');
  committed.push({seq: 2, id: 'reply', actor: 'main', kind: 'assistant', data: {text: 'complete answer'}});
  browser.feed([committed[1]], 2); await flush();
  browser.feed([], 3, false, {actors: [{id: 'main', status: 'idle', pending_jobs: 1}]}); await flush();
  assert.equal(browser.get('connection').textContent, 'Connected');
  assert.match(text(browser.get('messages')), /literal user text/);
  assert.match(text(browser.get('messages')), /complete answer/);
  assert.equal(browser.get('cancel').disabled, false, 'background work can be stopped while the main actor is idle');

  browser.visible(false); browser.visible(true); await flush();
  assert.equal(browser.streams.at(-1).after, 3, 'visibility reconnect starts after the last committed cursor');
  committed.push({seq: 4, id: 'failure', actor: 'main', kind: 'error', data: {message: 'visible failure'}});
  browser.feed([committed[2]], 4); await flush();
  browser.feed([committed[2]], 4); await flush();
  assert.equal(browser.get('messages').children.length, 3, 'replayed events do not duplicate chat messages');

  const reload = client(); reload.ready(); await flush();
  assert.equal(reload.get('draft').value, 'new draft');
  reload.feed([committed[1], committed[2]], 4, true); await flush();
  assert.equal(reload.get('older').hidden, false);
  reload.get('older').dispatchEvent(event('click')); await flush();
  assert.match(text(reload.get('messages')), /literal user text/);
  assert.equal(calls.at(-1).path, '/api/events?before=2&limit=100');
  assert.equal(reload.api.cursor(), 4, 'older paging preserves the stream cursor');
  reload.visible(false); reload.visible(true); await flush();
  assert.equal(reload.streams.at(-1).after, 4);
  assert.equal(reload.timers.size, 0);
  reload.feed([], 4, false, {actors: [{id: 'main', status: 'blocked_memory'}]}); await flush();
  assert.match(reload.get('status').textContent, /Memory failed.*retry/);
  reload.api.receive('invalid JSON'); reload.api.receive(JSON.stringify({events: [], cursor: -1}));
  assert.equal(reload.api.cursor(), 4, 'malformed feeds do not change progress');
  console.log('PASS: Datastar integration, hidden-idle lifecycle, stable-ID retries, safe committed messages, draft restoration, and history paging');
})().catch(error => { console.error(error); process.exitCode = 1; });
JS
