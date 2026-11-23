// Issue #89: a tapped notification opens the screen it is about (links built by lib/push/messages.ts pushLink).
import type {Page} from '@playwright/test';
import {test, expect, ids, NOW, MONTH, type Backend} from './fixtures';

const REQUEST = '30000000-0000-4000-8000-0000000000aa';
const tab = (page: Page, name: string) => page.getByRole('tab', {name, exact: true});
const day = (page: Page, date: string) => page.locator(`button[data-date="${date}"]`).first();

// Blair asks Alex to swap 3 ↔ 2 November: the request waits for Alex.
function openRequest(backend: Backend, id = REQUEST, requester = ids.b, other = ids.a) {
  const from = backend.raw.assignments.find(d => d.day === '2026-11-03' && d.publication_id)!, to = backend.raw.assignments.find(d => d.day === '2026-11-02' && d.publication_id)!;
  backend.raw.swapRequests!.unshift({id, month: MONTH, source_publication_id: from.publication_id!, requester_id: requester, other_id: other, from_day: from.day, from_end_day: from.end_day,
    to_day: to.day, to_end_day: to.end_day, explanation: '', status: 'awaiting_engineer', accepted_by: null, accepted_at: null, created_at: NOW, resolved_at: null, resolved_by: null,
    result_publication_id: null, override_reason: '', proposed_by: null, requester_accepted_at: null});
}
async function tap(page: Page, link: string) {
  await page.goto(link);
  await expect(page.locator('[data-settings-button]')).toBeVisible();
}

test('#89 rule 1: a swap request notification opens that request', async ({page, openApp, backend}) => {
  openRequest(backend);
  await openApp('a', page, {month: null});
  await tap(page, `/?tab=home&swap=${REQUEST}&month=${MONTH}&day=2026-11-03`);
  await expect(tab(page, 'Home')).toHaveAttribute('aria-selected', 'true');
  await expect(page.locator(`[data-swap-card="${REQUEST}"]`)).toBeInViewport();
  await expect(page).toHaveURL(/\/$/);
});

test('#89 rule 1: a duty reminder opens that duty day', async ({page, openApp}) => {
  await openApp('a', page, {month: null});
  await tap(page, '/?tab=schedule&month=2026-11&duty=2026-11-02');
  await expect(tab(page, 'Schedule')).toHaveAttribute('aria-selected', 'true');
  await expect(day(page, '2026-11-02')).toHaveClass(/flash-day/);
  await expect(day(page, '2026-11-02')).toBeInViewport();
  await expect(page.getByText('This duty has changed', {exact: false})).toHaveCount(0);
});

test('#89 rule 1: an admin approval notification opens the approvals list', async ({page, openApp}) => {
  await openApp('admin', page, {month: null});
  await tap(page, '/?tab=team&focus=approvals');
  await expect(tab(page, 'Team')).toHaveAttribute('aria-selected', 'true');
  await expect(page.locator('.join-requests')).toBeInViewport();
  await expect(page.getByText('Pat Pending', {exact: true})).toBeVisible();
});

test('#89 rule 2: with the app open, a tap navigates in place without reloading', async ({page, openApp, backend}) => {
  openRequest(backend);
  await openApp('a', page);
  await expect(page.locator('[data-settings-button]')).toBeVisible();
  await page.evaluate(() => {(window as unknown as {sameWindow: boolean}).sameWindow = true;});
  // public/sw.js focuses the open window and posts the link with a reply port (unit-tested in
  // tests/push.test.mjs); the app must acknowledge, or the worker reloads the window on the link.
  const post = (url: string) => page.evaluate(url => new Promise<unknown>(resolve => {
    const channel = new MessageChannel();
    channel.port1.onmessage = event => resolve(event.data);
    setTimeout(() => resolve('no answer'), 2000);
    navigator.serviceWorker.dispatchEvent(new MessageEvent('message', {data: {type: 'duty-open', url}, ports: [channel.port2]}));
  }), url);
  expect(await post('/?tab=schedule&month=2026-11&duty=2026-11-02')).toBe('duty-opened');
  await expect(tab(page, 'Schedule')).toHaveAttribute('aria-selected', 'true');
  await expect(day(page, '2026-11-02')).toHaveClass(/flash-day/);
  expect(await post(`/?tab=home&swap=${REQUEST}&month=${MONTH}&day=2026-11-03`)).toBe('duty-opened');
  await expect(tab(page, 'Home')).toHaveAttribute('aria-selected', 'true');
  await expect(page.locator(`[data-swap-card="${REQUEST}"]`)).toBeInViewport();
  expect(await page.evaluate(() => (window as unknown as {sameWindow?: boolean}).sameWindow)).toBe(true);
});

test('#89 rule 2: resumed from the background after missing the message, the app opens the stashed link', async ({page, openApp, backend}) => {
  openRequest(backend);
  await openApp('a', page);
  await expect(tab(page, 'Home')).toHaveAttribute('aria-selected', 'true');
  await page.evaluate(() => {(window as unknown as {sameWindow: boolean}).sameWindow = true;});
  // Backgrounded: the phone froze the page, so the worker's message never arrived; the worker
  // stashed the link (public/sw.js) and focused the window, which comes back to the foreground.
  const visibility = (state: 'hidden' | 'visible') => page.evaluate(state => {
    Object.defineProperty(document, 'visibilityState', {configurable: true, get: () => state});
    document.dispatchEvent(new Event('visibilitychange'));
  }, state);
  await visibility('hidden');
  await page.evaluate(() => caches.open('duty-links-v1').then(cache => cache.put('/__duty-pending-link',
    new Response(JSON.stringify({url: '/?tab=schedule&month=2026-11&duty=2026-11-02', at: Date.now()})))));
  await visibility('visible');
  await expect(tab(page, 'Schedule')).toHaveAttribute('aria-selected', 'true');
  await expect(day(page, '2026-11-02')).toHaveClass(/flash-day/);
  // Taken once: the worker sees it gone and does not reload the window.
  expect(await page.evaluate(() => caches.open('duty-links-v1').then(cache => cache.match('/__duty-pending-link')).then(r => !!r))).toBe(false);
  expect(await page.evaluate(() => (window as unknown as {sameWindow?: boolean}).sameWindow)).toBe(true);
});

test('#89 rule 3: a handled request or a moved duty opens the closest screen with a note', async ({page, openApp}) => {
  await openApp('a', page, {month: null});
  // The request was already answered: its day in the schedule.
  await tap(page, `/?tab=home&swap=${REQUEST}&month=${MONTH}&day=2026-11-03`);
  await expect(page.getByText('This swap request was already handled.', {exact: true})).toBeVisible();
  await expect(tab(page, 'Schedule')).toHaveAttribute('aria-selected', 'true');
  await expect(day(page, '2026-11-03')).toHaveClass(/flash-day/);
  // 3 November is Blair's now: the day opens, with a note that the duty changed.
  await tap(page, '/?tab=schedule&month=2026-11&duty=2026-11-03');
  await expect(page.getByText('This duty has changed. Here is the current schedule.', {exact: true})).toBeVisible();
  await expect(day(page, '2026-11-03')).toHaveClass(/flash-day/);
});

test('#89 rule 3: no one waiting for approval opens the Team tab with a note', async ({page, openApp, backend}) => {
  backend.raw.members.find(m => m.id === ids.pending)!.status = 'approved';
  await openApp('admin', page, {month: null});
  await tap(page, '/?tab=team&focus=approvals');
  await expect(tab(page, 'Team')).toHaveAttribute('aria-selected', 'true');
  await expect(page.getByText('No one is waiting for approval now.', {exact: true})).toBeVisible();
});

test('#89 a request made after the app loaded, the reverse of one just approved, opens instead of "already handled"', async ({page, openApp, backend}) => {
  // Blair and Alex swapped 3 ↔ 2 November; the app has that settled request.
  openRequest(backend);
  Object.assign(backend.raw.swapRequests![0], {status: 'approved', resolved_at: NOW, resolved_by: ids.admin});
  await openApp('a', page);
  await expect(page.locator('[data-settings-button]')).toBeVisible();
  // Then the reverse swap is asked: a new request the open app hasn't loaded yet.
  const REVERSE = '30000000-0000-4000-8000-0000000000bb';
  openRequest(backend, REVERSE);
  await page.evaluate(url => navigator.serviceWorker.dispatchEvent(new MessageEvent('message', {data: {type: 'duty-open', url}})),
    `/?tab=home&swap=${REVERSE}&month=${MONTH}&day=2026-11-03`);
  await expect(tab(page, 'Home')).toHaveAttribute('aria-selected', 'true');
  await expect(page.locator(`[data-swap-card="${REVERSE}"]`)).toBeInViewport();
  await expect(page.getByText('This swap request was already handled.', {exact: true})).toHaveCount(0);
  // Also on a cold open whose loaded copy predates the request.
  const LATER = '30000000-0000-4000-8000-0000000000cc';
  await page.reload();
  await expect(page.locator('[data-settings-button]')).toBeVisible();
  openRequest(backend, LATER);
  await page.evaluate(url => navigator.serviceWorker.dispatchEvent(new MessageEvent('message', {data: {type: 'duty-open', url}})),
    `/?tab=home&swap=${LATER}&month=${MONTH}&day=2026-11-03`);
  await expect(page.locator(`[data-swap-card="${LATER}"]`)).toBeInViewport();
  await expect(page.getByText('This swap request was already handled.', {exact: true})).toHaveCount(0);
});

test('#89 a member who signed up after the app loaded opens in the approvals list', async ({page, openApp, backend}) => {
  backend.raw.members.find(m => m.id === ids.pending)!.status = 'approved';
  await openApp('admin', page);
  await expect(page.locator('[data-settings-button]')).toBeVisible();
  backend.raw.members.find(m => m.id === ids.pending)!.status = 'pending';
  await page.evaluate(() => navigator.serviceWorker.dispatchEvent(new MessageEvent('message', {data: {type: 'duty-open', url: '/?tab=team&focus=approvals'}})));
  await expect(tab(page, 'Team')).toHaveAttribute('aria-selected', 'true');
  await expect(page.getByText('Pat Pending', {exact: true})).toBeVisible();
  await expect(page.getByText('No one is waiting for approval now.', {exact: true})).toHaveCount(0);
});

test('#89 rule 2: the app comes forward before the worker stashed the link, and still opens it', async ({page, openApp, backend}) => {
  openRequest(backend);
  await openApp('a', page);
  await expect(tab(page, 'Home')).toHaveAttribute('aria-selected', 'true');
  await page.evaluate(() => {(window as unknown as {sameWindow: boolean}).sameWindow = true;});
  const visibility = (state: 'hidden' | 'visible') => page.evaluate(state => {
    Object.defineProperty(document, 'visibilityState', {configurable: true, get: () => state});
    document.dispatchEvent(new Event('visibilitychange'));
  }, state);
  // The phone did not list the suspended window, so the worker could only stash the link; the
  // app is shown first and the stash lands a moment later.
  await visibility('hidden');
  await visibility('visible');
  await page.evaluate(() => new Promise(resolve => setTimeout(resolve, 600)));
  await page.evaluate(() => caches.open('duty-links-v1').then(cache => cache.put('/__duty-pending-link',
    new Response(JSON.stringify({url: '/?tab=schedule&month=2026-11&duty=2026-11-02', at: Date.now()})))));
  await expect(tab(page, 'Schedule')).toHaveAttribute('aria-selected', 'true');
  await expect(day(page, '2026-11-02')).toHaveClass(/flash-day/);
  expect(await page.evaluate(() => (window as unknown as {sameWindow?: boolean}).sameWindow)).toBe(true);
});

test('#89 a cold start on a link drops the stashed copy from the worker', async ({page, openApp}) => {
  await openApp('a', page, {month: null});
  await page.evaluate(() => caches.open('duty-links-v1').then(cache => cache.put('/__duty-pending-link',
    new Response(JSON.stringify({url: '/?tab=team&focus=approvals', at: Date.now()})))));
  await tap(page, '/?tab=schedule&month=2026-11&duty=2026-11-02');
  await expect(tab(page, 'Schedule')).toHaveAttribute('aria-selected', 'true');
  await expect.poll(() => page.evaluate(() => caches.open('duty-links-v1').then(cache => cache.match('/__duty-pending-link')).then(r => !!r))).toBe(false);
  await expect(tab(page, 'Schedule')).toHaveAttribute('aria-selected', 'true');
});

// Each recipient of a settled swap sees the day that is theirs now, even from a stale app.
for (const [who, theirs, gave] of [['a', '2026-11-03', '2026-11-02'], ['b', '2026-11-02', '2026-11-03']] as const) {
  test(`#89 after an approved swap, ${who} opens on the new duty date, not the one given away`, async ({page, openApp, backend}) => {
    await openApp(who, page);
    await expect(page.locator('[data-settings-button]')).toBeVisible();
    // Alex asked Blair: 2 ↔ 3 November. The admin approves while this app sits in the background.
    for (const row of backend.raw.assignments.filter(d => d.publication_id && ['2026-11-02', '2026-11-03'].includes(d.day)))
      row.primary_id = row.day === '2026-11-02' ? ids.b : ids.a;
    await page.evaluate(url => navigator.serviceWorker.dispatchEvent(new MessageEvent('message', {data: {type: 'duty-open', url}})),
      '/?tab=schedule&month=2026-11&day=2026-11-02&or=2026-11-03');
    await expect(tab(page, 'Schedule')).toHaveAttribute('aria-selected', 'true');
    await expect(day(page, theirs)).toHaveClass(/flash-day/);
    await expect(day(page, gave)).not.toHaveClass(/flash-day/);
  });
}

test('#89 rule 2 (iOS): a resumed app the phone did not list gets the broadcast link', async ({page, openApp}) => {
  await openApp('a', page);
  await expect(tab(page, 'Home')).toHaveAttribute('aria-selected', 'true');
  // No postMessage, no visibility events: only the worker's broadcast (public/sw.js).
  await page.evaluate(url => {const c = new BroadcastChannel('duty-links'); c.postMessage({type: 'duty-open', url}); c.close();}, '/?tab=schedule&month=2026-11&duty=2026-11-02');
  await expect(tab(page, 'Schedule')).toHaveAttribute('aria-selected', 'true');
  await expect(day(page, '2026-11-02')).toHaveClass(/flash-day/);
});

test('#89 rule 2 (iOS): a frozen app that resumes without visibility events takes the stashed link', async ({page, openApp}) => {
  await openApp('a', page);
  await expect(tab(page, 'Home')).toHaveAttribute('aria-selected', 'true');
  // Frozen for ~5 s (the main thread blocked), during which the worker stashed the link.
  await page.evaluate(async () => {
    await caches.open('duty-links-v1').then(cache => cache.put('/__duty-pending-link',
      new Response(JSON.stringify({url: '/?tab=schedule&month=2026-11&duty=2026-11-02', at: Date.now()}))));
    const end = performance.now() + 5000;
    while (performance.now() < end) { /* frozen */ }
  });
  await expect(tab(page, 'Schedule')).toHaveAttribute('aria-selected', 'true');
  await expect(day(page, '2026-11-02')).toHaveClass(/flash-day/);
});
