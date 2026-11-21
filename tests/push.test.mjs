// Web push (decision 2026-11-06): the sender's text, validation, outcomes and secret check,
// and the settings helpers. Who is told what and when lives in the database and is
// covered by supabase/tests/push.sql (deadlines, reminder times, swaps, switches,
// language and idempotency).
import test from 'node:test';
import assert from 'node:assert/strict';
import {PUSH_KINDS, pushLink, pushText, pushDate, pushMonth} from '../lib/push/messages.ts';
import {readFileSync} from 'node:fs';
import vm from 'node:vm';
import {authorized, dispatch, outcome, parseDispatch, payload, refusalLog, serviceReason} from '../lib/push/dispatch.ts';
import {supportedPushEndpoint, base64url, vapidKeyBytes, validVapidPublicKey, vapidSubjectProblem} from '../lib/push/endpoint.ts';
import {DEFAULT_SETTINGS, deepLink, readNotificationState, settingsPayload, validTime} from '../lib/push/settings.ts';
import {POST} from '../app/api/push/dispatch/route.ts';

const params = {month: '2026-12', deadline: '2026-11-24', version: 2, day: '2026-12-03', count: 2, fromDay: '2026-12-03', toDay: '2026-12-10',
  endDay: '2026-12-04', role: 'primary', name: 'Dana Levi'};
const message = (over = {}) => ({id: '12', endpoint: 'https://fcm.googleapis.com/fcm/send/device-1', keys: {p256dh: 'B'.repeat(87), auth: 'A'.repeat(22)},
  lang: 'en', kind: 'remind_evening', params: {day: '2026-12-03', endDay: '2026-12-04', role: 'primary'}, url: '/?tab=schedule&month=2026-12', tag: 'duty-12', ...over});

test('every kind has its own English and Hebrew text with the dates in Israel', () => {
  const seen = new Set();
  for (const kind of PUSH_KINDS) {
    const en = pushText(kind, params, 'en'), he = pushText(kind, params, 'he');
    assert.ok(en.title && en.body && he.title && he.body, kind);
    assert.ok(/[a-z]/.test(en.title + en.body) && /[֐-׿]/.test(he.title + he.body), `${kind} languages`);
    assert.notDeepEqual(en, he, kind);
    assert.ok(!/undefined|NaN|null/.test(JSON.stringify([en, he])), `${kind} has no missing values`);
    seen.add(en.title);
  }
  assert.ok(seen.size >= PUSH_KINDS.length - 1, 'titles tell the kinds apart');
  assert.equal(pushDate('2026-12-03', 'en'), 'Thu, Dec 3');
  assert.equal(pushDate('2026-12-03', 'he'), 'יום ה׳, 3 בדצמ׳');
  assert.equal(pushMonth('2026-12', 'en'), 'December 2026');
  assert.equal(pushText('deadline_3', params, 'en').body, 'Enter your December 2026 constraints by Tue, Nov 24.');
  assert.equal(pushText('remind_evening', {...params, role: 'secondary'}, 'en').title, 'Emergency cover tomorrow');
  assert.equal(pushText('remind_morning', params, 'en').body, 'You’re on duty today, Thu, Dec 3.');
  assert.equal(pushText('swap_new', params, 'en').body, 'Swap Thu, Dec 3 ↔ Thu, Dec 10. Open it to answer.');
  assert.equal(pushText('edit', {...params, count: 1}, 'en').body, 'An admin changed your duty on Thu, Dec 3.');
});

test('text never shows malformed or injected values', () => {
  assert.equal(pushDate('2026-13-45x', 'en'), '');
  assert.equal(pushMonth('2026-13', 'en'), '');
  const text = pushText('member_waiting', {name: 'Eve\u0000\nInjected'.padEnd(200, 'x')}, 'en');
  assert.ok(!/[\u0000-\u001f]/.test(text.body) && text.body.length < 120);
  assert.equal(pushText('member_waiting', {}, 'en').body, 'Someone is waiting for your approval.');
});

test('the scheduler request is validated exactly', () => {
  assert.equal(parseDispatch({messages: [message()]})?.length, 1);
  const cleaned = parseDispatch({messages: [message({params: {...params, note: 'private', day: 'nope'}})]})[0].params;
  assert.equal(cleaned.day, undefined); assert.ok(!('note' in cleaned)); assert.equal(cleaned.month, '2026-12'); assert.equal(cleaned.name, 'Dana Levi');
  for (const bad of [null, {}, {messages: 'x'}, {messages: [message({id: 'x'})]}, {messages: [message({lang: 'fr'})]}, {messages: [message({kind: 'other'})]},
    {messages: [message({url: 'https://evil.example/'})]}, {messages: [message({url: '/?tab=x&next=//evil'})]}, {messages: [message({tag: 'Bad Tag'})]},
    {messages: [message({keys: null})]}, {messages: Array.from({length: 101}, () => message())}]) assert.equal(parseDispatch(bad), null, JSON.stringify(bad)?.slice(0, 80));
});

test('push service answers become outcomes; only explicit refusals are retried', () => {
  assert.equal(outcome(201), 'sent'); assert.equal(outcome(200), 'sent');
  assert.equal(outcome(404), 'gone'); assert.equal(outcome(410), 'gone');
  assert.equal(outcome(429), 'retry'); assert.equal(outcome(503), 'retry');
  assert.equal(outcome(400), 'rejected'); assert.equal(outcome(413), 'rejected'); assert.equal(outcome(403), 'rejected');
  assert.equal(outcome(undefined), 'unknown');
});

test('dispatch writes each message in its own language and never contacts other hosts', async () => {
  const sent = [];
  const send = async (subscription, body, options) => {
    sent.push({subscription, body: JSON.parse(body), options});
    if (subscription.endpoint.endsWith('gone')) throw Object.assign(Error('gone'), {statusCode: 410});
    if (subscription.endpoint.endsWith('busy')) throw Object.assign(Error('busy'), {statusCode: 429});
    if (subscription.endpoint.endsWith('lost')) throw Error('socket hang up');
    return {statusCode: 201};
  };
  const result = await dispatch([
    message({id: '1'}), message({id: '2', lang: 'he', endpoint: 'https://web.push.apple.com/device-gone'}),
    message({id: '3', endpoint: 'https://updates.push.services.mozilla.com/wpush/v2/busy'}), message({id: '4', endpoint: 'https://fcm.googleapis.com/fcm/send/lost'}),
    message({id: '5', endpoint: 'https://evil.example/fcm/send/x'}), message({id: '6', endpoint: 'http://fcm.googleapis.com/fcm/send/x'}),
    message({id: '7', keys: {p256dh: 'short', auth: 'A'.repeat(22)}}),
  ], send);
  assert.deepEqual(result.results, [{id: '1', outcome: 'sent', status: 201}, {id: '2', outcome: 'gone', status: 410}, {id: '3', outcome: 'retry', status: 429},
    {id: '4', outcome: 'unknown'}, {id: '5', outcome: 'rejected'}, {id: '6', outcome: 'rejected'}, {id: '7', outcome: 'rejected'}]);
  assert.equal(sent.length, 4, 'only allowed push services with valid keys are contacted');
  assert.deepEqual(sent[0].body, {title: 'Duty tomorrow', body: 'You’re on duty on Thu, Dec 3.', url: '/?tab=schedule&month=2026-12&duty=2026-12-03', tag: 'duty-12', lang: 'en'});
  assert.equal(sent[1].body.lang, 'he'); assert.equal(sent[1].body.title, 'כוננות מחר');
  assert.deepEqual(sent[0].options, {TTL: 21600, urgency: 'high', topic: 'duty-12'});
  assert.equal(JSON.parse(payload(message({kind: 'published', params: {month: '2026-12'}}))).title, 'December 2026 is published');
});

test('the shared secret is compared exactly', () => {
  const secret = 's'.repeat(40);
  assert.equal(authorized(`Bearer ${secret}`, secret), true);
  for (const header of [null, '', secret, `Bearer ${secret}x`, `Bearer ${'s'.repeat(39)}`, `bearer ${secret}`]) assert.equal(authorized(header, secret), false, String(header));
  assert.equal(authorized('Bearer short', 'short'), false, 'a short configured secret is refused');
  assert.equal(authorized(`Bearer ${secret}`, undefined), false);
});

test('only known push services; keys are base64url', () => {
  for (const ok of ['https://fcm.googleapis.com/fcm/send/abc-123', 'https://web.push.apple.com/QGmBz', 'https://api.push.apple.com/x/y',
    'https://updates.push.services.mozilla.com/wpush/v2/x', 'https://wns2-par02p.notify.windows.com/w/?token=x', 'https://fcm.googleapis.com:443/fcm/send/abc'])
    assert.equal(supportedPushEndpoint(ok), true, ok);
  for (const bad of ['http://fcm.googleapis.com/fcm/send/abc', 'https://fcm.googleapis.com.evil.example/x', 'https://evil.example/fcm.googleapis.com/x',
    'https://user@fcm.googleapis.com/fcm/send/abc', 'https://fcm.googleapis.com:8443/fcm/send/abc', 'https://localhost/fcm/send/abcdef', 'https://fcm.googleapis.com',
    'x'.repeat(30), null, 42]) assert.equal(supportedPushEndpoint(bad), false, String(bad));
  const bytes = new Uint8Array(65).map((_, i) => i * 7);
  assert.equal(base64url(bytes.buffer), Buffer.from(bytes).toString('base64url'));
  assert.equal(base64url(null), '');
  const key = Buffer.from(new Uint8Array(65).fill(4)).toString('base64url');
  assert.equal(validVapidPublicKey(key), true);
  assert.deepEqual([...vapidKeyBytes(key)], Array(65).fill(4));
  assert.equal(validVapidPublicKey('short'), false);
});

test('settings: exact payload, valid times and safe links', () => {
  assert.deepEqual(settingsPayload({...DEFAULT_SETTINGS, devices: 3, extra: 1}), DEFAULT_SETTINGS);
  assert.throws(() => settingsPayload({...DEFAULT_SETTINGS, eveningTime: '24:00'}), /Invalid notification time/);
  for (const ok of ['00:00', '08:30', '18:00', '23:45']) assert.equal(validTime(ok), true, ok);
  for (const bad of ['24:00', '8:30', '08:60', '08:10', '23:59', '', null, '08:30:00']) assert.equal(validTime(bad), false, String(bad));
  assert.deepEqual(readNotificationState({...DEFAULT_SETTINGS, devices: 2, other: 'x'}), {...DEFAULT_SETTINGS, devices: 2});
  assert.throws(() => readNotificationState({...DEFAULT_SETTINGS, devices: -1}), /Could not load notification settings/);
  assert.throws(() => readNotificationState({...DEFAULT_SETTINGS, swaps: 'yes', devices: 0}), /Could not load notification settings/);
  assert.deepEqual(deepLink('?tab=availability&month=2026-12'), {tab: 'availability', month: '2026-12'});
  assert.deepEqual(deepLink('?tab=admin&month=2026-13'), {});
  assert.deepEqual(deepLink(''), {});
});

test('the sender refuses before sending: no secret, wrong secret, no VAPID keys, bad body', async () => {
  const saved = {...process.env};
  const call = (body, auth) => POST(new Request('http://localhost/api/push/dispatch', {method: 'POST', body, headers: auth ? {authorization: auth} : {}}));
  try {
    delete process.env.DUTY_PUSH_SECRET;
    assert.equal((await call('{}', 'Bearer x')).status, 503);
    process.env.DUTY_PUSH_SECRET = 's'.repeat(40);
    assert.equal((await call('{}', 'Bearer wrong')).status, 401);
    assert.equal((await call('{}')).status, 401);
    delete process.env.VAPID_PUBLIC_KEY;
    assert.equal((await call('{}', `Bearer ${'s'.repeat(40)}`)).status, 503);
    process.env.VAPID_PUBLIC_KEY = Buffer.from(new Uint8Array(65).fill(4)).toString('base64url');
    process.env.VAPID_PRIVATE_KEY = Buffer.from(new Uint8Array(32).fill(9)).toString('base64url');
    // Apple refuses every send signed with a placeholder subject: refused first, with the reason.
    process.env.VAPID_SUBJECT = 'mailto:duty@example.invalid';
    const placeholder = await call('{}', `Bearer ${'s'.repeat(40)}`);
    assert.equal(placeholder.status, 503);
    assert.match((await placeholder.json()).error, /example.invalid.*Apple/);
    process.env.VAPID_SUBJECT = 'https://miko-prod.vercel.app';
    assert.equal((await call('not json', `Bearer ${'s'.repeat(40)}`)).status, 400);
    assert.equal((await call(JSON.stringify({messages: [message({lang: 'fr'})]}), `Bearer ${'s'.repeat(40)}`)).status, 400);
    assert.equal((await call('x'.repeat(200_001), `Bearer ${'s'.repeat(40)}`)).status, 413);
    // A message to an unknown host is answered without any network request.
    const response = await call(JSON.stringify({messages: [message({endpoint: 'https://evil.example/x/y'})]}), `Bearer ${'s'.repeat(40)}`);
    assert.equal(response.status, 200);
    assert.deepEqual(await response.json(), {results: [{id: '12', outcome: 'rejected'}]});
  } finally {
    for (const key of ['DUTY_PUSH_SECRET', 'VAPID_PUBLIC_KEY', 'VAPID_PRIVATE_KEY', 'VAPID_SUBJECT']) if (key in saved) process.env[key] = saved[key]; else delete process.env[key];
  }
});

test('signing out and turning off always unsubscribe this browser, even when the server call fails or hangs', async () => {
  const {disablePush, forgetDevice} = await import('../lib/push/browser.ts');
  const saved = Object.getOwnPropertyDescriptor(globalThis, 'navigator'), savedWindow = globalThis.window;
  let unsubscribed = 0;
  const subscription = {endpoint: 'https://fcm.googleapis.com/fcm/send/x', unsubscribe: async () => {unsubscribed++; return true;}};
  Object.defineProperty(globalThis, 'navigator', {configurable: true, value: {serviceWorker: {getRegistration: async () => ({pushManager: {getSubscription: async () => subscription}})}}});
  globalThis.window = {PushManager() {}, Notification() {}};
  try {
    await forgetDevice(async () => {throw Error('offline');});
    await forgetDevice(() => new Promise(() => {}), 10);
    await assert.rejects(disablePush(async () => {throw Error('offline');}), /offline/);
    assert.equal(unsubscribed, 3);
  } finally {
    if (saved) Object.defineProperty(globalThis, 'navigator', saved); else delete globalThis.navigator;
    globalThis.window = savedWindow;
  }
});

test('the VAPID subject must be a real mailto: address or https URL, never a placeholder', () => {
  for (const ok of ['mailto:omri@datateam.co.il', 'https://miko-prod.vercel.app', 'https://abc-12.ngrok-free.app', 'https://duty.example.co.il/'])
    assert.equal(vapidSubjectProblem(ok), null, ok);
  for (const bad of [undefined, '', 'duty@x.com', 'mailto:duty-local@example.invalid', 'mailto:you@example.com', 'mailto:a@localhost', 'mailto:nobody',
    'https://localhost:5173', 'https://127.0.0.1', 'https://host.docker.internal', 'https://duty.test', 'https://user:pw@duty.co.il', 'http://duty.co.il'])
    assert.notEqual(vapidSubjectProblem(bad), null, String(bad));
});

test('a refusal carries the push service reason, without endpoints or keys', async () => {
  assert.equal(serviceReason('{"reason":"BadJwtToken"}'), 'BadJwtToken');
  assert.equal(serviceReason('<html><body>Error 403 (Forbidden) see https://fcm.googleapis.com/fcm/send/abcdefghijklmnopqrstuvwxyz0123456789</body></html>'), 'Error 403 (Forbidden) see …');
  assert.equal(serviceReason('token cXdlcnR5dWlvcGFzZGZnaGprbHp4Y3Zibm0xMjM0NTY3 invalid'), 'token … invalid');
  assert.equal(serviceReason(''), undefined);
  assert.equal(serviceReason(undefined), undefined);
  assert.ok(serviceReason('x'.repeat(10) + ' '.repeat(5) + 'y '.repeat(200)).length <= 160);
  const apple = message({endpoint: 'https://web.push.apple.com/QGAbCdEfGhIjKlMnOpQrStUvWxYz0123456789'});
  const result = await dispatch([apple], async () => {throw Object.assign(new Error('Received unexpected response code'), {statusCode: 403, body: '{"reason":"BadJwtToken"}'});});
  assert.deepEqual(result.results, [{id: '12', outcome: 'rejected', status: 403, reason: 'BadJwtToken'}]);
  const [line] = refusalLog([apple], result.results);
  assert.equal(line, 'duty push: web.push.apple.com refused remind_evening (403: BadJwtToken) → rejected');
  assert.ok(!line.includes('QGAb') && !line.includes(apple.keys.p256dh));
  assert.deepEqual(refusalLog([apple], [{id: '12', outcome: 'sent', status: 201}]), []);
});

test('every notification carries its own tag, so a new event of the same kind alerts instead of replacing the last', () => {
  const first = JSON.parse(payload(message({id: '12', tag: 'duty-101', kind: 'published', params: {month: '2026-12'}}))), second = JSON.parse(payload(message({id: '13', tag: 'duty-102', kind: 'published', params: {month: '2026-12'}})));
  assert.equal(first.tag, 'duty-101');
  assert.equal(second.tag, 'duty-102');
  assert.notEqual(first.tag, second.tag);
});

// Issue #89 rule 1: every notification kind opens the screen it is about.
test('#89 rule 1: each kind links to its own screen: the request, the duty day, the approvals', () => {
  const request = '30000000-0000-4000-8000-0000000000aa', p = {...params, request}, db = '/?tab=schedule&month=2026-12';
  const expected = {
    deadline_3: '/?tab=availability&month=2026-12', deadline_1: '/?tab=availability&month=2026-12',
    published: '/?tab=schedule&month=2026-12', republished: '/?tab=schedule&month=2026-12',
    edit: '/?tab=schedule&month=2026-12&day=2026-12-03',
    swap_new: `/?tab=home&swap=${request}&month=2026-12&day=2026-12-03&or=2026-12-10`, swap_accepted: `/?tab=home&swap=${request}&month=2026-12&day=2026-12-03&or=2026-12-10`,
    swap_awaiting_admin: `/?tab=home&swap=${request}&month=2026-12&day=2026-12-03&or=2026-12-10`,
    // Both dates of a settled swap: each recipient's app opens the one that is theirs now.
    swap_declined: '/?tab=schedule&month=2026-12&day=2026-12-03&or=2026-12-10', swap_rejected: '/?tab=schedule&month=2026-12&day=2026-12-03&or=2026-12-10',
    swap_approved: '/?tab=schedule&month=2026-12&day=2026-12-03&or=2026-12-10',
    remind_evening: '/?tab=schedule&month=2026-12&duty=2026-12-03', remind_morning: '/?tab=schedule&month=2026-12&duty=2026-12-03',
    member_waiting: '/?tab=team&focus=approvals',
  };
  assert.deepEqual(Object.keys(expected).sort(), [...PUSH_KINDS].sort(), 'every existing kind is covered');
  for (const kind of PUSH_KINDS) {
    assert.equal(pushLink(kind, p, db), expected[kind], kind);
    // The sender carries the request id through validation into the notification.
    const [parsed] = parseDispatch({messages: [message({kind, params: p, url: db})]});
    assert.equal(JSON.parse(payload(parsed)).url, expected[kind], `${kind} payload`);
    assert.deepEqual(deepLink(expected[kind].slice(1)).tab, expected[kind].match(/tab=([a-z]+)/)[1], `${kind} the app reads the tab`);
  }
  // Missing or malformed params keep the database's link; a bad request id never reaches the URL.
  assert.equal(pushLink('remind_morning', {}, db), db);
  assert.equal(pushLink('swap_new', {...params, request: 'x&tab=team'}, db), '/?tab=schedule&month=2026-12&day=2026-12-03&or=2026-12-10');
  assert.deepEqual(deepLink(`?tab=home&swap=${request}&month=2026-12&day=2026-12-03`), {tab: 'home', swap: request, month: '2026-12', day: '2026-12-03'});
  assert.deepEqual(deepLink('?tab=schedule&duty=2026-12-03&focus=approvals'), {tab: 'schedule', duty: '2026-12-03', focus: 'approvals'});
  assert.deepEqual(deepLink('?day=2026-13-01&duty=x&swap=a%20b&focus=all'), {});
});

// Issue #89 rule 2: the service worker reuses an open window; it opens one only when none is open.
// Mirrors a phone: matchAll includes uncontrolled windows, focus() may fail, and a backgrounded
// app may miss the message (no ack) or read the stashed link on resuming instead.
async function tapNotification(windows, url, app = 'ack', later = null) {
  const listeners = {}, calls = {opened: [], posted: [], focused: [], navigated: [], broadcast: []}, store = new Map();
  const caches = {open: async () => ({put: async (key, response) => {store.set(key, await response.text());}, delete: async key => store.delete(key), match: async key => store.get(key)}),
    keys: async () => [], delete: async () => true};
  const client = w => ({url: 'https://miko.example/', focused: false, visibilityState: 'hidden', ...w,
    postMessage(data, ports) {
      calls.posted.push({client: this.name, ...data});
      if (app === 'ack') ports[0].postMessage('duty-opened');
      if (app === 'resume') store.delete('/__duty-pending-link'); // the app took the stash instead
    },
    async focus() {calls.focused.push(this.name); if (w.focusFails) throw Error('not allowed'); return this;},
    async navigate(href) {if (w.uncontrolled) throw TypeError('not controlled'); calls.navigated.push(href); return this;}});
  const clients = windows.map(client);
  later = later && later.map(client);
  const self = {location: new URL('https://miko.example/'), addEventListener: (type, fn) => {listeners[type] = fn;},
    clients: {matchAll: async options => {calls.options = options; const listed = later && calls.opened.length ? later : clients; return listed;}, openWindow: async href => {calls.opened.push(href);}}, registration: {}};
  vm.runInNewContext(readFileSync(new URL('../public/sw.js', import.meta.url), 'utf8'),
    {self, URL, caches, fetch: () => {}, Response, MessageChannel, setTimeout: fn => setTimeout(fn, 5), clearTimeout, Date, JSON,
      BroadcastChannel: class {constructor(name) {this.name = name;} postMessage(data) {calls.broadcast.push({channel: this.name, ...data});} close() {}}});
  let done;
  listeners.notificationclick({notification: {data: {url}, close() {}}, waitUntil: promise => {done = promise;}});
  await done;
  return JSON.parse(JSON.stringify({...calls, stashed: store.size})); // plain objects from the worker's own realm
}
test('#89 rule 2: tapping with the app open navigates that window instead of opening a second one', async () => {
  const link = '/?tab=home&swap=30000000-0000-4000-8000-0000000000aa&month=2026-12&day=2026-12-03', href = `https://miko.example${link}`;
  // The app hears it and acknowledges: focused and told, nothing reloads or opens.
  const heard = await tapNotification([{name: 'app'}], link);
  assert.deepEqual(heard.options, {type: 'window', includeUncontrolled: true});
  delete heard.options;
  assert.deepEqual(heard, {opened: [], posted: [{client: 'app', type: 'duty-open', url: link}], focused: ['app'], navigated: [], stashed: 0,
    broadcast: [{channel: 'duty-links', type: 'duty-open', url: link}]});
  // Backgrounded and frozen, the message is lost: the window itself navigates to the link.
  const lost = await tapNotification([{name: 'app'}], link, 'lost');
  assert.deepEqual([lost.navigated, lost.opened, lost.stashed], [[href], [], 0]);
  // Resumed, the app read the stashed link instead of the message: no reload.
  const resumed = await tapNotification([{name: 'app'}], link, 'resume');
  assert.deepEqual([resumed.navigated, resumed.opened], [[], []]);
  // focus() refused (some phones): still told, and still no second window.
  const refused = await tapNotification([{name: 'app', focusFails: true}], link);
  assert.deepEqual([refused.posted.length, refused.opened], [1, []]);
  // An uncontrolled window cannot navigate: only then a new window.
  assert.deepEqual((await tapNotification([{name: 'app', uncontrolled: true}], link, 'lost')).opened, [href]);
  // Several windows: the one the user last looked at.
  const many = await tapNotification([{name: 'old'}, {name: 'shown', visibilityState: 'visible'}, {name: 'other', url: 'https://other.example/'}], link);
  assert.deepEqual(many.focused, ['shown']);
  // No window listed (closed, or a suspended phone app the phone does not list): one opens on the
  // link, and the link stays stashed for a running app to take when it comes forward.
  const closed = await tapNotification([], link);
  assert.deepEqual([closed.opened, closed.posted, closed.stashed], [[href], [], 1]);
  // iOS: a suspended app is not listed, openWindow just brings it forward, and its window is listed
  // a moment later: it is sent the link then, and the link is broadcast to every page of the app.
  const suspended = await tapNotification([], link, 'ack', [{name: 'app'}]);
  assert.deepEqual(suspended.opened, [href]);
  assert.deepEqual(suspended.posted, [{client: 'app', type: 'duty-open', url: link}]);
  assert.equal(suspended.broadcast.length, 2);
  assert.deepEqual((await tapNotification([], 'https://evil.example/')).opened, ['https://miko.example/']);
});
