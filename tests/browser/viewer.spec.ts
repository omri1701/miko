import {test, expect, ids, switchLanguage} from './fixtures';
import type {Page} from '@playwright/test';
import {PROJECTS} from '../../lib/supabase/environment';
import {existsSync} from 'node:fs';

// Viewer members (#90, decisions 2026-11-20). The database refuses every Viewer write
// (supabase/tests/viewer.sql); the app hides the edit actions instead of disabling them.
test.beforeEach(({backend}) => {backend.url = PROJECTS.prod; backend.runtimeOrigin = 'https://miko-prod.vercel.app';});

async function snapshot(page: Page, name: string) {
  test.info().annotations.push({type: 'visual-review', description: JSON.stringify({name: name + '.png', viewport: page.viewportSize(), language: await page.locator('html').getAttribute('lang')})});
  await page.evaluate(() => document.fonts.ready);
  await page.mouse.move(0, 0);
  if (!existsSync(test.info().snapshotPath(name + '.png'))) {
    const path = test.info().outputPath(name + '-actual.png');
    await page.screenshot({path, fullPage: true, animations: 'disabled', caret: 'hide'});
    await test.info().attach(name + '-actual.png', {path, contentType: 'image/png'});
  }
  await expect.soft(page).toHaveScreenshot(name + '.png', {fullPage: true});
}
const tab = (page: Page, en: string, he: string, lang: 'en' | 'he') => page.getByRole('tab', {name: lang === 'en' ? en : he, exact: true}).click();

for (const lang of ['en', 'he'] as const) {
  const t = (en: string, he: string) => lang === 'en' ? en : he;

  test(`admin makes a member a Viewer in Team ${lang}`, async ({page, openApp, backend}) => {
    await openApp();
    if (lang === 'he') await switchLanguage(page, 'he');
    await tab(page, 'Team', 'צוות', lang);
    const row = page.locator(`.team-row[data-member="${ids.e}"]`), dialog = page.getByRole('dialog');
    await row.locator('.team-row-inner').click();
    const name = backend.raw.members.find(m => m.id === ids.e)!.name;
    const toggle = dialog.getByRole('switch', {name: `${t('Viewer', 'צופה')} ${name}`, exact: true});
    await expect(toggle).not.toBeChecked();
    // The explanation lives only in the confirm popup; Cancel changes nothing.
    await expect(dialog.first()).not.toContainText(t('Never scheduled', 'לא משובץ'));
    const confirm = page.getByRole('alertdialog');
    await toggle.click();
    await expect(confirm).toContainText(t(`Make ${name} a Viewer?`, `להפוך את ${name} לצופה?`));
    await expect(confirm).toContainText(t('Never scheduled, no constraints or points; current duties stay.', 'לא משובץ, בלי אילוצים ונקודות; הכוננויות הנוכחיות נשארות.'));
    await snapshot(page, `viewer-confirm-${lang}`);
    await confirm.getByRole('button', {name: t('Cancel', 'ביטול'), exact: true}).click();
    await expect(confirm).toHaveCount(0);
    await expect(toggle).not.toBeChecked();
    expect(backend.calls.filter(c => c.name === 'duty_set_viewer')).toEqual([]);
    await toggle.click();
    await confirm.getByRole('button', {name: t('Make viewer', 'הפיכה לצופה'), exact: true}).click();
    await expect(confirm).toHaveCount(0);
    await expect(toggle).toBeChecked();
    await expect(row.locator('.team-name')).toContainText(t('Viewer', 'צופה'));
    expect(backend.calls.filter(c => c.name === 'duty_set_viewer').map(c => c.params)).toEqual([expect.objectContaining({p_member: ids.e, p_viewer: true})]);
    await snapshot(page, `member-sheet-viewer-${lang}`);
    // Turning it off needs no confirmation.
    await toggle.click();
    await expect(toggle).not.toBeChecked();
    expect(backend.calls.filter(c => c.name === 'duty_set_viewer').map(c => c.params.p_viewer)).toEqual([true, false]);
  });

  test(`a Viewer sees the schedule with no edit actions ${lang}`, async ({page, openApp, backend}) => {
    backend.raw.months[0].status = 'published';
    backend.raw.members.find(m => m.id === ids.b)!.viewer = true;
    await openApp('b');
    if (lang === 'he') await switchLanguage(page, 'he');
    // Home: no constraints prompt and no swap request.
    await expect(page.locator('.home')).toBeVisible();
    await expect(page.getByRole('button', {name: t('Ask to swap', 'בקשת החלפה')})).toHaveCount(0);
    await expect(page.getByText(t('Enter now', 'להזין'))).toHaveCount(0);
    // Availability: a note instead of the editor.
    await tab(page, 'Availability', 'אילוצים', lang);
    await expect(page.getByRole('note').filter({hasText: t('Viewers don’t add constraints.', 'צופים לא מוסיפים אילוצים.')})).toBeVisible();
    await expect(page.locator('.availability-summary')).toHaveCount(0);
    await snapshot(page, `viewer-availability-${lang}`);
    // Schedule: the published calendar, no month actions.
    await tab(page, 'Schedule', 'לוח', lang);
    await expect(page.locator('.calendar-grid')).toBeVisible();
    await expect(page.locator('.month-primary')).toHaveCount(0);
    await expect(page.getByRole('button', {name: /^(Month actions|פעולות לחודש)$/})).toHaveCount(0);
    // Settings: no notifications (only Viewer-admins are notified); their own name stays editable.
    await page.getByRole('button', {name: t('Settings', 'הגדרות'), exact: true}).click();
    await expect(page.locator('#settings-notifications-title')).toHaveCount(0);
    await expect(page.getByPlaceholder(t('Your name', 'השם שלך'))).toBeEnabled();
  });

  test(`a Viewer-admin reads like an admin but edits nothing ${lang}`, async ({page, openApp, backend}) => {
    backend.raw.members.find(m => m.id === ids.admin)!.viewer = true;
    await openApp();
    if (lang === 'he') await switchLanguage(page, 'he');
    // The draft is visible, but there is no plan, publish or draft tool; Versions only.
    await tab(page, 'Schedule', 'לוח', lang);
    await expect(page.locator('.calendar-grid')).toBeVisible();
    await expect(page.locator('.month-primary')).toHaveCount(0);
    await page.getByRole('button', {name: /^(Month actions|פעולות לחודש)$/}).click();
    await expect(page.getByRole('menuitem')).toHaveText([t('Versions', 'גרסאות')]);
    await page.getByRole('menuitem').click();
    await expect(page.getByRole('dialog')).toBeVisible();
    await expect(page.getByRole('button', {name: t('Restore as draft', 'שחזור כטיוטה')})).toHaveCount(0);
    await expect(page.getByRole('button', {name: t('Delete version', 'מחיקת גרסה')})).toHaveCount(0);
    await page.keyboard.press('Escape');
    // Everyone's constraints are readable, the pending sign-up is listed without Approve or Decline.
    await tab(page, 'Availability', 'אילוצים', lang);
    await expect(page.getByRole('combobox', {name: t('Engineer', 'מהנדס')})).toBeVisible();
    await tab(page, 'Team', 'צוות', lang);
    await expect(page.locator('.membership-request')).toContainText('Pat Pending');
    await expect(page.getByRole('button', {name: t('Approve', 'אישור'), exact: true})).toHaveCount(0);
    await snapshot(page, `viewer-admin-team-${lang}`);
    await page.locator(`.team-row[data-member="${ids.e}"] .team-row-inner`).click();
    await expect(page.getByRole('dialog').getByRole('switch')).toHaveCount(0);
    // Nothing was written: no schedule, member, constraint, swap or plan operation was sent.
    expect(backend.calls.map(c => c.name).filter(n => /^duty_(save_schedule|set_(constraints|role|viewer|no_weekends)|review_member|resolve_swap|request_swap|restore_publication|cancel_draft|delete_publication|edit_published|confirm_allocation|save_generation|generation_context|add_temporary|link_temporary)/.test(n))).toEqual([]);
  });
}
