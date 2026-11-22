import type {Page} from '@playwright/test';
import {test, expect, ids, switchLanguage, choose, touchEvent} from './fixtures';

// #105 Constraints redesign (approved mockup work/design/constraints-mockup.html). NOW is Fri 9 Oct
// 2026 (Israel), the app opens on November; a member's window is October–December.
const tabName = (he: boolean) => he ? 'אילוצים' : 'Availability';
const cell = (page: Page, date: string) => page.locator(`.month-pane:not(.month-peek) .availability-day[data-date="${date}"]`);
const notes = (page: Page) => page.locator('.month-pane:not(.month-peek) .availability-note');
const previous = (page: Page, he: boolean) => page.getByRole('button', {name: he ? 'חודש קודם' : 'Previous month', exact: true}).last();
const next = (page: Page, he: boolean) => page.getByRole('button', {name: he ? 'חודש הבא' : 'Next month', exact: true}).last();
async function open(page: Page, openApp: (who?: 'admin' | 'a') => Promise<unknown>, he: boolean, who: 'admin' | 'a' = 'a') {
  await openApp(who);
  if (he) await switchLanguage(page, 'he');
  await page.getByRole('tab', {name: tabName(he), exact: true}).click();
  await expect(page.locator('.availability-grid').first()).toBeVisible();
}
/** Every ancestor up to the grid, and the element itself, is fully opaque. */
const opaque = (page: Page, date: string) => cell(page, date).locator('.availability-note').evaluate(el => {
  for (let node: Element | null = el; node && !node.classList.contains('calendar-grid'); node = node.parentElement) if (getComputedStyle(node).opacity !== '1') return false;
  return true;
});

for (const lang of ['en', 'he'] as const) test(`#105 rule 1: the note is written in the day, readable, phone and PC type ${lang}`, async ({page, openApp}, info) => {
  const he = lang === 'he';
  await open(page, openApp, he);
  const note = cell(page, '2026-11-04').locator('.availability-note');
  await expect(note).toHaveText('Synthetic vacation');
  await expect(note).toBeVisible();
  // No dot-only notes, no dimmed text.
  await expect(page.locator('.mobile-note-dot')).toHaveCount(0);
  expect(await opaque(page, '2026-11-04')).toBe(true);
  const style = await note.evaluate(el => {const s = getComputedStyle(el); return {size: s.fontSize, weight: s.fontWeight, family: s.fontFamily, clamp: s.webkitLineClamp, align: s.textAlign, wrap: s.textWrap};});
  expect(style.align).toBe('center');
  if (info.project.name === 'mobile') expect(style).toMatchObject({size: '11px', clamp: '3'});
  else {
    expect(style).toMatchObject({size: '16px', weight: '600', clamp: '2'});
    expect(style.family).toMatch(/^"Segoe UI Variable Display", "SF Pro Display"/);
    expect(style.wrap).toContain('balance');
  }
});

for (const lang of ['en', 'he'] as const) test(`#105 rule 2: days in a row with the same kind and note are one block per week row; removing a middle day splits it ${lang}`, async ({page, openApp, backend}) => {
  const he = lang === 'he';
  const add = (days: string[], kind: 'no' | 'prefer', note: string) => backend.raw.constraints.push(...days.map(day => ({member_id: ids.a, day, kind, note})));
  // Tue 10 – Thu 12 Nov: one block. Fri 13 – Mon 16 crosses a week: one block per row, the note on
  // each. Tue 17 has another note: its own block. Wed 18 – Thu 19 prefer, no note: joined, no text.
  add(['2026-11-10', '2026-11-11', '2026-11-12'], 'no', 'Army reserve');
  add(['2026-11-13', '2026-11-14', '2026-11-15', '2026-11-16'], 'no', 'Abroad ');
  add(['2026-11-17'], 'no', 'Dentist');
  add(['2026-11-18', '2026-11-19'], 'prefer', '');
  await open(page, openApp, he);
  await expect(notes(page).filter({hasText: 'Army reserve'})).toHaveCount(1);
  await expect(cell(page, '2026-11-10').locator('.availability-note')).toHaveText('Army reserve');
  for (const d of ['2026-11-10', '2026-11-11']) await expect(cell(page, d)).toHaveClass(/joins-next/);
  await expect(cell(page, '2026-11-12')).not.toHaveClass(/joins-next/);
  // The note spans the block's three days, centred across them.
  const [label, first, last] = await Promise.all([cell(page, '2026-11-10').locator('.availability-note').boundingBox(), cell(page, '2026-11-10').boundingBox(), cell(page, '2026-11-12').boundingBox()]);
  const middle = (first!.x + first!.width / 2 + last!.x + last!.width / 2) / 2;
  expect(Math.abs(label!.x + label!.width / 2 - middle)).toBeLessThan(3);
  expect(label!.width).toBeGreaterThan(first!.width * 2.5);
  // Across the week edge: the note on each row; the trimmed note matches.
  await expect(notes(page).filter({hasText: 'Abroad'})).toHaveCount(2);
  await expect(cell(page, '2026-11-13').locator('.availability-note')).toHaveText('Abroad');
  await expect(cell(page, '2026-11-15').locator('.availability-note')).toHaveText('Abroad');
  await expect(cell(page, '2026-11-14')).not.toHaveClass(/joins-next/);
  await expect(cell(page, '2026-11-16')).not.toHaveClass(/joins-next/);
  // A different note is a different block; a noteless block joins without text.
  await expect(cell(page, '2026-11-17').locator('.availability-note')).toHaveText('Dentist');
  await expect(cell(page, '2026-11-18')).toHaveClass(/joins-next/);
  await expect(cell(page, '2026-11-18').locator('.availability-note')).toHaveCount(0);
  // Removing Wed 11 Nov changes that day only: two blocks, each with the note.
  await cell(page, '2026-11-11').click();
  const editor = page.getByRole('dialog');
  await editor.getByRole('button', {name: he ? 'הסרת אילוץ' : 'Remove constraint', exact: true}).click();
  await page.getByRole('alertdialog').getByRole('button', {name: he ? 'הסרת אילוצים והערות' : 'Remove constraints and notes', exact: true}).click();
  await expect(page.getByRole('dialog')).toHaveCount(0);
  expect(backend.calls.filter(c => c.name === 'duty_set_constraints').at(-1)!.params).toMatchObject({p_days: ['2026-11-11'], p_kind: 'clear'});
  await expect(notes(page).filter({hasText: 'Army reserve'})).toHaveCount(2);
  await expect(cell(page, '2026-11-10')).not.toHaveClass(/joins-next/);
  await expect(cell(page, '2026-11-12').locator('.availability-note')).toHaveText('Army reserve');
});

for (const lang of ['en', 'he'] as const) test(`#105 rule 3: the neighbour month's days show their colour and note, join blocks and work like other days ${lang}`, async ({page, openApp, backend}) => {
  const he = lang === 'he';
  backend.raw.constraints.push(...['2026-11-30', '2026-12-01'].map(day => ({member_id: ids.a, day, kind: 'no' as const, note: 'Trip'})));
  await open(page, openApp, he);
  // November's last row runs into December: 1 Dec is lighter but keeps its colour.
  const outside = cell(page, '2026-12-01');
  await expect(outside).toHaveClass(/outside/);
  await expect(outside).toHaveClass(/\bno\b/);
  expect(await outside.evaluate(el => getComputedStyle(el).opacity)).toBe('1');
  await expect(cell(page, '2026-11-30')).toHaveClass(/joins-next/);
  await expect(cell(page, '2026-11-30').locator('.availability-note')).toHaveText('Trip');
  const number = (d: string) => cell(page, d).locator('.day-number').evaluate(el => getComputedStyle(el).color);
  expect(await number('2026-12-01')).not.toBe(await number('2026-11-30'));
  // The count chips still count November only (4 Nov and 30 Nov).
  await expect(page.locator('.availability-summary')).toContainText(he ? '2 לא זמין' : '2 unavailable');
  // A neighbour day opens its editor like any other day.
  await outside.click();
  await expect(page.getByRole('dialog').getByRole('textbox')).toHaveValue('Trip');
  await page.keyboard.press('Escape');
  // On December's grid, 30 Nov shows the same block from the other side.
  await next(page, he).click();
  await expect(cell(page, '2026-11-30')).toHaveClass(/outside/);
  await expect(cell(page, '2026-11-30').locator('.availability-note')).toHaveText('Trip');
});

for (const lang of ['en', 'he'] as const) test(`#105 rules 4-5: passed days are darker and keep their colour and note; today has the circle; a passed day opens read-only ${lang}`, async ({page, openApp, backend}) => {
  const he = lang === 'he', long = 'Doctor: yearly check-up in Tel Aviv, away the whole day and back late in the evening.';
  backend.raw.constraints.push({member_id: ids.admin, day: '2026-10-05', kind: 'no', note: long});
  await open(page, openApp, he, 'admin');
  await previous(page, he).click();
  const passed = cell(page, '2026-10-05'), plain = cell(page, '2026-10-06');
  await expect(passed).toHaveClass(/past/);
  await expect(passed.locator('.availability-note')).toHaveText(long);
  expect(await opaque(page, '2026-10-05')).toBe(true);
  // Darker than an open day, gray number; the constraint keeps a dimmed colour of its own.
  const bg = (d: string) => cell(page, d).evaluate(el => getComputedStyle(el).backgroundColor);
  expect(await bg('2026-10-06')).not.toBe(await bg('2026-10-13'));
  expect(await bg('2026-10-05')).not.toBe(await bg('2026-10-06'));
  expect(await plain.locator('.day-number').evaluate(el => getComputedStyle(el).color)).not.toBe(await cell(page, '2026-10-13').locator('.day-number').evaluate(el => getComputedStyle(el).color));
  // Today: Schedule's circle. Fri/Sat columns: Schedule's weekend tint.
  await expect(cell(page, '2026-10-09').locator('.current-date')).toHaveText('9');
  await expect(cell(page, '2026-10-16')).toHaveClass(/weekend/);
  expect(await bg('2026-10-16')).not.toBe(await bg('2026-10-15'));
  // Rule 5: the passed day with a constraint opens the same sheet, read-only: the kind and the full note.
  await passed.click({force: true});
  const sheet = page.getByRole('dialog');
  await expect(sheet.locator('.constraint-state')).toHaveText(he ? 'לא זמין' : 'Unavailable');
  await expect(sheet.locator('.constraint-note-full')).toHaveText(long);
  await expect(sheet.getByRole('textbox')).toHaveCount(0);
  // No buttons but the sheet's own Close.
  await expect(sheet.getByRole('button')).toHaveCount(1);
  await page.keyboard.press('Escape');
  await expect(page.getByRole('dialog')).toHaveCount(0);
  // Without a constraint it keeps today's toast.
  await plain.click({force: true});
  await expect(page.locator('[data-sonner-toast]').filter({hasText: he ? 'היום הזה כבר עבר' : 'This day has passed'})).toBeVisible();
  await expect(page.getByRole('dialog')).toHaveCount(0);
});

for (const lang of ['en', 'he'] as const) test(`#105 rule 5: one sheet: a tap opens the editor with the whole note; a closed month's constraint opens read-only ${lang}`, async ({page, openApp, backend}) => {
  const he = lang === 'he', long = 'Family wedding abroad, flying out early on the morning and back late at night — please do not schedule me on this day at all, thanks';
  backend.raw.constraints.push({member_id: ids.a, day: '2026-11-12', kind: 'no', note: long}, {member_id: ids.a, day: '2026-10-20', kind: 'prefer', note: 'Happy to cover'});
  await open(page, openApp, he);
  await cell(page, '2026-11-12').click();
  const editor = page.getByRole('dialog');
  await expect(editor).toHaveCount(1);
  if (he) await expect(editor.getByRole('heading')).toContainText('12'); else await expect(editor.getByRole('heading')).toHaveText('Thu 12 Nov');
  const box = editor.getByRole('textbox');
  await expect(box).toHaveValue(long);
  // The field grows to show the whole note.
  expect(await box.evaluate(el => el.scrollHeight <= el.clientHeight + 2)).toBe(true);
  await expect(editor.getByRole('button', {name: he ? 'לא זמין' : 'Unavailable', exact: true})).toHaveAttribute('aria-pressed', 'true');
  await page.keyboard.press('Escape');
  // October: a member's deadline has passed, so its days are closed; a constraint opens read-only.
  await previous(page, he).click();
  await cell(page, '2026-10-20').click({force: true});
  const sheet = page.getByRole('dialog');
  await expect(sheet.locator('.constraint-state')).toHaveText(he ? 'מעדיף כוננות' : 'Prefer duty');
  await expect(sheet.locator('.constraint-note-full')).toHaveText('Happy to cover');
  await expect(sheet.getByRole('textbox')).toHaveCount(0);
});

for (const lang of ['en', 'he'] as const) test(`#105 rule 6: admins see Everyone; a day lists first names; tapping a person edits for them ${lang}`, async ({page, openApp, backend}, info) => {
  const he = lang === 'he', pc = info.project.name !== 'mobile';
  backend.raw.constraints.push(
    {member_id: ids.b, day: '2026-11-04', kind: 'prefer', note: ''},
    {member_id: ids.c, day: '2026-11-04', kind: 'no', note: 'Exam'},
    ...[ids.a, ids.b, ids.c, ids.d].map(member_id => ({member_id, day: '2026-11-18', kind: 'no' as const, note: ''})));
  await open(page, openApp, he, 'admin');
  const picker = page.locator('.availability-screen select');
  // The default stays the admin; Everyone is the first choice.
  await expect(picker.locator('option:checked')).toContainText('Avery Admin');
  await expect(picker.locator('option').first()).toHaveText(he ? 'כולם' : 'Everyone');
  await choose(picker, he ? 'כולם' : 'Everyone');
  await expect(page.locator('.availability-summary')).toHaveCount(0);
  const who = cell(page, '2026-11-04').locator('.availability-who');
  // Unavailable first (red), then prefer duty (green); PC adds the note.
  await expect(who).toHaveText(pc ? ['Alex · Synthetic vacation', 'Casey · Exam', 'Blair'] : ['Alex', 'Casey', 'Blair'], {useInnerText: true});
  await expect(who.nth(0)).toHaveClass(/\bno\b/);
  await expect(who.nth(2)).toHaveClass(/prefer/);
  // At most three lines: two names, then +N.
  await expect(cell(page, '2026-11-18').locator('.availability-who')).toHaveText(['Alex', 'Blair', '+2'], {useInnerText: true});
  // No range selection in Everyone.
  await expect(page.locator('.month-pane:not(.month-peek) .availability-day[data-gesture-key]')).toHaveCount(0);
  await cell(page, '2026-11-04').click();
  const sheet = page.getByRole('dialog');
  if (he) await expect(sheet.getByRole('heading').first()).toContainText('4'); else await expect(sheet.getByRole('heading').first()).toHaveText('Wed 4 Nov');
  await expect(sheet.locator('.everyone-group h3')).toHaveText(he ? ['לא זמין', 'מעדיף כוננות'] : ['Unavailable', 'Prefer duty']);
  await expect(sheet.locator('.everyone-group.no .everyone-person b')).toHaveText(['Alex Atlas', 'Casey Cedar']);
  await expect(sheet.locator('.everyone-group.no .everyone-person small')).toHaveText(['Synthetic vacation', 'Exam']);
  await expect(sheet.locator('.everyone-group.prefer .everyone-person b')).toHaveText(['Blair Birch']);
  await sheet.getByRole('button', {name: /Casey Cedar/}).click();
  // The picker switches to Casey and that day's editor opens.
  await expect(picker.locator('option:checked')).toHaveText('Casey Cedar');
  const editor = page.getByRole('dialog');
  await expect(editor.getByRole('textbox')).toHaveValue('Exam');
  await editor.getByRole('textbox').fill('Exam (moved)');
  await editor.getByRole('button', {name: he ? 'שמירה' : 'Save', exact: true}).click();
  await expect(page.getByRole('dialog')).toHaveCount(0);
  expect(backend.calls.filter(c => c.name === 'duty_set_constraints').at(-1)!.params).toMatchObject({p_member: ids.c, p_days: ['2026-11-04'], p_note: 'Exam (moved)'});
});

test('#105 rule 6: members never get Everyone or anyone else\'s constraints', async ({page, openApp, backend}) => {
  backend.raw.constraints.push({member_id: ids.b, day: '2026-11-05', kind: 'no', note: 'Private to Blair'});
  await open(page, openApp, false);
  await expect(page.locator('.availability-screen select')).toHaveCount(0);
  await expect(page.locator('.availability-who')).toHaveCount(0);
  await expect(page.getByText('Private to Blair')).toHaveCount(0);
});

for (const who of ['a', 'admin'] as const) for (const lang of ['en', 'he'] as const) test(`#105 months: Schedule → April → Constraints: closed for a member, editable for an admin (${who}) ${lang}`, async ({page, openApp, backend}) => {
  const he = lang === 'he';
  await openApp(who);
  if (he) await switchLanguage(page, 'he');
  await page.getByRole('tab', {name: he ? 'לוח' : 'Schedule', exact: true}).click();
  for (let i = 0; i < 5; i++) await next(page, he).click();
  await expect(page.locator('.month-name:visible')).toHaveText(he ? 'אפריל 2027' : 'April 2027');
  await page.getByRole('tab', {name: tabName(he), exact: true}).click();
  await expect(page.locator('.availability-screen .month-name')).toHaveText(he ? 'אפריל 2027' : 'April 2027');
  const april = cell(page, '2027-04-14');
  if (who === 'a') {
    // A member: closed, the existing toast, nothing to select; the database refuses too (access.sql).
    await expect(page.locator('.availability-screen .month-status')).toHaveText(he ? 'סגור' : 'Closed');
    await expect(april).toHaveAttribute('aria-disabled', 'true');
    await expect(page.locator('.month-pane:not(.month-peek) .availability-day[data-gesture-key^="2027-04"]')).toHaveCount(0);
    await april.click({force: true});
    await expect(page.locator('[data-sonner-toast]').filter({hasText: he ? 'אפריל עוד לא נפתח' : "April isn't open yet"})).toBeVisible();
    await expect(page.getByRole('dialog')).toHaveCount(0);
  } else {
    // An admin has no month limit: April opens the editor and saves.
    await expect(april).not.toHaveAttribute('aria-disabled', 'true');
    await april.click();
    const editor = page.getByRole('dialog');
    await editor.getByRole('textbox').fill('Conference');
    await editor.getByRole('button', {name: he ? 'שמירה' : 'Save', exact: true}).click();
    await expect(page.getByRole('dialog')).toHaveCount(0);
    expect(backend.calls.filter(c => c.name === 'duty_set_constraints').at(-1)!.params).toMatchObject({p_member: ids.admin, p_days: ['2027-04-14'], p_note: 'Conference'});
  }
});

for (const lang of ['en', 'he'] as const) test(`#105 selection: several days are one unbroken outline, across weeks, with no gaps at dividers or inside corners ${lang}`, async ({page, openApp}, info) => {
  const he = lang === 'he', mobile = info.project.name === 'mobile';
  await open(page, openApp, he);
  // Wed 11 → Wed 18 Nov: Wed–Sat of one week and Sun–Wed of the next, so the shape has inside
  // corners (under 11 Nov's end side, above 18 Nov's start side).
  const a = (await cell(page, '2026-11-11').boundingBox())!, b = (await cell(page, '2026-11-18').boundingBox())!;
  const from = {x: a.x + a.width / 2, y: a.y + a.height / 2}, to = {x: b.x + b.width / 2, y: b.y + b.height / 2};
  if (mobile) {await touchEvent(page, 'touchstart', from.x, from.y); await page.waitForTimeout(350); await touchEvent(page, 'touchmove', to.x, to.y);}
  else {await page.mouse.move(from.x, from.y); await page.mouse.down(); await page.waitForTimeout(350); await page.mouse.move(to.x, to.y, {steps: 8});}
  await expect(page.locator('.month-pane:not(.month-peek) .date-selected')).toHaveCount(8);
  await expect(page.locator('.month-pane:not(.month-peek) .selection-box')).toHaveCount(8);
  // Mid-drag, with nothing over the grid: read the screen's pixels in the page.
  const shot = (await page.screenshot({animations: 'disabled', scale: 'css'})).toString('base64');
  const gaps = await page.evaluate(async png => {
    const image = await createImageBitmap(await (await fetch(`data:image/png;base64,${png}`)).blob());
    const canvas = new OffscreenCanvas(image.width, image.height), ctx = canvas.getContext('2d')!;
    ctx.drawImage(image, 0, 0);
    const px = (x: number, y: number) => Array.from(ctx.getImageData(Math.floor(x), Math.floor(y), 1, 1).data.slice(0, 3));
    // rgb(…) or, for color-mix(), color(srgb 0–1 …).
    const rgb = (css: string) => css.match(/[\d.]+/g)!.slice(0, 3).map(Number).map(v => css.startsWith('color(') ? v * 255 : v);
    const far = (p: number[], q: number[]) => Math.hypot(p[0] - q[0], p[1] - q[1], p[2] - q[2]);
    const cells = [...document.querySelectorAll<HTMLElement>('.month-pane:not(.month-peek) .availability-grid .availability-day')];
    const line = rgb(getComputedStyle(document.querySelector('.selection-box')!).borderTopColor || getComputedStyle(document.querySelector('.selection-box')!).borderLeftColor);
    const missing: string[] = [];
    const check = (x: number, y: number, where: string, fill: number[]) => {const p = px(x, y); if (far(p, line) > far(p, fill)) missing.push(`${where} @${Math.round(x)},${Math.round(y)} ${p}`);};
    cells.forEach((el, i) => {
      if (!el.classList.contains('date-selected')) return;
      const on = (j: number) => !!cells[j]?.classList.contains('date-selected'), col = i % 7;
      // The cell's own border box, dividers included: the outline must cover its edges.
      const box = el.getBoundingClientRect(), fill = rgb(getComputedStyle(el).backgroundColor), d = el.dataset.date;
      const rtl = getComputedStyle(el).direction === 'rtl';
      const startSel = col > 0 && on(i - 1), endSel = col < 6 && on(i + 1);
      const leftSel = rtl ? endSel : startSel, rightSel = rtl ? startSel : endSel;
      const along = (from: number, to: number) => [from + .5, (from + to) / 2, to - .5];
      // Each outer side: at both ends (the divider pixels included) and the middle.
      if (!on(i - 7)) for (const x of along(box.left, box.right)) check(x, box.top + 1, `${d} top`, fill);
      if (!on(i + 7)) for (const x of along(box.left, box.right)) check(x, box.bottom - 1, `${d} bottom`, fill);
      if (!leftSel) for (const y of along(box.top, box.bottom)) check(box.left + 1, y, `${d} left`, fill);
      if (!rightSel) for (const y of along(box.top, box.bottom)) check(box.right - 1, y, `${d} right`, fill);
      // Inside corners: both neighbours selected, the diagonal not.
      const up = on(i - 7), down = on(i + 7);
      const diag = (dy: number, side: 'left' | 'right') => on(i + dy + ((side === 'left') !== rtl ? -1 : 1));
      if (up && leftSel && !diag(-7, 'left')) check(box.left + 1, box.top + 1, `${d} inside top-left`, fill);
      if (up && rightSel && !diag(-7, 'right')) check(box.right - 1, box.top + 1, `${d} inside top-right`, fill);
      if (down && leftSel && !diag(7, 'left')) check(box.left + 1, box.bottom - 1, `${d} inside bottom-left`, fill);
      if (down && rightSel && !diag(7, 'right')) check(box.right - 1, box.bottom - 1, `${d} inside bottom-right`, fill);
    });
    return missing;
  }, shot);
  expect(gaps).toEqual([]);
  // The outline doesn't move the grid while dragging.
  expect((await cell(page, '2026-11-11').boundingBox())!).toEqual(a);
  if (mobile) await touchEvent(page, 'touchend', to.x, to.y); else await page.mouse.up();
  await expect(page.getByRole('dialog')).toBeVisible();
  await expect(page.locator('.month-pane:not(.month-peek) .date-selected')).toHaveCount(8);
});

test('#105 rule 7a: hover shading only applies where a pointer hovers', async ({page, openApp}) => {
  await open(page, openApp, false);
  const bare = await page.evaluate(() => {
    const out: string[] = [];
    const walk = (rules: CSSRuleList, hover: boolean) => {for (const rule of Array.from(rules)) {
      if (rule instanceof CSSMediaRule) walk(rule.cssRules, hover || /hover\s*:\s*hover/.test(rule.conditionText));
      else if (rule instanceof CSSStyleRule && /(day-cell|availability)[^,{]*:hover/.test(rule.selectorText) && !hover) out.push(rule.selectorText);
    }};
    for (const sheet of Array.from(document.styleSheets)) {try {walk(sheet.cssRules, false);} catch {}}
    return out;
  });
  expect(bare).toEqual([]);
});

test.describe('with motion', () => {
  test.use({reducedMotion: 'no-preference'});
  /** Records, every frame for `ms`, how each listed day is drawn in the Constraints grids. */
  const watch = (page: Page, ms: number) => page.evaluate(ms => {
    const w = window as unknown as {seen: {past: boolean[]; colours: string[]}};
    w.seen = {past: [], colours: []};
    const start = performance.now();
    const step = () => {
      for (const el of document.querySelectorAll('.constraint-editor .availability-grid [data-date="2026-10-05"]')) w.seen.past.push(el.classList.contains('past'));
      for (const el of document.querySelectorAll('.constraint-editor .availability-grid [data-date="2026-11-30"]')) w.seen.colours.push(getComputedStyle(el).backgroundColor);
      if (performance.now() - start < ms) requestAnimationFrame(step);
    };
    requestAnimationFrame(step);
  }, ms);
  const seen = (page: Page) => page.evaluate(() => (window as unknown as {seen: {past: boolean[]; colours: string[]}}).seen);
  for (const lang of ['en', 'he'] as const) test(`#105 rule 7b-c: nothing flickers on a month switch: passed days arrive passed, shared days keep their colour ${lang}`, async ({page, openApp, backend}) => {
    const he = lang === 'he';
    backend.raw.constraints.push({member_id: ids.admin, day: '2026-10-05', kind: 'no', note: 'Errand'}, ...['2026-11-30', '2026-12-01'].map(day => ({member_id: ids.admin, day, kind: 'no' as const, note: 'Away'})));
    await open(page, openApp, he, 'admin');
    // Back to October: 5 Oct is drawn passed in every frame, while it slides in and after.
    await watch(page, 1500);
    await previous(page, he).click();
    await page.waitForTimeout(1600);
    const back = await seen(page);
    expect(back.past.length).toBeGreaterThan(0);
    expect(back.past.every(Boolean)).toBe(true);
    // November to December: 30 Nov is in both grids and never changes colour.
    await next(page, he).click();
    await expect(page.locator('.availability-screen .month-name')).toHaveText(he ? 'נובמבר 2026' : 'November 2026');
    await watch(page, 1500);
    await next(page, he).click();
    await page.waitForTimeout(1600);
    const forward = await seen(page);
    expect(forward.colours.length).toBeGreaterThan(0);
    expect(new Set(forward.colours).size).toBe(1);
  });
});
