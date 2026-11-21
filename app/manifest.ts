import type {MetadataRoute} from 'next';
import {APP_DESCRIPTION, APP_NAME, BRAND_COLOR} from '@/lib/brand';
import {BRAND_ENVIRONMENTS, appNameFor, brandEnvironment, publicAsset} from '@/lib/brand-environment';

// Home Screen app (decision 2026-11-06): iPhone receives Web Push only from an app added
// to the Home Screen (iOS 16.4+), which needs this manifest with display "standalone".
// Name and icons follow the environment (issue #93); Production's manifest is unchanged.
export default function manifest(): MetadataRoute.Manifest {
  const environment = brandEnvironment(process.env), name = appNameFor(APP_NAME, environment), dark = BRAND_ENVIRONMENTS[environment].dark;
  return {
    name, short_name: name, description: APP_DESCRIPTION,
    id: '/', start_url: '/', scope: '/', display: 'standalone', background_color: dark, theme_color: environment === 'prod' ? BRAND_COLOR : dark,
    icons: [
      {src: publicAsset(environment, 'icon-192.png'), sizes: '192x192', type: 'image/png', purpose: 'any'},
      {src: publicAsset(environment, 'icon-512.png'), sizes: '512x512', type: 'image/png', purpose: 'any'},
      {src: publicAsset(environment, 'icon-maskable-512.png'), sizes: '512x512', type: 'image/png', purpose: 'maskable'},
    ],
  };
}
