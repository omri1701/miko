import type {Page} from '@playwright/test';
import {test, expect, ids, switchLanguage, press} from './fixtures';

// #94 (swipe between months) and #95 (bigger on PC, read a day's note on a phone) on Constraints.
const heading = (page: Page) => page.locator('.availability-screen .month-name');
const tabName = (he: boolean) => he ? 'אילוצים' : 'Availability';
const day = (page: Page, date: string) => page.locator(`.month-pane:not(.month-peek) .availability-day[data-gesture-key="${date}"]`);
async function openConstraints(page: Page, openApp: (who?: 'admin' | 'a' | 'b') => Promise<unknown>, he: boolean, who: 'admin' | 'a' | 'b' = 'a') {
  await openApp(who);
  if (he) await switchLanguage(page, 'he');
  await page.getByRole('tab', {name: tabName(he), exact: true}).click();
  await expect(page.locator('.availability-grid')).toBeVisible();
}

for (const lang of ['en', 'he'] as const) test(`#94 rules 1-2: a sideways swipe on the grid slides in the next or previous month, mirrored in Hebrew ${lang}`, async ({page, openApp}, info) => {
  test.skip(info.project.name !== 'mobile', 'A finger swipe; PC keeps the month buttons (rule 4).');
  const he = lang === 'he';
  await openConstraints(page, openApp, he);
  const grid = (await page.locator('.constraint-editor .month-stage').boundingBox())!;
  const x = grid.x + grid.width / 2, y = grid.y + 30;
  // The next month comes from the reading end: drag left in English, right in Hebrew.
  const toward = he ? 1 : -1;
  let g = await press(page, x, y, true);
  await g.move(toward * grid.width * .3);
  // Rule 1: the neighbour month slides in with the finger (the same grid, read-only).
  const peek = page.locator('.constraint-editor .month-peek');
  await expect(peek).toHaveCount(1);
  await expect(peek.locator('.availability-day[data-date="2026-12-01"]')).toBeVisible();
  await g.move(toward * grid.width * .6);
  await g.end();
  await expect(heading(page)).toHaveText(he ? 'דצמבר 2026' : 'December 2026');
  await expect(peek).toHaveCount(0);
  // The swipe is not a tap: no editor opens.
  await expect(page.getByRole('dialog')).toHaveCount(0);
  // Rule 2: the opposite direction goes back.
  g = await press(page, x, y, true);
  await g.move(-toward * grid.width * .6);
  await g.end();
  await expect(heading(page)).toHaveText(he ? 'נובמבר 2026' : 'November 2026');
});

test('#94 rule 1: a closed month (disabled day cells) still swipes', async ({page, openApp, backend}, info) => {
  test.skip(info.project.name !== 'mobile', 'A finger swipe.');
  backend.raw.months[0].deadline = '2026-10-01';
  await openConstraints(page, openApp, false);
  await expect(day(page, '2026-11-10')).toBeDisabled();
  const grid = (await page.locator('.constraint-editor .month-stage').boundingBox())!;
  const g = await press(page, grid.x + grid.width / 2, grid.y + 30, true);
  await g.move(-grid.width * .6);
  await g.end();
  await expect(heading(page)).toHaveText('December 2026');
});

test('#94 rule 3: a vertical drag on the grid scrolls and never changes the month', async ({page, openApp}, info) => {
  test.skip(info.project.name !== 'mobile', 'Touch scrolling.');
  await page.setViewportSize({width: 390, height: 560});
  await openConstraints(page, openApp, false);
  const grid = (await page.locator('.constraint-editor .month-stage').boundingBox())!;
  const x = grid.x + grid.width / 2, y = grid.y + grid.height - 20;
  const cdp = await page.context().newCDPSession(page);
  await cdp.send('Input.dispatchTouchEvent', {type: 'touchStart', touchPoints: [{x, y}]});
  // Mostly vertical, with a little sideways drift, as a thumb scrolls.
  for (let step = 1; step <= 8; step++) await cdp.send('Input.dispatchTouchEvent', {type: 'touchMove', touchPoints: [{x: x - step * 3, y: y - step * 25}]});
  await expect(page.locator('.month-peek')).toHaveCount(0);
  await cdp.send('Input.dispatchTouchEvent', {type: 'touchEnd', touchPoints: []});
  await cdp.detach();
  await expect(heading(page)).toHaveText('November 2026');
  await expect(page.locator('.month-peek')).toHaveCount(0);
  await expect(page.getByRole('dialog')).toHaveCount(0);
});

for (const lang of ['en', 'he'] as const) test(`#94 rule 4: the month buttons still work, by click and by keyboard ${lang}`, async ({page, openApp}) => {
  const he = lang === 'he';
  await openConstraints(page, openApp, he);
  const next = page.getByRole('button', {name: he ? 'חודש הבא' : 'Next month', exact: true}), prev = page.getByRole('button', {name: he ? 'חודש קודם' : 'Previous month', exact: true});
  await next.click();
  await expect(heading(page)).toHaveText(he ? 'דצמבר 2026' : 'December 2026');
  await expect(day(page, '2026-12-01')).toBeVisible();
  await prev.focus();
  await page.keyboard.press('Enter');
  await expect(heading(page)).toHaveText(he ? 'נובמבר 2026' : 'November 2026');
  await expect(day(page, '2026-11-04')).toHaveClass(/\bno\b/);
  // The grid's own keyboard use is unchanged: Enter on a day opens its editor.
  await day(page, '2026-11-10').focus();
  await page.keyboard.press('Enter');
  await expect(page.getByRole('dialog')).toBeVisible();
});

test('#95 rule 1: on PC the grid uses the available width and height, with readable notes', async ({page, openApp}, info) => {
  test.skip(info.project.name !== 'desktop', 'PC layout.');
  await openConstraints(page, openApp, false);
  const main = (await page.locator('.main-wrap').boundingBox())!, screen = (await page.locator('.availability-screen').boundingBox())!;
  // The old 900px cap is gone: the screen spans the content column (its padding aside).
  expect(screen.width).toBeGreaterThan(main.width - 100);
  expect(screen.width).toBeGreaterThan(1000);
  const cell = (await day(page, '2026-11-04').boundingBox())!;
  expect(cell.height).toBeGreaterThanOrEqual(96);
  expect(cell.width).toBeGreaterThan(130);
  // The six weeks fill the window without pushing the grid past it.
  const grid = (await page.locator('.availability-grid').first().boundingBox())!;
  expect(grid.y + grid.height).toBeLessThanOrEqual(1000);
  const note = day(page, '2026-11-04').locator('.availability-description');
  await expect(note).toHaveText('Synthetic vacation');
  expect(await note.evaluate(e => e.scrollHeight <= e.clientHeight + 1)).toBe(true);
});

for (const lang of ['en', 'he'] as const) test(`#95 rule 2: on a phone, tapping an unavailable day with a note shows the whole note with Edit ${lang}`, async ({page, openApp, backend}, info) => {
  test.skip(info.project.name !== 'mobile', 'Phones cut the note to a dot.');
  const he = lang === 'he', long = 'Family wedding abroad, flying out early on the morning and back late at night — please do not schedule me';
  backend.raw.constraints.push({member_id: ids.a, day: '2026-11-12', kind: 'no', note: long}, {member_id: ids.a, day: '2026-11-13', kind: 'prefer', note: 'Happy to cover'});
  await openConstraints(page, openApp, he);
  await day(page, '2026-11-12').tap();
  const sheet = page.getByRole('dialog').filter({has: page.locator('.constraint-note-full')});
  await expect(sheet).toBeVisible();
  await expect(sheet.getByRole('heading')).toContainText('12');
  await expect(sheet.locator('.constraint-note-full')).toHaveText(long);
  // Read only: no availability choice until Edit.
  await expect(sheet.getByRole('button', {name: he ? 'לא זמין' : 'Unavailable', exact: true})).toHaveCount(0);
  await sheet.getByRole('button', {name: he ? 'עריכה' : 'Edit', exact: true}).click();
  await expect(sheet).toHaveCount(0);
  const editor = page.getByRole('dialog');
  await expect(editor.getByRole('heading')).toContainText('12');
  await expect(editor.getByRole('textbox')).toHaveValue(long);
  await expect(editor.getByRole('button', {name: he ? 'לא זמין' : 'Unavailable', exact: true})).toHaveAttribute('aria-pressed', 'true');
  await page.keyboard.press('Escape');
  await expect(page.getByRole('dialog')).toHaveCount(0);
  // Days without a note, and preferred days, still open the editor straight away.
  for (const date of ['2026-11-10', '2026-11-13']) {
    await day(page, date).tap();
    await expect(page.getByRole('dialog').getByRole('textbox')).toBeVisible();
    await page.keyboard.press('Escape');
    await expect(page.getByRole('dialog')).toHaveCount(0);
  }
});

test('#95 rule 3: another engineer never sees someone else’s note', async ({page, openApp}) => {
  // Engineer B never receives A's note: no cell, label or sheet shows it.
  await openConstraints(page, openApp, false, 'b');
  await expect(page.getByLabel('Engineer')).toHaveCount(0);
  await expect(day(page, '2026-11-04')).not.toHaveClass(/\bno\b/);
  expect(await page.content()).not.toContain('Synthetic vacation');
  await day(page, '2026-11-04').click();
  await expect(page.getByRole('dialog').getByRole('textbox')).toHaveValue('');
});

test('#95 rule 3: an admin still reads an engineer’s note, as today', async ({page, openApp}, info) => {
  await openConstraints(page, openApp, false, 'admin');
  await page.getByLabel('Engineer').click();
  await page.getByRole('option', {name: 'Alex Atlas', exact: true}).click();
  await expect(day(page, '2026-11-04')).toHaveClass(/\bno\b/);
  await day(page, '2026-11-04').click();
  if (info.project.name === 'mobile') await expect(page.getByRole('dialog').locator('.constraint-note-full')).toHaveText('Synthetic vacation');
  else await expect(page.getByRole('dialog').getByRole('textbox')).toHaveValue('Synthetic vacation');
});
