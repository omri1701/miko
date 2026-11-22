import type {Page} from '@playwright/test';
import {test, expect, ids, switchLanguage, press, choose} from './fixtures';

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

test('#94 rule 1: a closed month (closed day cells) still swipes', async ({page, openApp, backend}, info) => {
  test.skip(info.project.name !== 'mobile', 'A finger swipe.');
  backend.raw.months[0].deadline = '2026-10-01';
  await openConstraints(page, openApp, false);
  await expect(page.locator('.month-pane:not(.month-peek) .availability-day[data-date="2026-11-10"]')).toHaveAttribute('aria-disabled', 'true');
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
  const note = day(page, '2026-11-04').locator('.availability-note');
  await expect(note).toHaveText('Synthetic vacation');
  expect(await note.evaluate(e => e.scrollHeight <= e.clientHeight + 1)).toBe(true);
});

// #95 rule 2 (a phone's separate read sheet) is replaced by #105 rule 5: one sheet, see
// constraints-redesign.spec.ts.

test('#95 rule 3: another engineer never sees someone else’s note', async ({page, openApp}) => {
  // Engineer B never receives A's note: no cell, label or sheet shows it.
  await openConstraints(page, openApp, false, 'b');
  await expect(page.getByLabel('Engineer')).toHaveCount(0);
  await expect(day(page, '2026-11-04')).not.toHaveClass(/\bno\b/);
  expect(await page.content()).not.toContain('Synthetic vacation');
  await day(page, '2026-11-04').click();
  await expect(page.getByRole('dialog').getByRole('textbox')).toHaveValue('');
});

test('#95 rule 3: an admin still reads an engineer’s note, as today', async ({page, openApp}) => {
  await openConstraints(page, openApp, false, 'admin');
  await choose(page.getByLabel('Engineer'), 'Alex Atlas');
  await expect(day(page, '2026-11-04')).toHaveClass(/\bno\b/);
  await day(page, '2026-11-04').click();
  await expect(page.getByRole('dialog').getByRole('textbox')).toHaveValue('Synthetic vacation');
});

type Box = {x: number; y: number; width: number; height: number};
const boxes = (page: Page, selector: string) => page.locator(selector).evaluateAll(els => els.map(e => {
  const r = e.getBoundingClientRect();
  return {date: (e as HTMLElement).dataset.date!, combined: e.classList.contains('combined-weekend'), box: {x: r.x, y: r.y, width: r.width, height: r.height}};
}));
const near = (a: Box, b: Box, label: string) => {for (const k of ['x', 'y', 'width', 'height'] as const) expect(Math.abs(a[k] - b[k]), `${label} ${k}`).toBeLessThanOrEqual(.5);};

for (const lang of ['en', 'he'] as const) for (const who of ['a', 'admin'] as const) test(`#95 rule 4: every day box sits exactly where Schedule draws it, ${who} ${lang}`, async ({page, openApp}) => {
  const he = lang === 'he';
  await openApp(who);
  if (he) await switchLanguage(page, 'he');
  await page.getByRole('tab', {name: he ? 'לוח' : 'Schedule', exact: true}).click();
  await expect(page.locator('.month-pane .calendar-grid').first()).toBeVisible();
  const schedule = await boxes(page, '.month-pane:not(.month-peek) .calendar-grid > button[data-date]');
  await page.getByRole('tab', {name: tabName(he), exact: true}).click();
  await expect(page.locator('.availability-grid')).toBeVisible();
  const constraints = new Map((await boxes(page, '.month-pane:not(.month-peek) .availability-grid > button[data-date]')).map(c => [c.date, c.box]));
  expect(schedule.length).toBeGreaterThan(20);
  for (const cell of schedule) {
    const own = constraints.get(cell.date)!;
    if (!cell.combined) {near(own, cell.box, cell.date); continue;}
    // A combined Friday–Saturday duty is one box over the two day boxes.
    const saturday = constraints.get(new Date(Date.parse(cell.date + 'T12:00:00Z') + 864e5).toISOString().slice(0, 10))!;
    const left = Math.min(own.x, saturday.x), right = Math.max(own.x + own.width, saturday.x + saturday.width);
    near({x: left, y: own.y, width: right - left, height: own.height}, cell.box, cell.date);
    expect(Math.abs(saturday.y - own.y)).toBeLessThanOrEqual(.5);
  }
});

test('#95 rule 5: the counts cover only the shown month and follow the month change', async ({page, openApp, backend}, info) => {
  backend.raw.months.push({month: '2026-12', deadline: '2026-11-24', status: 'draft', generated: false, current_publication_id: null, publication_sequence: 0});
  backend.raw.constraints.push(
    {member_id: ids.a, day: '2026-11-20', kind: 'prefer', note: ''},
    {member_id: ids.a, day: '2026-12-03', kind: 'no', note: ''}, {member_id: ids.a, day: '2026-12-15', kind: 'no', note: ''},
    {member_id: ids.a, day: '2026-11-30', kind: 'no', note: ''});
  await openConstraints(page, openApp, false);
  const summary = page.locator('.availability-summary');
  await expect(summary).toContainText('2 unavailable');
  await expect(summary).toContainText('1 preferred');
  await page.getByRole('button', {name: 'Next month', exact: true}).click();
  await expect(heading(page)).toHaveText('December 2026');
  // 30 November shows in December's first week but belongs to November.
  await expect(summary).toContainText('2 unavailable');
  await expect(summary).toContainText('0 preferred');
  if (info.project.name !== 'mobile') return;
  const grid = (await page.locator('.constraint-editor .month-stage').boundingBox())!;
  const g = await press(page, grid.x + grid.width / 2, grid.y + 30, true);
  await g.move(grid.width * .6);
  await g.end();
  await expect(heading(page)).toHaveText('November 2026');
  await expect(summary).toContainText('2 unavailable');
  await expect(summary).toContainText('1 preferred');
});

// #111: constraints only for this Israel month and the next two (October–December under NOW).
const monthButton = (page: Page, he: boolean, next: boolean) => page.getByRole('button', {name: next ? (he ? 'חודש הבא' : 'Next month') : (he ? 'חודש קודם' : 'Previous month'), exact: true}).last();
for (const lang of ['en', 'he'] as const) test(`#111 rules 1-2: everyone goes to any month; a member's month past the window is closed ${lang}`, async ({page, openApp}, info) => {
  const he = lang === 'he';
  await openConstraints(page, openApp, he);
  await monthButton(page, he, true).click();
  await expect(heading(page)).toHaveText(he ? 'דצמבר 2026' : 'December 2026');
  // Rule 1: December is open. Rule 2 (#105): Next still goes on, to a closed January.
  await expect(day(page, '2026-12-10')).toBeEnabled();
  await expect(monthButton(page, he, true)).toBeEnabled();
  if (info.project.name === 'mobile') {
    const toward = he ? 1 : -1;
    // The grid swipe goes to January, with January beside it while dragging.
    const grid = (await page.locator('.constraint-editor .month-stage').boundingBox())!;
    const g = await press(page, grid.x + grid.width / 2, grid.y + 30, true);
    await g.move(toward * grid.width * .3);
    await expect(page.locator('.constraint-editor .month-peek')).toHaveCount(1);
    await g.move(toward * grid.width * .7);
    await g.end();
    // A tap right after a swipe is taken for its ghost click (700 ms); a person taps later.
    await page.waitForTimeout(800);
  } else await monthButton(page, he, true).click();
  await expect(heading(page)).toHaveText(he ? 'ינואר 2027' : 'January 2027');
  await expect(page.locator('.availability-screen .month-status')).toHaveText(he ? 'סגור' : 'Closed');
  // January's own days are closed (the neighbour December days in its grid stay open, #105 rule 3).
  await expect(page.locator('.month-pane:not(.month-peek) .availability-day[data-gesture-key^="2027-01"]')).toHaveCount(0);
  await tapClosed(page, '2027-01-12', he ? 'ינואר עוד לא נפתח' : "January isn't open yet");
  // And on, by the month name too on a phone.
  if (info.project.name === 'mobile') {
    const name = (await page.locator('.availability-screen .month-heading').boundingBox())!;
    const g = await press(page, name.x + name.width / 2, name.y + name.height / 2, true);
    await g.move((he ? 1 : -1) * 160);
    await g.end();
    await expect(heading(page)).toHaveText(he ? 'פברואר 2027' : 'February 2027');
  }
});

/** A tap on a closed day: no editor, a short toast saying why (#111). */
async function tapClosed(page: Page, date: string, text: string) {
  // A closed day never joins a range selection, so it has no gesture key.
  const cell = page.locator(`.month-pane:not(.month-peek) .availability-day[data-date="${date}"]`);
  await expect(cell).toHaveAttribute('aria-disabled', 'true');
  await expect(cell).not.toHaveAttribute('data-gesture-key');
  // Playwright waits for aria-disabled to clear; a finger or mouse taps it at once.
  await cell.click({force: true});
  await expect(page.locator('[data-sonner-toast]').filter({hasText: text})).toBeVisible();
  await expect(page.getByRole('dialog')).toHaveCount(0);
}

for (const lang of ['en', 'he'] as const) test(`#111 rules 1 and 3: past months can be viewed but not edited; a month past the window neither ${lang}`, async ({page, openApp}) => {
  const he = lang === 'he';
  await openApp('a');
  if (he) await switchLanguage(page, 'he');
  await page.getByRole('tab', {name: he ? 'לוח' : 'Schedule', exact: true}).click();
  await page.getByRole('button', {name: he ? 'חודש הבא' : 'Next month', exact: true}).last().click();
  await page.getByRole('button', {name: he ? 'חודש הבא' : 'Next month', exact: true}).last().click();
  await expect(page.locator('.month-name:visible')).toHaveText(he ? 'ינואר 2027' : 'January 2027');
  // January, reached from Schedule, isn't open yet: read-only and Closed.
  await page.getByRole('tab', {name: tabName(he), exact: true}).click();
  await expect(heading(page)).toHaveText(he ? 'ינואר 2027' : 'January 2027');
  await expect(page.locator('.availability-screen .month-status')).toHaveText(he ? 'סגור' : 'Closed');
  await expect(monthButton(page, he, true)).toBeEnabled();
  await tapClosed(page, '2027-01-12', he ? 'ינואר עוד לא נפתח' : "January isn't open yet");
  // Back toward the window: December is open again.
  await monthButton(page, he, false).click();
  await expect(heading(page)).toHaveText(he ? 'דצמבר 2026' : 'December 2026');
  await expect(day(page, '2026-12-10')).toBeEnabled();
  await expect(day(page, '2026-12-10')).not.toHaveAttribute('aria-disabled', 'true');
  // Rule 3: earlier months can still be viewed (back past October, the current month), never edited.
  for (const label of he ? ['נובמבר 2026', 'אוקטובר 2026', 'ספטמבר 2026'] : ['November 2026', 'October 2026', 'September 2026']) {
    await monthButton(page, he, false).click();
    await expect(heading(page)).toHaveText(label);
  }
  await expect(page.locator('.availability-screen .month-status')).toHaveText(he ? 'סגור' : 'Closed');
  await tapClosed(page, '2026-09-15', he ? 'ספטמבר כבר נסגר' : 'September is closed');
});

for (const lang of ['en', 'he'] as const) test(`#111 rule 3: days of the current month that have passed can't be edited ${lang}`, async ({page, openApp}) => {
  // An admin, whose current month (October under NOW, the 9th) has no deadline.
  const he = lang === 'he';
  await openConstraints(page, openApp, he, 'admin');
  await monthButton(page, he, false).click();
  await expect(heading(page)).toHaveText(he ? 'אוקטובר 2026' : 'October 2026');
  await tapClosed(page, '2026-10-08', he ? 'היום הזה כבר עבר' : 'This day has passed');
  // Today and later still open the editor.
  await day(page, '2026-10-09').click();
  await expect(page.getByRole('dialog').getByRole('textbox')).toBeVisible();
});

for (const lang of ['en', 'he'] as const) test(`#111 rule 4: the database's refusal shows a translated message ${lang}`, async ({page, openApp}) => {
  const he = lang === 'he';
  await openConstraints(page, openApp, he);
  // As duty_private.set_constraints refuses a write past the window (a clock that moved on).
  await page.route('**/rest/v1/rpc/duty_set_constraints', route => route.fulfill({status: 403, json: {message: 'constraints-window-closed:2026-12', code: '42501'}}));
  await monthButton(page, he, true).click();
  await day(page, '2026-12-10').click();
  await page.getByRole('dialog').getByRole('button', {name: he ? 'שמירה' : 'Save', exact: true}).click();
  await expect(page.locator('[data-sonner-toast]').filter({hasText: he ? 'דצמבר עוד לא נפתח' : "December isn't open yet"})).toBeVisible();
});
