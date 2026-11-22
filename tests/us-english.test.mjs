import test from 'node:test';
import assert from 'node:assert/strict';
import {readdirSync, readFileSync, statSync} from 'node:fs';
import {join} from 'node:path';

// US English spelling (#113); English dates stay day first, and a date with a year is numeric.
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

// Owner 2026-11-22: English text dates stay day first, as before #113 ("5 Nov", "Fri 6 Nov",
// "Friday 9 October"), so English dates are never formatted en-US (month first).
test('rule 2: English dates are day first, never en-US', () => {
  const hits = lines().filter(({line}) => line.includes('en-US'))
    .map(({file, n, line}) => `${file}:${n}: ${line.trim().slice(0, 100)}`);
  assert.deepEqual(hits, []);
});

// An English date with a year is numeric and day first ("03/11/2026", numericDate), never
// "3 Nov 2026"; month titles ("November 2026") have no day and stay.
test('rule 3: English dates with a day and a year are not formatted with Intl', () => {
  const hits = lines().filter(({line}) => line.includes('en-GB') && /\bday:/.test(line) && /\byear:/.test(line))
    .map(({file, n, line}) => `${file}:${n}: ${line.trim().slice(0, 100)}`);
  assert.deepEqual(hits, []);
});
