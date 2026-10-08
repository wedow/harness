/* The browser is a reconnectable client of the durable chat. */
(() => {
  'use strict';
  const byId = id => document.getElementById(id);
  const draft = byId('draft');
  const messages = byId('messages');
  const connection = byId('connection');
  const notice = byId('notice');
  const older = byId('older');
  const cancel = byId('cancel');
  const chat = byId('chat');
  const draftKey = 'harness.chat.draft';
  const pendingKey = 'harness.chat.pending';
  const events = new Map();
  const nodes = new Map();
  const pending = new Map();
  let cursor = 0;
  let oldest = 0;
  let initial = true;
  let loadingOlder = false;
  let hasOlder = true;
  let datastarReady = false;
  let liveController = null;
  let retryTimer = null;
  let connected = false;

  function saved(key, fallback) {
    try { return localStorage.getItem(key) ?? fallback; }
    catch { return fallback; }
  }
  function save(key, value) {
    try { localStorage.setItem(key, value); }
    catch { /* The chat remains usable when browser storage is unavailable. */ }
  }
  function savePending() {
    save(pendingKey, JSON.stringify([...pending.values()]));
  }

  draft.value = saved(draftKey, '');
  try {
    const items = JSON.parse(saved(pendingKey, '[]'));
    for (const item of items) {
      if (typeof item.id !== 'string' || typeof item.text !== 'string') continue;
      if (item.state === 'sending') item.state = 'queued';
      pending.set(item.id, item);
    }
  } catch { /* Ignore an incomplete local save. */ }

  async function request(path, body) {
    const controller = new AbortController();
    const timeout = setTimeout(() => controller.abort(), 12000);
    try {
      const options = {cache: 'no-store', signal: controller.signal};
      if (body !== undefined) {
        options.method = 'POST';
        options.headers = {'Content-Type': 'application/json'};
        options.body = JSON.stringify(body);
      }
      const response = await fetch(path, options);
      const data = await response.json();
      if (!response.ok) {
        const error = new Error(data.error || `Request failed (${response.status})`);
        error.permanent = response.status >= 400 && response.status < 500;
        throw error;
      }
      return data;
    } finally { clearTimeout(timeout); }
  }

  function element(tag, className, text) {
    const node = document.createElement(tag);
    if (className) node.className = className;
    if (text !== undefined) node.textContent = text;
    return node;
  }
  function eventNode(event) {
    const data = event.data || {};
    let label = 'Harness';
    let className = 'message';
    let text = typeof data === 'string' ? data : data.text;
    let collapsed = false;
    if (event.kind === 'message') {
      if (data.kind === 'user') { label = 'You'; className += ' user'; }
      else if (data.kind === 'echo') { label = 'Tool result'; collapsed = true; }
      else if (data.kind === 'work') { label = 'Agent report'; className += ' job'; }
      else if (data.kind === 'note') label = 'Note';
    } else if (event.kind === 'assistant') {
      // Provider blocks can contain reasoning; only the reply belongs in the UI.
      if (typeof text !== 'string' || !text.trim()) return null;
    } else if (event.kind === 'tool') {
      label = data.name || 'Tool call';
      text = JSON.stringify(data.input || {}, null, 2);
      collapsed = true;
    } else if (event.kind === 'job.completed') {
      label = data.name || 'Background task';
      text = data.error ? 'Task failed.' : 'Task completed.';
      className += ' job';
    } else if (event.kind === 'error') {
      label = 'Error'; className += ' failed';
      text = data.text || data.message || data.error;
    } else return null;
    if (typeof text !== 'string') text = JSON.stringify(text ?? data, null, 2);
    const article = element('article', className);
    article.dataset.seq = String(event.seq);
    const meta = element('div', 'meta');
    meta.append(element('span', 'label', label));
    if (event.date) {
      const time = element('time');
      time.dateTime = event.date;
      const date = new Date(event.date);
      time.textContent = Number.isNaN(date.getTime()) ? event.date : date.toLocaleString();
      meta.append(time);
    }
    article.append(meta);
    if (collapsed) {
      const details = element('details');
      details.append(element('summary', '', label), element('pre', '', text));
      article.append(details);
    } else article.append(element('pre', '', text));
    return article;
  }

  function render(mode = 'append') {
    const pinned = window.innerHeight + window.scrollY >= document.documentElement.scrollHeight - 100;
    const height = document.documentElement.scrollHeight;
    const top = window.scrollY;
    const ordered = [];
    for (const event of [...events.values()].sort((a, b) => a.seq - b.seq)) {
      if (!nodes.has(event.seq)) nodes.set(event.seq, eventNode(event));
      const node = nodes.get(event.seq);
      if (node) ordered.push(node);
    }
    for (const item of pending.values()) {
      const article = element('article', `message user pending${item.state === 'error' ? ' failed' : ''}`);
      article.dataset.messageId = item.id;
      const meta = element('div', 'meta');
      const state = item.state === 'accepted' ? 'Saved' : item.state === 'error' ? 'Could not send' : 'Sending…';
      meta.append(element('span', 'label', 'You'), element('span', '', state));
      if (item.state === 'error') {
        const retry = element('button', 'retry', 'Retry');
        retry.type = 'button';
        retry.addEventListener('click', () => {
          item.state = 'queued'; item.retryAt = 0; item.attempts = 0;
          savePending(); render(); sendPending();
        });
        meta.append(retry);
        const edit = element('button', 'retry', 'Edit');
        edit.type = 'button';
        edit.addEventListener('click', () => {
          draft.value = draft.value ? `${draft.value}\n\n${item.text}` : item.text;
          save(draftKey, draft.value);
          pending.delete(item.id); savePending(); render(); draft.focus();
        });
        meta.append(edit);
      }
      article.append(meta, element('pre', '', item.text));
      ordered.push(article);
    }
    messages.replaceChildren(...ordered);
    byId('empty').hidden = ordered.length > 0;
    older.hidden = !hasOlder || !oldest;
    if (mode === 'prepend') window.scrollTo(0, top + document.documentElement.scrollHeight - height);
    else if (initial || pinned) window.scrollTo(0, document.documentElement.scrollHeight);
  }

  function ingest(batch) {
    let changed = false;
    for (const event of batch) {
      if (event.actor !== 'main' || !Number.isSafeInteger(event.seq)) continue;
      if (!events.has(event.seq)) { events.set(event.seq, event); changed = true; }
      oldest = oldest ? Math.min(oldest, event.seq) : event.seq;
      const clientId = event.data?.message_id || event.id;
      if (pending.delete(clientId)) changed = true;
    }
    if (changed) savePending();
    return changed;
  }

  function activity(status = {}) {
    const actors = Array.isArray(status.actors) ? status.actors : [];
    const main = actors.find(actor => actor.id === 'main');
    const running = Number(status.requests?.running || 0);
    const queued = Number(status.requests?.queued || 0);
    const jobRunning = Number(status.jobs?.running || 0);
    const jobQueued = Number(status.jobs?.queued || 0);
    const pieces = [];
    const terminal = ['idle', 'done', 'completed', 'error', 'stopped', 'cancelled'];
    const active = main ? !terminal.includes(main.status) : running > 0;
    const waiting = main?.status === 'waiting_memory';
    const blocked = main?.status === 'blocked_memory';
    pieces.push(blocked ? 'Memory failed · send a message to retry' : waiting ? 'Preparing memory…' : active ? 'Working…' : 'Ready');
    if (queued) pieces.push(`${queued} queued`);
    if (jobRunning) pieces.push(`${jobRunning} background task${jobRunning === 1 ? '' : 's'} running`);
    if (jobQueued) pieces.push(`${jobQueued} background task${jobQueued === 1 ? '' : 's'} queued`);
    if (status.components?.reactor === false) pieces[0] = 'Agent offline · messages are saved';
    byId('status').textContent = pieces.join(' · ');
    cancel.disabled = !active && !(Number(main?.pending_jobs || 0) > 0);
    const jobs = byId('jobs');
    const tasks = actors.filter(actor => actor.id !== 'main' && !terminal.includes(actor.status));
    jobs.replaceChildren(...tasks.map(actor => element('li', '', `${actor.name || actor.id} · ${actor.status}`)));
    jobs.hidden = tasks.length === 0;
  }

  async function sendOne(item) {
    item.state = 'sending'; savePending(); render();
    try {
      const ack = await request('/api/messages', {text: item.text, id: item.id});
      // The feed can observe a committed message before its acknowledgement.
      if (!pending.has(item.id)) return;
      item.state = 'accepted'; item.seq = Number(ack.seq);
      if (item.seq && item.seq <= cursor) pending.delete(item.id);
      notice.textContent = '';
    } catch (error) {
      if (!pending.has(item.id)) return;
      item.state = error.permanent ? 'error' : 'queued';
      item.attempts = (item.attempts || 0) + 1;
      item.retryAt = Date.now() + Math.min(30000, 1500 * 2 ** Math.min(item.attempts, 4));
      notice.textContent = error.permanent ? error.message : 'Message saved in this browser; retrying when the server returns.';
    } finally { savePending(); render(); sendPending(); }
  }
  function sendPending() {
    clearTimeout(retryTimer); retryTimer = null;
    if (document.hidden) return;
    for (const item of pending.values()) {
      if (item.state === 'sending') return;
      if (item.state !== 'queued') continue;
      const delay = (item.retryAt || 0) - Date.now();
      if (delay > 0) retryTimer = setTimeout(sendPending, delay);
      else sendOne(item);
      return;
    }
  }

  function receive(payload) {
    if (typeof payload !== 'string' || !payload) return;
    let feed;
    try { feed = JSON.parse(payload); }
    catch { return; }
    if (!Array.isArray(feed?.events) || !Number.isSafeInteger(feed.cursor) || feed.cursor < 0) return;
    const changed = ingest(feed.events);
    cursor = Math.max(cursor, feed.cursor);
    let reconciled = false;
    for (const item of pending.values()) {
      if (item.state === 'accepted' && item.seq && item.seq <= cursor) {
        pending.delete(item.id); reconciled = true;
      }
    }
    if (reconciled) savePending();
    if (initial) hasOlder = Boolean(feed.has_more);
    if (changed || initial || reconciled) render();
    activity(feed.status);
    initial = false;
    if (!document.hidden) connectionState('Connected');
    sendPending();
  }

  function connectionState(text) {
    connected = text === 'Connected';
    connection.textContent = text;
    if (connected) connection.classList.remove('offline');
    else connection.classList.add('offline');
  }
  function connect() {
    if (!datastarReady || document.hidden || liveController) return;
    liveController = new AbortController();
    connectionState('Connecting…');
    chat.dispatchEvent(new CustomEvent('chat-connect'));
    sendPending();
  }
  function disconnect() {
    liveController?.abort(); liveController = null;
    clearTimeout(retryTimer); retryTimer = null;
    connectionState('Paused while hidden');
  }

  // Datastar owns transport parsing, backoff, and Last-Event-ID. Aborting its
  // controller also cancels queued reconnects, so hidden tabs remain idle.
  window.harnessChat = {cursor: () => cursor, controller: () => liveController, receive};
  document.addEventListener('datastar-ready', () => { datastarReady = true; connect(); });
  document.addEventListener('visibilitychange', () => {
    if (document.hidden) disconnect();
    else connect();
  });
  window.addEventListener('pagehide', disconnect);
  window.addEventListener('pageshow', connect);
  document.addEventListener('datastar-fetch', event => {
    if (event.detail?.el !== chat || document.hidden || !liveController) return;
    const type = event.detail.type;
    if (type === 'retrying' || type === 'error' || type === 'retries-failed') connectionState('Reconnecting…');
    else if (type === 'datastar-patch-signals') {
      const recovered = !connected;
      connectionState('Connected');
      // Signal effects ingest committed inputs before reconnect retries send.
      queueMicrotask(() => {
        if (recovered) for (const item of pending.values()) if (item.state === 'queued') item.retryAt = 0;
        sendPending();
      });
    }
  });

  older.addEventListener('click', async () => {
    if (loadingOlder || !oldest) return;
    loadingOlder = true; older.disabled = true; older.textContent = 'Loading…';
    try {
      const feed = await request(`/api/events?before=${oldest}&limit=100`);
      ingest(feed.events || []);
      hasOlder = Boolean(feed.has_more);
      render('prepend');
    } catch { notice.textContent = 'Earlier messages could not load. Try again when connected.'; }
    finally {
      loadingOlder = false; older.disabled = false; older.textContent = 'Load earlier messages';
    }
  });
  draft.addEventListener('input', () => save(draftKey, draft.value));
  byId('compose').addEventListener('submit', event => {
    event.preventDefault();
    if (!draft.value.trim()) return;
    const id = globalThis.crypto?.randomUUID?.() || `${Date.now()}-${Math.random().toString(16).slice(2)}`;
    pending.set(id, {id, text: draft.value, state: 'queued', retryAt: 0});
    savePending();
    draft.value = ''; save(draftKey, '');
    render(); sendPending(); draft.focus();
  });
  draft.addEventListener('keydown', event => {
    if (event.key === 'Enter' && (event.ctrlKey || event.metaKey)) {
      event.preventDefault(); byId('compose').requestSubmit();
    }
  });
  cancel.addEventListener('click', async () => {
    cancel.disabled = true;
    try { await request('/api/cancel', {}); notice.textContent = 'Stop requested.'; }
    catch { notice.textContent = 'Could not request a stop. Try again when connected.'; }
  });
  render();
  if (document.hidden) connectionState('Paused while hidden');
})();
