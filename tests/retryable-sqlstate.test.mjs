// #86: PostgREST re-runs a transaction that fails with SQLSTATE 40001 (serialization_failure)
// or 40P01 (deadlock_detected). A refusal raised on purpose with either code never succeeds on
// a retry, so in Production each such request looped forever (about 600 transactions a second
// for 12 days). No canonical database source may raise them; catching them is fine.
import assert from 'node:assert/strict';
import {readdirSync, readFileSync} from 'node:fs';
import {join, relative} from 'node:path';
import test from 'node:test';

// Files allowed to raise a retryable SQLSTATE on purpose, with the reason. Keep it empty.
const ALLOWED = new Map();

const RAISES = [
  /errcode\s*(=|:=)\s*'(40001|40P01|serialization_failure|deadlock_detected)'/i,
  /\braise\s+(exception\s+)?(serialization_failure|deadlock_detected)\b/i,
  /\braise\s+(exception\s+)?sqlstate\s+'(40001|40P01)'/i,
];
/** The retryable raises in SQL text, ignoring `--` comments. */
export function retryableRaises(sql) {
  return sql.split(/\r?\n/).map((line, i) => ({line: i + 1, text: line.replace(/--.*$/, '')}))
    .filter(({text}) => RAISES.some(pattern => pattern.test(text)));
}
const sources = dir => readdirSync(dir, {withFileTypes: true}).flatMap(entry =>
  entry.isDirectory() ? sources(join(dir, entry.name)) : entry.name.endsWith('.sql') ? [join(dir, entry.name)] : []);

test('the detector finds every way to raise 40001/40P01 and ignores handlers and comments', () => {
  for (const sql of [
    "raise exception 'The team data changed.' using errcode='40001';",
    "RAISE EXCEPTION 'x' USING ERRCODE = '40P01';",
    "raise exception using errcode='serialization_failure', message='x';",
    'raise serialization_failure;',
    'RAISE EXCEPTION deadlock_detected;',
    "raise sqlstate '40001';",
  ]) assert.equal(retryableRaises(sql).length, 1, sql);
  for (const sql of [
    'exception when serialization_failure then null;',
    "exception when sqlstate '40001' then null;",
    "raise exception 'Refresh and try again.' using errcode='PT409';",
    "-- never: using errcode='40001'",
  ]) assert.equal(retryableRaises(sql).length, 0, sql);
});

test('no canonical database source raises a retryable SQLSTATE (PostgREST would retry it forever)', () => {
  const root = 'supabase/schemas', found = [];
  for (const file of sources(root)) {
    const name = relative(root, file).replaceAll('\\', '/');
    if (ALLOWED.has(name)) continue;
    for (const {line, text} of retryableRaises(readFileSync(file, 'utf8'))) found.push(`${name}:${line}: ${text.trim()}`);
  }
  assert.deepEqual(found, [], 'Raise a non-retryable code instead (the stale-revision refusal uses PT409, HTTP 409)');
});
