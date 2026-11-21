// Duty service worker: web push notifications that open the screen each one links to, and an
// offline app shell (decision 2026-11-06): the document, its static assets and the public
// configuration are cached, so the last schedule the app saved stays viewable with no network.
// Team data itself is never cached here; the app keeps its last snapshot per member.
const CACHE = 'duty-shell-v1';
const SHELL = ['/', '/manifest.webmanifest', '/icon-192.png', '/icon-512.png', '/favicon.svg'];
const LINK = /^\/\?[a-z]+=[A-Za-z0-9=&_-]*$/;

self.addEventListener('install', event => {
  event.waitUntil(caches.open(CACHE).then(cache => cache.addAll(SHELL)).catch(() => {}).then(() => self.skipWaiting()));
});
self.addEventListener('activate', event => {
  event.waitUntil(caches.keys().then(keys => Promise.all(keys.filter(key => key !== CACHE && key !== LINKS).map(key => caches.delete(key)))).then(() => self.clients.claim()));
});

self.addEventListener('fetch', event => {
  const {request} = event;
  if (request.method !== 'GET') return;
  const url = new URL(request.url);
  if (url.origin !== self.location.origin) return;
  // The document and the public configuration: the network first, the last copy without it.
  if (request.mode === 'navigate' || url.pathname === '/api/config') {
    const key = request.mode === 'navigate' ? '/' : url.pathname;
    event.respondWith(fetch(request).then(response => {
      if (response.ok) caches.open(CACHE).then(cache => cache.put(key, response.clone())).catch(() => {});
      return response;
    }).catch(() => caches.match(key).then(cached => cached ?? Response.error())));
    return;
  }
  // Hashed static assets never change: the cache first, filled from the network.
  if (url.pathname.startsWith('/_next/static/') || SHELL.includes(url.pathname)) {
    event.respondWith(caches.match(request).then(cached => cached ?? fetch(request).then(response => {
      if (response.ok) caches.open(CACHE).then(cache => cache.put(request, response.clone())).catch(() => {});
      return response;
    })));
  }
});

self.addEventListener('push', event => {
  let data = {};
  try {data = event.data ? event.data.json() : {};} catch {data = {};}
  const text = value => typeof value === 'string' ? value.slice(0, 200) : '';
  const lang = data.lang === 'he' ? 'he' : 'en';
  const url = typeof data.url === 'string' && LINK.test(data.url) ? data.url : '/';
  event.waitUntil(self.registration.showNotification(text(data.title) || 'MiKo', {
    body: text(data.body), lang, dir: lang === 'he' ? 'rtl' : 'ltr', tag: text(data.tag) || undefined,
    icon: '/icon-192.png', badge: '/icon-192.png', data: {url},
  }));
});

// A tap with the app already open (issue #89 rule 2) navigates that window, never a second one.
// A backgrounded phone app can miss a message (iOS/Android freeze it), so three layers:
// 1. the link is stashed first, and the app reads (and removes) it when it comes back to the foreground,
//    even when the phone does not list the suspended window at all;
// 2. the window is focused and sent the link, which the app acknowledges on a port;
// 3. with no acknowledgement in time, the window itself navigates to the link.
const LINKS = 'duty-links-v1', PENDING = '/__duty-pending-link', ACK_MS = 2500;
const stash = link => caches.open(LINKS).then(cache => cache.put(PENDING, new Response(JSON.stringify({url: link, at: Date.now()})))).catch(() => {});
// Resolves true when the stash was still there (the app never read it).
const unstash = () => caches.open(LINKS).then(cache => cache.delete(PENDING)).catch(() => true);
// To every open page of the app, listed by the phone or not (components/rota/workspace.tsx).
function broadcast(link) {
  try {const channel = new BroadcastChannel('duty-links'); channel.postMessage({type: 'duty-open', url: link}); channel.close();} catch {}
}
function acknowledged(client, link) {
  return new Promise(resolve => {
    let channel;
    const settle = heard => {clearTimeout(timer); channel?.port1.close(); resolve(heard);};
    const timer = setTimeout(() => settle(false), ACK_MS);
    try {
      channel = new MessageChannel();
      channel.port1.onmessage = () => settle(true);
      client.postMessage({type: 'duty-open', url: link}, [channel.port2]);
    } catch {settle(false);}
  });
}
self.addEventListener('notificationclick', event => {
  event.notification.close();
  const link = event.notification.data && LINK.test(event.notification.data.url) ? event.notification.data.url : '/';
  const target = new URL(link, self.location.origin).href;
  event.waitUntil((async () => {
    // First, whatever follows: a suspended phone app is often not listed below, and openWindow then
    // only brings the running app forward unchanged; the app takes this link when it comes forward.
    await stash(link);
    broadcast(link);
    const windows = (await self.clients.matchAll({type: 'window', includeUncontrolled: true})).filter(client => new URL(client.url).origin === self.location.origin);
    // The window the user last looked at: focused, then visible, then any.
    const open = windows.find(client => client.focused) ?? windows.find(client => client.visibilityState === 'visible') ?? windows[0];
    // A cold start opens on the link itself and drops the stash (components/rota/workspace.tsx).
    if (!open) {
      await self.clients.openWindow(target);
      // iOS: openWindow only brings a suspended app forward, which lists its window a moment later.
      await new Promise(resolve => setTimeout(resolve, 1000));
      for (const client of await self.clients.matchAll({type: 'window', includeUncontrolled: true}))
        if (new URL(client.url).origin === self.location.origin) try {client.postMessage({type: 'duty-open', url: link});} catch {}
      broadcast(link);
      return;
    }
    let client = open;
    try {client = (await open.focus()) ?? open;} catch {}
    if (await acknowledged(client, link)) {await unstash(); return;}
    // The app read the stash on resuming: done. Not heard at all: a reload on the link
    // (only a controlled window can navigate), else a new window.
    if (!await unstash()) return;
    try {if (await client.navigate(target)) return;} catch {}
    await self.clients.openWindow(target);
  })());
});
