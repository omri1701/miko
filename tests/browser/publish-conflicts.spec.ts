import {test, expect, ids, switchLanguage, choose} from './fixtures';
import {shortDate} from '../../lib/date-format';

// #103 (owner 2026-11-21): one availability approval, no locks. Publish never shows the red
// "approve it with a reason" message: its popup lists who is on a date they marked unavailable,
// one per line, and "Publish anyway" approves exactly those. A newer conflict is refused and listed.
for (const lang of ['en', 'he'] as const) {
  const t = (en: string, he: string) => lang === 'en' ? en : he;
  test(`Publish lists unapproved conflicts; Publish anyway approves exactly them ${lang}`, async ({page, openApp, backend}) => {
    const name = (id: string) => backend.raw.members.find(m => m.id === id)!.name;
    const line = (member: string, day: string, note: string) => t(`${name(member)} marked ${shortDate(day, lang)} as unavailable`, `${name(member)} סימן/ה את ${shortDate(day, lang)} כלא זמין`) + (note ? ` · ${note}` : '');
    // Two weekday duties of two different members (not the admin viewing).
    const [first, second] = backend.raw.assignments.filter(d => d.publication_id === null && d.day >= '2026-11-09' && d.day.slice(0, 7) === '2026-11'
      && d.primary_id && ![ids.admin, ids.a].includes(d.primary_id) && !backend.raw.constraints.some(c => c.member_id === d.primary_id))
      .filter((d, i, all) => all.findIndex(o => o.primary_id === d.primary_id) === i);
    backend.raw.constraints.push({member_id: first.primary_id!, day: first.day, kind: 'no', note: 'Dentist'});
    backend.expectedRefusal = /^Availability conflict: \[/;
    await openApp('admin');
    if (lang === 'he') await switchLanguage(page, 'he');
    await page.getByRole('tab', {name: t('Schedule', 'לוח'), exact: true}).click();
    await page.getByRole('button', {name: t('Publish', 'פרסום'), exact: true}).click();
    const dialog = page.getByRole('dialog');
    await expect(dialog).toHaveAccessibleName(t('1 member is on a day they marked unavailable', 'חבר צוות אחד משובץ ביום שסימן כלא זמין'));
    await expect(dialog.getByRole('listitem')).toHaveText([line(first.primary_id!, first.day, 'Dentist')]);
    await expect(dialog.getByRole('button')).toContainText([t('Cancel', 'ביטול'), t('Publish anyway', 'לפרסם בכל זאת')]);
    // Another member marks a date after the popup opened: refused, and the popup lists both.
    backend.raw.constraints.push({member_id: second.primary_id!, day: second.day, kind: 'no', note: ''});
    await dialog.getByRole('button', {name: t('Publish anyway', 'לפרסם בכל זאת'), exact: true}).click();
    await expect(dialog).toHaveAccessibleName(t('2 members are on days they marked unavailable', '2 חברי צוות משובצים בימים שסימנו כלא זמינים'));
    await expect(dialog.getByRole('listitem')).toHaveText([line(first.primary_id!, first.day, 'Dentist'), line(second.primary_id!, second.day, '')]);
    await expect(page.locator('body')).not.toContainText(t('Someone is assigned', 'מישהו שובץ'));
    expect(backend.raw.months[0].status).toBe('draft');
    expect(backend.refusals).toHaveLength(1);
    await dialog.getByRole('button', {name: t('Publish anyway', 'לפרסם בכל זאת'), exact: true}).click();
    await expect(page.getByRole('dialog')).toBeHidden();
    await expect(page.getByRole('button', {name: t('Reopen', 'פתיחה לעריכה'), exact: true})).toBeVisible();
    const sent = backend.calls.filter(c => c.name === 'duty_save_schedule').at(-1)!.params.p_state as {publish_anyway?: unknown};
    expect(sent.publish_anyway).toEqual([{member: first.primary_id, day: first.day}, {member: second.primary_id, day: second.day}]);
    expect(backend.raw.constraints.filter(c => c.duty_approved).map(c => c.day)).toEqual([first.day, second.day]);
  });
}

// The duty editor's box approves for good: Publish then asks nothing.
test('an approval from the duty editor is never asked again at Publish', async ({page, openApp, backend}) => {
  const row = backend.raw.assignments.find(d => d.publication_id === null && d.day === '2026-11-10')!;
  const member = backend.raw.members.find(m => m.id !== row.primary_id && m.id !== row.secondary_id && m.id !== ids.admin && m.status === 'approved' && m.active
    && !backend.raw.constraints.some(c => c.member_id === m.id))!;
  backend.raw.constraints.push({member_id: member.id, day: row.day, kind: 'no', note: 'Errand'});
  await openApp('admin');
  await page.getByRole('tab', {name: 'Schedule', exact: true}).click();
  const cell = page.locator(`[data-gesture-key="${row.day}"]`).first();
  if (!await cell.evaluate(el => el.classList.contains('selected-day'))) await cell.click();
  const details = page.locator('[data-day-details] .day-duty');
  await expect(page.getByRole('dialog').or(details)).toBeVisible();
  if (await details.isVisible()) await details.click();
  await page.getByRole('dialog').getByRole('button', {name: 'Edit', exact: true}).click();
  const dialog = page.getByRole('dialog');
  await choose(dialog.getByRole('combobox', {name: 'Primary engineer', exact: true}), new RegExp(`^${member.name}`));
  await dialog.getByRole('checkbox', {name: 'Approve these exceptions as manager'}).click();
  await dialog.getByRole('button', {name: 'Save assignment', exact: true}).click();
  await expect(dialog).toBeHidden();
  const saved = backend.calls.filter(c => c.name === 'duty_save_schedule').at(-1)!.params.p_state as {approve_unavailable?: unknown};
  expect(saved.approve_unavailable).toEqual([{member: member.id, day: row.day}]);
  await page.getByRole('button', {name: 'Publish', exact: true}).click();
  await expect(page.getByRole('dialog', {name: 'Publish?'})).toBeVisible();
});
