import {test} from 'node:test';
import assert from 'node:assert/strict';
import {dateRange,weekdayDate} from '../lib/date-format.ts';

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

test('#105: a single day reads "Sat 1 Jan" in English with no comma, whatever the engine adds', () => {
 assert.equal(weekdayDate('2028-01-01','en'),'Sat 1 Jan');
 assert.equal(weekdayDate('2026-12-09','en'),'Wed 9 Dec');
 assert.equal(weekdayDate('2026-12-09','he'),new Date('2026-12-09T12:00:00Z').toLocaleDateString('he-IL',{weekday:'short',day:'numeric',month:'short',timeZone:'UTC'}));
});
