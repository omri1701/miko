import {test} from 'node:test';
import assert from 'node:assert/strict';
import {dateRange, jerusalemNumericDate, jerusalemNumericDateTime, numericDate, shortDate, weekdayDate} from '../lib/date-format.ts';

test('availability date titles: single, chronological ranges, months and years', () => {
  assert.equal(dateRange(['2026-10-12'], 'en'), '12 October');
  assert.equal(dateRange(['2026-10-17', '2026-10-12'], 'en'), '12–17 October');
  assert.equal(dateRange(['2026-11-02', '2026-10-30'], 'en'), '30 October–2 November');
  assert.equal(dateRange(['2027-01-02', '2026-12-30'], 'en'), '30 December 2026–2 January 2027');
  assert.equal(dateRange(['2026-10-12'], 'he'), '12 באוקטובר');
  assert.equal(dateRange(['2026-10-17', '2026-10-12'], 'he'), '12–17 באוקטובר');
  assert.equal(dateRange(['2026-11-02', '2026-10-30'], 'he'), '30 באוקטובר–2 בנובמבר');
  assert.equal(dateRange([], 'en'), '');
});

// #113 (owner 2026-11-22): English text dates are day first, as before, and keep the year as
// "9 Oct 2026"; only the version list is numeric ("09/11/2026, 14:05"), 24-hour. Hebrew is unchanged.
test('English dates: day first; version list DD/MM/YYYY, zero-padded, 24-hour times', () => {
  assert.equal(shortDate('2026-11-05', 'en'), '5 Nov');
  assert.equal(shortDate('2026-11-05', 'he'), '5 בנוב׳');
  assert.equal(numericDate('2026-11-03'), '03/11/2026');
  assert.equal(numericDate('2026-12-31'), '31/12/2026');
  // Israel date and time of an instant, whatever the browser's time zone.
  assert.equal(jerusalemNumericDate('2026-10-08T22:30:00Z'), '09/10/2026');
  assert.equal(jerusalemNumericDateTime('2026-10-09T11:05:00Z'), '09/10/2026, 14:05');
  assert.equal(jerusalemNumericDateTime('2026-12-01T21:00:00Z'), '01/12/2026, 23:00');
});

// WebKit (iPhone) gives "Sat, 1 Jan" for en-GB; the English weekday date never has a comma.
test('English weekday dates: "Sat 1 Jan", "Saturday 1 January", no comma; Hebrew unchanged', () => {
  assert.equal(weekdayDate('2028-01-01', 'en'), 'Sat 1 Jan');
  assert.equal(weekdayDate('2026-10-09', 'en', 'long'), 'Friday 9 October');
  assert.equal(weekdayDate('2026-11-12', 'en', 'short', 'Asia/Jerusalem'), 'Thu 12 Nov');
  assert.equal(weekdayDate('2026-11-06', 'he'), new Date('2026-11-06T12:00:00Z').toLocaleDateString('he-IL', {weekday: 'short', day: 'numeric', month: 'short', timeZone: 'UTC'}));
});

test('#105: a single day reads "Sat 1 Jan" in English with no comma, whatever the engine adds', () => {
 assert.equal(weekdayDate('2028-01-01','en'),'Sat 1 Jan');
 assert.equal(weekdayDate('2026-12-09','en'),'Wed 9 Dec');
 assert.equal(weekdayDate('2026-12-09','he'),new Date('2026-12-09T12:00:00Z').toLocaleDateString('he-IL',{weekday:'short',day:'numeric',month:'short',timeZone:'UTC'}));
});
