// Which environment's logo, icons and app name this build shows (issue #93). Only the logo/icon colour and the
// installed app name change; buttons and in-app colours do not. Production stays exactly as it was.
// Derived from existing build/runtime variables, never from the hostname: Vercel's own VERCEL_ENV on hosted
// deployments, DUTY_SUPABASE_TARGET (set by the local launchers) otherwise. With neither (tests, plain
// `next start`) the unchanged navy brand applies.
export type BrandEnvironment = 'prod' | 'dev' | 'local';
/** dark is the logo's navy (icon background, same in every environment); light replaces ONLY its cyan lines. */
export const BRAND_ENVIRONMENTS: Record<BrandEnvironment, {dark: string; light: string; nameSuffix: string}> = {
  prod: {dark: '#090442', light: '#19f2f7', nameSuffix: ''},
  dev: {dark: '#090442', light: '#3ddc84', nameSuffix: ' Dev'},
  local: {dark: '#090442', light: '#9aa0a6', nameSuffix: ' Local'},
};
export function brandEnvironment(env: Record<string, string | undefined>): BrandEnvironment {
  if (env.VERCEL_ENV) return env.VERCEL_ENV === 'production' ? 'prod' : 'dev'; // Preview follows Development.
  if (env.DUTY_SUPABASE_TARGET === 'dev') return 'dev';
  if (env.DUTY_SUPABASE_TARGET === 'local' || env.DUTY_SUPABASE_TARGET === 'prod') return 'local'; // Production inspection runs locally.
  return 'prod';
}
/** Public path of a brand file for an environment; Production keeps the original paths. */
export const assetPath = (environment: BrandEnvironment, file: string) => environment === 'prod' ? file : `env/${environment}/${file}`;
export const publicAsset = (environment: BrandEnvironment, file: string) => `/${assetPath(environment, file)}`;
/** Fixed at build time by next.config.ts (env NEXT_PUBLIC_BRAND_ENV) from the variables above. */
export function currentBrandEnvironment(): BrandEnvironment {
  const value = process.env.NEXT_PUBLIC_BRAND_ENV;
  return value === 'dev' || value === 'local' ? value : 'prod';
}
export const appNameFor = (name: string, environment: BrandEnvironment) => name + BRAND_ENVIRONMENTS[environment].nameSuffix;
