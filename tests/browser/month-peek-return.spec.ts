import type {Page} from '@playwright/test';
import {test, expect, switchLanguage, press} from './fixtures';

// #105 bug: after going to the next month and back, a blurred ghost of the neighbour month's name
// (or its grid) stayed beside the title. A month change must always clear the peek.
test.use({reducedMotion: 'no-preference'});
const screens = [{name: 'Schedule', he: 'לוח', screen: '[data-slot=tabs-content][data-state=active]'}, {name: 'Availability', he: 'אילוצים', screen: '.availability-screen'}];
const heading = (page: Page, screen: string) => page.locator(`${screen} .month-name`).first();
/** Nothing of a neighbour month is left: no peeking name, no peeking grid, no sliding title. */
async function settled(page: Page, screen: string) {
  await page.waitForTimeout(700);
  await expect(page.locator(`${screen} .month-name-peek`)).toHaveCount(0);
  await expect(page.locator(`${screen} .month-peek`)).toHaveCount(0);
  await expect(page.locator(`${screen} .month-title [data-sliding]`)).toHaveCount(0);
}

for (const s of screens) for (const lang of ['en', 'he'] as const) test(`#105: next month and back leaves no peek: chevrons and swipes, ${s.name} ${lang}`, async ({page, openApp}, info) => {
  const he = lang === 'he', mobile = info.project.name === 'mobile', toward = he ? 1 : -1;
  await openApp('admin');
  if (he) await switchLanguage(page, 'he');
  await page.getByRole('tab', {name: he ? s.he : s.name, exact: true}).first().click();
  const name = heading(page, s.screen);
  const nov = he ? 'נובמבר 2026' : 'November 2026', dec = he ? 'דצמבר 2026' : 'December 2026';
  await expect(name).toHaveText(nov);
  const chevron = (next: boolean) => page.locator(s.screen).getByRole('button', {name: next ? (he ? 'חודש הבא' : 'Next month') : (he ? 'חודש קודם' : 'Previous month'), exact: true}).last();
  // The month name dragged to the next month and back (a finger on a phone, the mouse on PC).
  const swipeName = async (dir: 1 | -1) => {
    const box = (await page.locator(`${s.screen} .month-heading`).first().boundingBox())!;
    const g = await press(page, box.x + box.width / 2, box.y + box.height / 2, mobile);
    await g.move(dir * toward * 160);
    await g.end();
  };
  await swipeName(1);
  await expect(name).toHaveText(dec);
  await settled(page, s.screen);
  await swipeName(-1);
  await expect(name).toHaveText(nov);
  await settled(page, s.screen);
  // Chevrons, after the swipes: the neighbour slides in and out without staying.
  await chevron(true).click();
  await expect(name).toHaveText(dec);
  await settled(page, s.screen);
  await chevron(false).click();
  await expect(name).toHaveText(nov);
  await settled(page, s.screen);
  // A grid swipe on a phone, there and back.
  if (mobile) {
    for (const [dir, label] of [[1, dec], [-1, nov]] as const) {
      const box = (await page.locator(`${s.screen} .month-stage`).first().boundingBox())!;
      const g = await press(page, box.x + box.width / 2, box.y + 40, true);
      await g.move(dir * toward * box.width * .3);
      await g.move(dir * toward * box.width * .7);
      await g.end();
      await expect(name).toHaveText(label);
      await settled(page, s.screen);
    }
  }
});
