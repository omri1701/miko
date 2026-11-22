import test from 'node:test';
import assert from 'node:assert/strict';
import {texts, monthName} from '../lib/texts.ts';
import {userMessage} from '../lib/messages.ts';

// The approved texts (#110, #111) live in lib/texts.ts; these pin them word for word.
const en = (a) => a, he = (_a, b) => b;

test('#110 rule 1: a conflict line names who marked which day, with the note only when there is one', () => {
  assert.equal(texts.conflictLine('Avi', '2026-12-22', 'doctor', 'en'), 'Avi marked 22 Dec as unavailable · doctor');
  assert.equal(texts.conflictLine('אבי', '2026-12-22', 'רופא', 'he'), 'אבי סימן/ה את 22 בדצמ׳ כלא זמין · רופא');
  assert.equal(texts.conflictLine('Avi', '2026-12-22', '  ', 'en'), 'Avi marked 22 Dec as unavailable');
  assert.equal(texts.conflictLine('Avi', '2026-12-22', undefined, 'he'), 'Avi סימן/ה את 22 בדצמ׳ כלא זמין');
});

test('#111: closed-day toasts and the database refusals use the approved texts, the month named', () => {
  assert.equal(monthName('2027-02', 'en'), 'February');
  assert.equal(monthName('2027-02', 'he'), 'פברואר');
  assert.equal(texts.monthNotOpen('2027-02', 'en'), "February isn't open yet");
  assert.equal(texts.monthNotOpen('2027-02', 'he'), 'פברואר עוד לא נפתח');
  assert.equal(texts.monthClosed('2026-10', 'en'), 'October is closed');
  assert.equal(texts.monthClosed('2026-10', 'he'), 'אוקטובר כבר נסגר');
  assert.equal(texts.dayPassed('en'), 'This day has passed');
  assert.equal(texts.dayPassed('he'), 'היום הזה כבר עבר');
  assert.equal(userMessage('constraints-window-closed:2027-02', en), "February isn't open yet");
  assert.equal(userMessage('constraints-window-closed:2027-02', he), 'פברואר עוד לא נפתח');
  assert.equal(userMessage('constraints-day-passed', en), 'This day has passed');
  assert.equal(userMessage('constraints-day-passed', he), 'היום הזה כבר עבר');
});

test('#105 rule 6: the admins\' Everyone choice uses the approved text', () => {
  assert.equal(texts.everyone('en'), 'Everyone');
  assert.equal(texts.everyone('he'), 'כולם');
});
