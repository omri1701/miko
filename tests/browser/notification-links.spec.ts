// Issue #89: a tapped notification opens the screen it is about (links built by lib/push/messages.ts pushLink).
import type {Page} from '@playwright/test';
import {test, expect, ids, NOW, MONTH, type Backend} from './fixtures';

const REQUEST = '30000000-0000-4000-8000-0000000000aa';
const tab = (page: Page, name: string) => page.getByRole('tab', {name, exact: true});
const day = (page: Page, date: string) => page.locator(`button[data-date="${date}"]`).first();

// Blair asks Alex to swap 3 ↔ 2 November: the request waits for Alex.
function openRequest(backend: Backend) {
  const from = backend.raw.assignments.find(d => d.day === '2026-11-03' && d.publication_id)!, to = backend.raw.assignments.find(d => d.day === '2026-11-02' && d.publication_id)!;
  backend.raw.swapRequests!.unshift({id: REQUEST, month: MONTH, source_publication_id: from.publication_id!, requester_id: ids.b, other_id: ids.a, from_day: from.day, from_end_day: from.end_day,
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
  // public/sw.js focuses the open window and posts the link (unit-tested in tests/push.test.mjs).
  const post = (url: string) => page.evaluate(url => navigator.serviceWorker.dispatchEvent(new MessageEvent('message', {data: {type: 'duty-open', url}})), url);
  await post('/?tab=schedule&month=2026-11&duty=2026-11-02');
  await expect(tab(page, 'Schedule')).toHaveAttribute('aria-selected', 'true');
  await expect(day(page, '2026-11-02')).toHaveClass(/flash-day/);
  await post(`/?tab=home&swap=${REQUEST}&month=${MONTH}&day=2026-11-03`);
  await expect(tab(page, 'Home')).toHaveAttribute('aria-selected', 'true');
  await expect(page.locator(`[data-swap-card="${REQUEST}"]`)).toBeInViewport();
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
