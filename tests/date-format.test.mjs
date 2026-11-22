import {test} from 'node:test';
import assert from 'node:assert/strict';
import {dateRange, jerusalemNumericDate, jerusalemNumericDateTime, numericDate, shortDate} from '../lib/date-format.ts';
import {calendarMonthLabel} from '../lib/rota/calendar-dates.ts';

test('availability date titles: single, chronological ranges, months and years', () => {
  // US English (#113): month first.
  assert.equal(dateRange(['2026-10-12'], 'en'), 'October 12');
  assert.equal(dateRange(['2026-10-17', '2026-10-12'], 'en'), 'October 12–17');
  assert.equal(dateRange(['2026-11-02', '2026-10-30'], 'en'), 'October 30–November 2');
  assert.equal(dateRange(['2027-01-02', '2026-12-30'], 'en'), '30/12/2026–02/01/2027');
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

// #113 (owner 2026-11-22): an English date with a year is numeric and day first; times are 24-hour.
test('English dates with a year: DD/MM/YYYY, zero-padded, 24-hour times', () => {
  assert.equal(numericDate('2026-11-03'), '03/11/2026');
  assert.equal(numericDate('2026-12-31'), '31/12/2026');
  // Israel date and time of an instant, whatever the browser's time zone.
  assert.equal(jerusalemNumericDate('2026-10-08T22:30:00Z'), '09/10/2026');
  assert.equal(jerusalemNumericDateTime('2026-10-09T11:05:00Z'), '09/10/2026, 14:05');
  assert.equal(jerusalemNumericDateTime('2026-12-01T21:00:00Z'), '01/12/2026, 23:00');
});
