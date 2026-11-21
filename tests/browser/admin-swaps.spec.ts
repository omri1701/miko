// Admin-proposed swaps: both members accept, then an explicit admin approval.
import type {Browser, Page} from '@playwright/test';
import {test, expect, ids, duty, NOW, targetReady, switchLanguage, openDutySheet} from './fixtures';

// The duty sheet's Swap sets the source; Space on the target opens the request.
async function startSwap(page: Page, from: string) {
  await (await openDutySheet(page, from)).getByRole('button', {name: /^(Swap|החלפה)$/}).click();
  await expect(duty(page, from)).toHaveAttribute('aria-pressed', 'true');
}
async function pick(page: Page, from: string, to: string) {
  await startSwap(page, from);
  await targetReady(page, to); await duty(page, to).focus(); await page.keyboard.press('Space');
  await expect(page.getByRole('dialog')).toBeVisible();
}
async function language(page: Page, lang: 'en' | 'he') {
  await expect(page.locator('[data-settings-button]')).toBeVisible();
  if (lang === 'he') await switchLanguage(page, 'he');
}
async function published(page: Page, lang: 'en' | 'he') {
  await language(page, lang);
  await page.getByRole('tab', {name: lang === 'en' ? 'Schedule' : 'לוח', exact: true}).click();
  await page.getByRole('radio', {name: lang === 'en' ? 'Published' : 'פורסם', exact: true}).click();
}
async function home(page: Page) {
  await page.getByRole('tab', {name: /^(Home|בית)$/}).click();
}
async function contexts(browser: Browser, page: Page, count: number) {
  return Promise.all(Array.from({length: count}, () => browser.newContext({viewport: page.viewportSize()!, timezoneId: 'Asia/Jerusalem', locale: 'en-GB', serviceWorkers: 'block'})));
}

test('admin proposal needs both members, then an explicit approval with a copyable summary', async ({page, browser, openApp, backend}) => {
  await openApp('admin'); await published(page, 'en');
  // Headless Linux has no system clipboard; capture what the page copies instead.
  await page.addInitScript(() => Object.defineProperty(navigator, 'clipboard', {configurable: true,
    value: {writeText: async (text: string) => {(window as unknown as {copied: string}).copied = text;}}}));
  await pick(page, '2026-11-02', '2026-11-03');
  await expect(page.getByRole('dialog', {name: 'Propose swap'})).toContainText('Both engineers accept, then an admin approves.');
  await page.getByLabel('Explanation (optional)').fill('Synthetic coverage change');
  await page.getByRole('button', {name: 'Send to both', exact: true}).click();
  await expect(page.getByRole('dialog')).toBeHidden();
  await home(page);
  await expect(page.locator('[data-swap-card]').getByText('Your proposal', {exact: true})).toBeVisible();
  await expect(page.getByText('Waiting for: Alex Atlas, Blair Birch', {exact: true})).toBeVisible();
  expect(backend.raw.swapRequests![0]).toMatchObject({requester_id: ids.a, other_id: ids.b, proposed_by: ids.admin, status: 'awaiting_engineer'});
  const [ac, bc] = await contexts(browser, page, 2);
  try {
    const a = await ac.newPage(), b = await bc.newPage();
    await openApp('a', a); await openApp('b', b);
    await expect(a.getByText('Proposed by Avery Admin', {exact: true})).toBeVisible();
    await a.getByRole('button', {name: 'Accept', exact: true}).click();
    await expect(a.getByText('Accepted · waiting for the other engineer', {exact: true})).toBeVisible();
    await page.reload();
    await expect(page.getByText('Waiting for: Blair Birch', {exact: true})).toBeVisible();
    await expect(page.getByRole('button', {name: 'Approve', exact: true})).toHaveCount(0);
    await b.reload(); await b.getByRole('button', {name: 'Accept', exact: true}).click();
    await expect(b.getByText('Accepted · waiting for an admin', {exact: true})).toBeVisible();
    // Nothing changes until the final approval.
    expect(backend.raw.publications).toHaveLength(1);
    await page.reload(); await page.getByRole('button', {name: 'Approve', exact: true}).click();
    const dialog = page.getByRole('dialog', {name: 'Approve swap'});
    await expect(dialog).toContainText('Record it in the external system first');
    const summary = ['Duty swap: Alex Atlas ⇄ Blair Birch',
      'Alex Atlas — gives: 2 Nov (1 pt) · takes: 3 Nov (1 pt) · change: 0 pts',
      'Blair Birch — gives: 3 Nov (1 pt) · takes: 2 Nov (1 pt) · change: 0 pts'].join('\n');
    await expect(dialog.getByLabel('Swap summary')).toHaveText(summary);
    await dialog.getByRole('button', {name: 'Copy summary'}).click();
    await expect(page.getByText('Copied', {exact: true})).toBeVisible();
    expect(await page.evaluate(() => (window as unknown as {copied: string}).copied)).toBe(summary);
    await dialog.getByRole('button', {name: 'Approve & publish'}).click();
    await expect(dialog).toBeHidden();
    await expect(page.getByText('Swap approved and published', {exact: true})).toBeVisible();
    expect(backend.raw.swapRequests![0].status).toBe('approved');
    await page.reload(); await published(page, 'en');
    await expect(duty(page, '2026-11-02')).toHaveAccessibleName(/Blair Birch/);
    expect(backend.raw.publications.map(p => p.version)).toEqual([1, 2]);
  } finally {await ac.close(); await bc.close();}
});

test('admin as a party: only the other member is asked, and the admin still approves', async ({page, browser, openApp, backend}) => {
  await openApp('admin'); await published(page, 'en');
  // Choosing the other member's duty first still makes the admin's side the request.
  await pick(page, '2026-11-09', '2026-11-08');
  const dialog = page.getByRole('dialog', {name: 'Ask to swap'});
  await expect(dialog).toContainText('your duty');
  await dialog.getByRole('button', {name: 'Confirm Request', exact: true}).click();
  await expect(dialog).toBeHidden();
  expect(backend.raw.swapRequests![0]).toMatchObject({requester_id: ids.admin, other_id: ids.a, proposed_by: null, from_day: '2026-11-08'});
  await expect(page.getByRole('button', {name: 'Accept', exact: true})).toHaveCount(0);
  const [ac] = await contexts(browser, page, 1);
  try {
    const a = await ac.newPage(); await openApp('a', a);
    await a.getByRole('button', {name: 'Accept', exact: true}).click();
    await expect(a.getByText('Accepted · waiting for an admin', {exact: true})).toBeVisible();
    await page.reload();
    await expect(page.locator('[data-swap-card]').getByText('Waiting for an admin', {exact: true})).toBeVisible();
    expect(backend.raw.publications).toHaveLength(1);
    await page.getByRole('button', {name: 'Approve', exact: true}).click();
    await page.getByRole('button', {name: 'Approve & publish'}).click();
    await expect(page.getByText('Swap approved and published', {exact: true})).toBeVisible();
    expect(backend.raw.swapRequests![0].status).toBe('approved');
    await page.reload(); await published(page, 'en');
    await expect(duty(page, '2026-11-08')).toHaveAccessibleName(/Alex Atlas/);
  } finally {await ac.close();}
});

for (const lang of ['en', 'he'] as const) test(`a stale approval dialog shows the latest request and cannot approve it ${lang}`, async ({page, openApp, backend}) => {
  const t = (en: string, he: string) => lang === 'en' ? en : he;
  await openApp('admin'); await published(page, lang);
  await pick(page, '2026-11-02', '2026-11-03');
  await page.getByRole('button', {name: t('Send to both', 'שליחה לשניהם'), exact: true}).click();
  await expect(page.getByRole('dialog')).toBeHidden();
  Object.assign(backend.raw.swapRequests![0], {requester_accepted_at: NOW, accepted_by: ids.b, accepted_at: NOW, status: 'awaiting_admin'});
  backend.raw.revision!++;
  await page.reload(); await language(page, lang);
  await page.getByRole('button', {name: t('Approve', 'אישור'), exact: true}).click();
  const dialog = page.getByRole('dialog', {name: t('Approve swap', 'אישור החלפה')});
  await expect(dialog.getByLabel(t('Swap summary', 'סיכום ההחלפה'))).toContainText('Alex Atlas ⇄ Blair Birch');
  // Another tab's republish handed 3 November to Casey, who has not answered yet.
  Object.assign(backend.raw.swapRequests![0], {other_id: ids.c, accepted_by: null, accepted_at: null, requester_accepted_at: null, status: 'awaiting_engineer'});
  backend.raw.assignments.find(d => d.day === '2026-11-03' && d.publication_id === backend.raw.months[0].current_publication_id)!.primary_id = ids.c;
  backend.failNextSave = true;
  await dialog.getByRole('button', {name: t('Approve & publish', 'אישור ופרסום')}).click();
  await expect(dialog.getByRole('alert')).toContainText(t('This request changed and no longer needs this answer.', 'הבקשה השתנתה ואינה ממתינה עוד לתשובה זו.'));
  await expect(dialog.getByLabel(t('Swap summary', 'סיכום ההחלפה'))).toContainText('Alex Atlas ⇄ Casey Cedar');
  await expect(dialog.getByRole('button', {name: t('Approve & publish', 'אישור ופרסום')})).toBeDisabled();
  expect(backend.raw.publications).toHaveLength(1);
});

for (const lang of ['en', 'he'] as const) test(`availability alert names whose constraint blocks a swap ${lang}`, async ({page, openApp, backend}) => {
  const t = (en: string, he: string) => lang === 'en' ? en : he;
  await openApp('a'); await language(page, lang);
  // Alex would receive 4 November, which Alex marked unavailable: red before the pick, no note (#92).
  await startSwap(page, '2026-11-09');
  await targetReady(page, '2026-11-04');
  await expect(duty(page, '2026-11-04')).toHaveAttribute('title', t('You marked 4 Nov as unavailable · Synthetic vacation', 'סימנת את 4 בנוב׳ כלא זמין · Synthetic vacation'));
  await duty(page, '2026-11-04').focus(); await page.keyboard.press('Space');
  await expect(page.getByRole('dialog').getByRole('note')).toHaveText(t('You marked 4 Nov as unavailable · Synthetic vacation', 'סימנת את 4 בנוב׳ כלא זמין · Synthetic vacation'));
  await expect(page.getByRole('button', {name: t('Send anyway', 'לשלוח בכל זאת'), exact: true})).toBeEnabled();
  await page.keyboard.press('Escape');
  expect(backend.calls.filter(c => c.name === 'duty_request_swap')).toHaveLength(0);
  // Without a conflict the same dialog sends normally.
  await pick(page, '2026-11-02', '2026-11-03');
  await expect(page.getByRole('dialog').getByRole('alert')).toHaveCount(0);
  await expect(page.getByRole('button', {name: t('Confirm Request', 'אישור בקשה'), exact: true})).toBeEnabled();
});

// #92 (owner 2026-11-20): a member may accept a date they marked unavailable; the card says so
// (never the note), accepting keeps the constraint, and the admin approves as usual.
for (const lang of ['en', 'he'] as const) test(`a member accepts a date they marked unavailable; the admin approves as usual ${lang}`, async ({page, browser, openApp, backend}) => {
  const t = (en: string, he: string) => lang === 'en' ? en : he;
  await openApp('admin'); await published(page, lang);
  await pick(page, '2026-11-02', '2026-11-03');
  await expect(page.getByRole('dialog', {name: t('Propose swap', 'הצעת החלפה')})).toBeVisible();
  await page.getByRole('button', {name: t('Send to both', 'שליחה לשניהם'), exact: true}).click();
  await expect(page.getByRole('dialog')).toBeHidden();
  // Blair marks 2 November unavailable after the proposal was sent.
  backend.raw.constraints.push({member_id: ids.b, day: '2026-11-02', kind: 'no', note: 'Late private note'});
  backend.raw.revision!++;
  const [bc] = await contexts(browser, page, 1);
  try {
    const b = await bc.newPage(); await openApp('b', b); await language(b, lang);
    const card = b.locator('[data-swap-card]');
    // The owner reads their own constraint, note included.
    await expect(card.getByRole('note')).toHaveText(t('You marked 2 Nov as unavailable · Late private note', 'סימנת את 2 בנוב׳ כלא זמין · Late private note'));
    // Owner 2026-11-21: below the title row, the people row and conflict lines span the card
    // (not a column beside the icon), and the people row stays on one line.
    const [cardBox, pairBox, noteBox, iconBox] = await Promise.all([card, card.locator('.swap-card-pair'), card.getByRole('note'), card.locator('.swap-card-icon')]
      .map(l => l.boundingBox()));
    for (const box of [pairBox!, noteBox!]) {
      expect(box.y).toBeGreaterThanOrEqual(iconBox!.y + iconBox!.height - 1);
      expect(box.width).toBeGreaterThan(cardBox!.width - 40);
    }
    expect(await card.locator('.swap-party').evaluateAll(parts => new Set(parts.map(p => Math.round(p.getBoundingClientRect().top))).size)).toBe(1);
    await card.getByRole('button', {name: t('Accept', 'קבלה'), exact: true}).click();
    await expect(b.getByRole('dialog')).toHaveCount(0);
    await expect.poll(() => backend.raw.swapRequests![0].accepted_by).toBe(ids.b);
  } finally {await bc.close();}
  // Alex's side, accepted on the server to keep this test on the admin review.
  Object.assign(backend.raw.swapRequests![0], {requester_accepted_at: NOW, status: 'awaiting_admin'});
  backend.raw.revision!++;
  await page.reload(); await language(page, lang);
  await page.getByRole('button', {name: t('Approve', 'אישור'), exact: true}).click();
  const dialog = page.getByRole('dialog', {name: t('Approve swap', 'אישור החלפה')});
  await expect(dialog.getByLabel(t('Swap summary', 'סיכום ההחלפה'))).toContainText(t('Duty swap: Alex Atlas ⇄ Blair Birch', 'החלפת כוננויות: Alex Atlas ⇄ Blair Birch'));
  // Owner 2026-11-21: the admin sees the conflict with its note, no explanation, checkbox or reason.
  await expect(dialog.getByRole('alert').getByRole('listitem')).toHaveText(t('Blair Birch marked 2 Nov as unavailable · Late private note', 'Blair Birch סימן/ה את 2 בנוב׳ כלא זמין · Late private note'));
  await expect(dialog.getByRole('checkbox')).toHaveCount(0);
  await expect(dialog.getByRole('textbox')).toHaveCount(0);
  await expect(dialog).not.toContainText(t('reason', 'נימוק'));
  const approve = dialog.getByRole('button', {name: t('Approve anyway', 'לאשר בכל זאת'), exact: true});
  await expect(approve).toBeEnabled();
  await approve.click();
  await expect(dialog).toBeHidden();
  expect(backend.raw.swapRequests![0]).toMatchObject({status: 'approved', override_reason: ''});
  expect(backend.raw.constraints.some(c => c.member_id === ids.b && c.day === '2026-11-02')).toBe(true);
});

for (const lang of ['en', 'he'] as const) test(`an admin answers for temporary members, then approves separately ${lang}`, async ({page, openApp, backend}) => {
  // Decision 2026-11-01: temporary members have no account, so each open side goes to the admin.
  const t = (en: string, he: string) => lang === 'en' ? en : he;
  const tamar = '90000000-0000-0000-0000-000000000001', noa = '90000000-0000-0000-0000-000000000002';
  for (const [id, name] of [[tamar, 'Tamar Temp'], [noa, 'Noa Temp']]) backend.raw.members.push({id, name, email: null, is_temporary: true, role: 'engineer', status: 'approved', active: true, seniority: backend.raw.members.length, color: '#adc9ee'});
  const current = backend.raw.months[0].current_publication_id;
  for (const d of backend.raw.assignments.filter(d => d.publication_id === current)) {
    if (d.day === '2026-11-02') d.primary_id = tamar;
    if (d.day === '2026-11-03') d.primary_id = noa;
  }
  await openApp('admin'); await published(page, lang);
  await pick(page, '2026-11-02', '2026-11-03');
  await page.getByRole('button', {name: t('Send to both', 'שליחה לשניהם'), exact: true}).click();
  await expect(page.getByRole('dialog')).toBeHidden();
  await home(page);
  // The requester's side first, then the other's; each answer is recorded as that member's.
  await expect(page.getByText(t('Answer for Tamar Temp (temporary)', 'מענה עבור Tamar Temp (זמני)'), {exact: true})).toBeVisible();
  await page.getByRole('button', {name: t('Accept', 'קבלה'), exact: true}).click();
  await expect(page.getByText(t('Accepted · waiting for the other engineer', 'התקבל · ממתין למהנדס השני'), {exact: true})).toBeVisible();
  await expect(page.getByText(t('Answer for Noa Temp (temporary)', 'מענה עבור Noa Temp (זמני)'), {exact: true})).toBeVisible();
  await page.getByRole('button', {name: t('Accept', 'קבלה'), exact: true}).click();
  await expect(page.getByText(t('Accepted · waiting for an admin', 'התקבל · ממתין למנהל'), {exact: true})).toBeVisible();
  expect(backend.raw.swapRequests![0]).toMatchObject({requester_id: tamar, other_id: noa, status: 'awaiting_admin', accepted_by: noa, requester_accepted_at: NOW});
  // Answering never publishes: the explicit approval with its summary still follows.
  expect(backend.raw.publications).toHaveLength(1);
  await page.getByRole('button', {name: t('Approve', 'אישור'), exact: true}).click();
  const dialog = page.getByRole('dialog', {name: t('Approve swap', 'אישור החלפה')});
  await expect(dialog.getByLabel(t('Swap summary', 'סיכום ההחלפה'))).toContainText('Tamar Temp ⇄ Noa Temp');
  await dialog.getByRole('button', {name: t('Approve & publish', 'אישור ופרסום')}).click();
  await expect(dialog).toBeHidden();
  expect(backend.raw.publications).toHaveLength(2);
});
