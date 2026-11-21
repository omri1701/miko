import type {Page} from '@playwright/test';
import {test, expect, ids, duty, NOW} from './fixtures';

// #115: switching months or tabs shows the screen as it is: no spinner, no replayed entrance, no
// bounce. Only data that really changed on screen blinks, once. No new text.
const next = (page: Page) => page.getByRole('button', {name: 'Next month', exact: true}).last();
const tab = (page: Page, name: string) => page.getByRole('tab', {name, exact: true}).first().click();

test('#115 rule 1: a background read of the month shows no spinner, "Generating…", dimming or "Saving…"; Plan pressed meanwhile waits for it', async ({page, openApp}) => {
  await openApp();
  await tab(page, 'Schedule');
  // December's facts arrive late, so a busy Plan button would show for that whole time.
  let release = () => {};
  const held = new Promise<void>(resolve => {release = resolve;});
  await page.route('**/rest/v1/rpc/duty_generation_context', async route => {
    if (route.request().postDataJSON()?.p_month === '2026-12') await held;
    await route.fallback();
  });
  // Every DOM change is checked, so even one frame with the spinner is caught.
  await page.evaluate(() => {
    const w = window as unknown as {busy: boolean};
    w.busy = false;
    new MutationObserver(() => {
      const bar = document.querySelector('.month-bar');
      if (bar?.querySelector('.spin,[aria-busy=true]') || bar?.textContent?.includes('Generating…')) w.busy = true;
      // Nor does the screen dim or say "Saving…" for a read.
      if (document.querySelector('fieldset.workspace-controls:disabled, .side-status')) w.busy = true;
    }).observe(document.body, {subtree: true, childList: true, attributes: true, characterData: true});
  });
  await next(page).click();
  await expect(page.locator('.month-bar .month-name')).toHaveText('December 2026');
  const plan = page.locator('.month-primary');
  await expect(plan).toHaveAccessibleName('Plan the month');
  await expect(plan).toBeEnabled();
  // Plan pressed while the read is held opens the plan once the read lands, without a second read.
  await plan.click();
  await expect(page.getByRole('dialog', {name: 'Plan the month'})).toBeVisible();
  release();
  await expect(page.getByRole('button', {name: 'Confirm & generate', exact: true})).toBeEnabled({timeout: 30_000});
  expect(await page.evaluate(() => (window as unknown as {busy: boolean}).busy)).toBe(false);
});

test.describe('with motion', () => {
  test.use({reducedMotion: 'no-preference'});

  test('#115 rule 2: switching tabs replays no entrance and changing month elsewhere doesn’t roll the Schedule name later', async ({page, openApp}) => {
    await openApp();
    await page.evaluate(() => {
      const w = window as unknown as {played: string[]};
      w.played = [];
      document.addEventListener('animationstart', e => w.played.push(`${(e as AnimationEvent).animationName} ${(e.target as Element).className}`), true);
    });
    await tab(page, 'Schedule'); await tab(page, 'Team'); await tab(page, 'Home');
    await tab(page, 'Availability');
    await next(page).click();
    await expect(page.locator('.month-name:visible')).toHaveText('December 2026');
    await tab(page, 'Schedule');
    await expect(page.locator('.month-bar .month-name')).toHaveText('December 2026');
    await tab(page, 'Team');
    // Only the Constraints name's own roll (its chevron was pressed) may play.
    const played = await page.evaluate(() => (window as unknown as {played: string[]}).played);
    expect(played.filter(p => !/^roll-up month-name$/.test(p))).toEqual([]);
    expect(played.filter(p => /^roll-up/.test(p))).toHaveLength(1);
  });

  test('#115 rule 2: the Constraints grid lands on the new month without bouncing', async ({page, openApp}) => {
    await openApp('a');
    await tab(page, 'Availability');
    await expect(page.locator('.availability-tools')).toBeVisible();
    // Every frame of the change: what sits under the grid moves one way only, then stays.
    await page.evaluate(() => {
      const w = window as unknown as {tops: number[]};
      w.tops = [];
      const start = performance.now();
      const step = () => {
        w.tops.push(Math.round(document.querySelector('.availability-tools')!.getBoundingClientRect().top));
        if (performance.now() - start < 1200) requestAnimationFrame(step);
      };
      requestAnimationFrame(step);
    });
    await next(page).click();
    await page.waitForTimeout(1400);
    const tops = await page.evaluate(() => (window as unknown as {tops: number[]}).tops);
    const moves = tops.slice(1).map((top, i) => Math.sign(top - tops[i])).filter(Boolean);
    expect(new Set(moves).size, `tops: ${tops.join(',')}`).toBeLessThanOrEqual(1);
  });

  test('#115 rule 3: a refresh blinks only the days whose duty changed; changing month or tab blinks nothing', async ({page, backend, openApp}) => {
    await page.clock.install({time: new Date(NOW)});
    // Every blink is recorded with its day.
    await page.addInitScript(() => {
      const w = window as unknown as {blinks: string[]};
      w.blinks = [];
      const animate = Element.prototype.animate;
      Element.prototype.animate = function (this: Element, ...args: Parameters<Element['animate']>) {
        const day = this.closest('.month-pane:not(.month-peek) [data-date]')?.getAttribute('data-date');
        if (day && this.classList.contains('assignment-chip')) w.blinks.push(day);
        return animate.apply(this, args);
      };
    });
    await openApp('a');
    await tab(page, 'Schedule');
    await expect(duty(page, '2026-11-10')).toBeVisible();
    const blinks = () => page.evaluate(() => (window as unknown as {blinks: string[]}).blinks.splice(0));
    // Another month and back, and another tab and back: nothing changed, nothing blinks.
    await next(page).click();
    await expect(page.locator('.month-bar .month-name')).toHaveText('December 2026');
    await page.getByRole('button', {name: 'Previous month', exact: true}).last().click();
    await expect(page.locator('.month-bar .month-name')).toHaveText('November 2026');
    await tab(page, 'Team'); await tab(page, 'Schedule');
    expect(await blinks()).toEqual([]);
    // Someone else's change arrives with the next refresh: only that day blinks, once.
    const row = backend.raw.assignments.find(r => r.publication_id !== null && r.day === '2026-11-10')!;
    const other = [ids.b, ids.c].find(id => id !== row.primary_id)!;
    row.primary_id = other;
    backend.raw.revision!++;
    await page.clock.runFor(30_000);
    await expect(duty(page, '2026-11-10')).toHaveAttribute('aria-label', new RegExp(backend.raw.members.find(m => m.id === other)!.name));
    await expect.poll(blinks).toEqual(['2026-11-10']);
    await page.clock.runFor(30_000);
    expect(await blinks()).toEqual([]);
  });
});
