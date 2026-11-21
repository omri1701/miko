import {test} from 'node:test';
import assert from 'node:assert/strict';
import {dateRange, shortDate} from '../lib/date-format.ts';
import {calendarMonthLabel} from '../lib/rota/calendar-dates.ts';

test('availability date titles: single, chronological ranges, months and years', () => {
  // US English (#113): month first.
  assert.equal(dateRange(['2026-10-12'], 'en'), 'October 12');
  assert.equal(dateRange(['2026-10-17', '2026-10-12'], 'en'), 'October 12–17');
  assert.equal(dateRange(['2026-11-02', '2026-10-30'], 'en'), 'October 30–November 2');
  assert.equal(dateRange(['2027-01-02', '2026-12-30'], 'en'), 'December 30, 2026–January 2, 2027');
  assert.equal(dateRange(['2026-10-12'], 'he'), '12 באוקטובר');
  assert.equal(dateRange(['2026-10-17', '2026-10-12'], 'he'), '12–17 באוקטובר');
  assert.equal(dateRange(['2026-11-02', '2026-10-30'], 'he'), '30 באוקטובר–2 בנובמבר');
  assert.equal(dateRange([], 'en'), '');
});

// #113 rule 2 and 3: English short dates are month first; Hebrew is unchanged.
test('short dates and month titles: US English, Hebrew unchanged', () => {
  assert.equal(shortDate('2026-11-05', 'en'), 'Nov 5');
  assert.equal(shortDate('2026-11-05', 'he'), '5 בנוב׳');
  assert.equal(calendarMonthLabel('2026-11', 'en'), 'November 2026');
});
