import test from 'node:test';
import assert from 'node:assert/strict';
import {existsSync, readFileSync} from 'node:fs';
import {BRAND_ENVIRONMENTS, appNameFor, assetPath, brandEnvironment, publicAsset} from '../lib/brand-environment.ts';

// Issue #93 rules 1-4: colour and app name per environment, Production unchanged.
test('rules 1-3: environment comes from Vercel/launcher variables; Production and unknown stay navy',()=>{
 assert.equal(brandEnvironment({VERCEL_ENV:'production'}),'prod');
 assert.equal(brandEnvironment({VERCEL_ENV:'development'}),'dev');
 assert.equal(brandEnvironment({VERCEL_ENV:'preview'}),'dev');
 assert.equal(brandEnvironment({DUTY_SUPABASE_TARGET:'dev'}),'dev');
 assert.equal(brandEnvironment({DUTY_SUPABASE_TARGET:'local'}),'local');
 assert.equal(brandEnvironment({DUTY_SUPABASE_TARGET:'prod'}),'local');
 assert.equal(brandEnvironment({}),'prod');
 // A hosted deployment is decided by VERCEL_ENV, never by a launcher variable.
 assert.equal(brandEnvironment({VERCEL_ENV:'production',DUTY_SUPABASE_TARGET:'local'}),'prod');
 assert.equal(brandEnvironment({VERCEL_ENV:'preview',DUTY_SUPABASE_TARGET:'local'}),'dev');
});

test('rule 3: Production keeps the original asset paths, name and colours',()=>{
 assert.equal(publicAsset('prod','icon-192.png'),'/icon-192.png');
 assert.equal(assetPath('prod','brand/logo-96.webp'),'brand/logo-96.webp');
 assert.equal(appNameFor('MiKo','prod'),'MiKo');
 assert.equal(BRAND_ENVIRONMENTS.prod.dark,'#090442');
});

test('rule 4: the installed app name shows the environment except on Production',()=>{
 assert.equal(appNameFor('MiKo','dev'),'MiKo Dev');
 assert.equal(appNameFor('MiKo','local'),'MiKo Local');
});

test('rules 1-2: every favicon, Home Screen, manifest and in-app logo file exists for dev and local',()=>{
 for(const env of ['dev','local'])for(const file of ['favicon.svg','favicon-32.png','favicon-48.png','apple-touch-icon.png','icon-192.png','icon-512.png','icon-maskable-512.png',
  ...[96,192,512].flatMap(s=>[`brand/logo-${s}.png`,`brand/logo-${s}.webp`])])
  assert.ok(existsSync(new URL(`../public${publicAsset(env,file)}`,import.meta.url)),`${env}/${file}`);
 assert.notDeepEqual(readFileSync(new URL('../public/env/dev/icon-512.png',import.meta.url)),readFileSync(new URL('../public/env/local/icon-512.png',import.meta.url)));
});

test('the layout and manifest take names and icons from the environment',()=>{
 const layout=readFileSync(new URL('../app/layout.tsx',import.meta.url),'utf8'),manifest=readFileSync(new URL('../app/manifest.ts',import.meta.url),'utf8');
 for(const text of [layout,manifest])assert.match(text,/brand-environment/);
 assert.match(layout,/apple: icon\('apple-touch-icon\.png'\)/);assert.match(layout,/title: appName/);
 assert.match(manifest,/short_name: name/);assert.match(manifest,/publicAsset\(environment, 'icon-maskable-512\.png'\)/);
});
