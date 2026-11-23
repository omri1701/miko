import type {Page} from '@playwright/test';
import {test, expect, ids, duty, switchLanguage, type Backend} from './fixtures';

// #110: a draft names each availability conflict ("Avi marked 22 Dec as unavailable · doctor") instead of a count; a tap selects
// the day, and the conflicting days are red. No explanation text is added.
const lines = (page: Page) => page.locator('[data-conflicts] .conflict-line');
/** Alex (unavailable on 4 Nov, "Synthetic vacation") and Blair (unavailable on 25 Nov, no note) are on those days in the draft. */
function conflicts(backend: Backend) {
  for (const row of backend.raw.assignments.filter(r => r.publication_id === null)) {
    if (row.day === '2026-11-04') row.primary_id = ids.a;
    if (row.day === '2026-11-25') row.primary_id = ids.b;
  }
  backend.raw.constraints.push({member_id: ids.b, day: '2026-11-25', kind: 'no', note: ''});
}
async function openSchedule(page: Page, he: boolean) {
  if (he) await switchLanguage(page, 'he');
  await page.getByRole('tab', {name: he ? 'לוח' : 'Schedule', exact: true}).click();
  await expect(page.locator('.calendar-grid')).toBeVisible();
}

for (const lang of ['en', 'he'] as const) test(`#110 rules 1-4: each conflict is a line (who marked which day, and the note); a tap selects its day; the days are red ${lang}`, async ({page, backend, openApp}, info) => {
  const he = lang === 'he';
  conflicts(backend);
  await openApp();
  await openSchedule(page, he);
  // Rule 1: one line per conflict in date order, the note when there is one; no count line.
  await expect(lines(page)).toHaveCount(2);
  await expect(lines(page).nth(0)).toHaveText(he ? 'Alex סימן/ה את 4 בנוב׳ כלא זמין · Synthetic vacation' : 'Alex marked 4 Nov as unavailable · Synthetic vacation');
  await expect(lines(page).nth(1)).toHaveText(he ? 'Blair סימן/ה את 25 בנוב׳ כלא זמין' : 'Blair marked 25 Nov as unavailable');
  await expect(page.getByText(/conflict with availability|מתנגשות עם אילוצים/)).toHaveCount(0);
  // Rule 3: only the conflicting days are red.
  await expect(page.locator('.month-pane:not(.month-peek) .day-cell.conflict-day')).toHaveCount(2);
  await expect(duty(page, '2026-11-04')).toHaveClass(/\bconflict-day\b/);
  await expect(duty(page, '2026-11-25')).toHaveClass(/\bconflict-day\b/);
  await expect(duty(page, '2026-11-05')).not.toHaveClass(/\bconflict-day\b/);
  // Rule 2: a tap jumps to the day and selects it (the phone shows that day's details).
  await lines(page).nth(1).click();
  await expect(duty(page, '2026-11-25')).toHaveClass(/\bselected-day\b/);
  await expect(duty(page, '2026-11-25')).toBeFocused();
  await expect(duty(page, '2026-11-25')).toBeInViewport();
  if (info.project.name === 'mobile') await expect(page.locator('[data-day-details]')).toContainText('Blair');
  else await expect(page.getByRole('dialog')).toHaveCount(0);
  // Since #103 (owner 2026-11-21) availability never blocks Publish: its popup lists these conflicts.
});

test('#110 rule 3: an approved exception leaves no line and no red day', async ({page, backend, openApp}) => {
  conflicts(backend);
  // One approval per person and date (#103).
  backend.raw.constraints.find(c => c.member_id === ids.b && c.day === '2026-11-25')!.duty_approved = true;
  await openApp();
  await openSchedule(page, false);
  await expect(lines(page)).toHaveCount(1);
  await expect(duty(page, '2026-11-25')).not.toHaveClass(/\bconflict-day\b/);
});

test('#110: members never see the conflict lines or red days', async ({page, backend, openApp}) => {
  conflicts(backend);
  await openApp('a');
  await openSchedule(page, false);
  await expect(page.locator('[data-conflicts]')).toHaveCount(0);
  await expect(page.locator('.day-cell.conflict-day')).toHaveCount(0);
});
