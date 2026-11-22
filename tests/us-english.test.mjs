import test from 'node:test';
import assert from 'node:assert/strict';
import {readdirSync, readFileSync, statSync} from 'node:fs';
import {join} from 'node:path';

// US English everywhere (#113): the English UI uses US spelling and month-first dates.
// Hebrew texts and dates, code identifiers, CSS classes and stored values don't change.
const ROOTS = ['app', 'components', 'hooks', 'lib'];
const SKIP = new Set(['node_modules', '.next']);
const CODE = /\.(ts|tsx)$/;

function files(path) {
  if (SKIP.has(path.split(/[\\/]/).at(-1))) return [];
  return statSync(path).isDirectory() ? readdirSync(path).flatMap(name => files(join(path, name))) : CODE.test(path) ? [path] : [];
}
const lines = () => ROOTS.flatMap(files).flatMap(file => readFileSync(file, 'utf8').split('\n').map((line, i) => ({file, n: i + 1, line})));

const BRITISH = /\b(colours?|cancell(ed|ing)|favourit\w*|centr(e|es|ed)|organis\w*|grey(ed)?|neighbour\w*|behaviour\w*|recognis\w*|honour\w*|acknowledgement|judgement)\b/i;
// Stored values that keep their spelling (rule 4): the 'cancelled' swap/contribution status.
const STORED = new Set(['cancelled']);
const LITERAL = /(['"`])((?:\\.|(?!\1)[^\\])*)\1/g;

test('rule 1: English UI strings use US spelling', () => {
  const hits = lines().flatMap(({file, n, line}) => {
    const code = line.replace(/\/\/.*$/, '').replace(/\/\*.*?\*\//g, '');
    if (/^\s*(\*|\/\*)/.test(code)) return [];
    return [...code.matchAll(LITERAL)].map(m => m[2]).filter(text => !STORED.has(text) && /colour|cancelled|favourite|centre|organis|grey|neighbour|behaviour|recognis|honour|acknowledgement|judgement/i.test(text) && BRITISH.test(text))
      .map(text => `${file}:${n}: ${text.slice(0, 100)}`);
  });
  assert.deepEqual(hits, []);
});

// The two clock parsers read numeric parts only (never shown), so their locale doesn't matter.
const INTERNAL = new Set(['lib/scheduling/calendar.ts', 'components/home/home-data.ts:greeting']);
test('rule 2: English dates are formatted en-US, never en-GB', () => {
  const hits = lines().filter(({file, line}) => line.includes('en-GB')
    && !INTERNAL.has(file.replaceAll('\\', '/'))
    && !(file.replaceAll('\\', '/') === 'components/home/home-data.ts' && /hour12: false/.test(line)))
    .map(({file, n, line}) => `${file}:${n}: ${line.trim().slice(0, 100)}`);
  assert.deepEqual(hits, []);
});

// Owner 2026-11-22: an English date with a year is numeric and day first ("03/11/2026", numericDate),
// never "Nov 3, 2026"; month titles ("November 2026") have no day and stay.
test('rule 3: English dates with a day and a year are not formatted with Intl', () => {
  const hits = lines().filter(({line}) => line.includes('en-US') && /\bday:/.test(line) && /\byear:/.test(line))
    .map(({file, n, line}) => `${file}:${n}: ${line.trim().slice(0, 100)}`);
  assert.deepEqual(hits, []);
});
