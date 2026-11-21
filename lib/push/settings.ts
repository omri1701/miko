// Each member's notification switches (duty_notification_settings). A missing row means
// these defaults. Times are HH:MM in Asia/Jerusalem.
export type NotificationSettings = {deadlines: boolean; published: boolean; swaps: boolean; edits: boolean; evening: boolean; eveningTime: string;
  morning: boolean; morningTime: string; members: boolean};
export type NotificationState = NotificationSettings & {devices: number};
export const DEFAULT_SETTINGS: NotificationSettings = {deadlines: true, published: true, swaps: true, edits: true, evening: true, eveningTime: '18:00',
  morning: true, morningTime: '08:30', members: true};
export const SWITCHES = ['deadlines', 'published', 'swaps', 'edits', 'evening', 'morning', 'members'] as const;
export type Switch = typeof SWITCHES[number];

// Reminder times are quarter hours: the scheduler runs every 15 minutes (decision 2026-11-06).
export const validTime = (value: unknown): value is string => typeof value === 'string' && /^([01]\d|2[0-3]):(00|15|30|45)$/.test(value);

/** Validates the RPC's JSON; throws a user-facing message when it isn't that shape. */
export function readNotificationState(value: unknown): NotificationState {
  const v = value as Record<string, unknown> | null;
  if (typeof v !== 'object' || v === null || SWITCHES.some(key => typeof v[key] !== 'boolean') || !validTime(v.eveningTime) || !validTime(v.morningTime)
    || !Number.isSafeInteger(v.devices) || (v.devices as number) < 0) throw Error('Could not load notification settings. Please try again.');
  return {...Object.fromEntries(SWITCHES.map(key => [key, v[key]])) as Record<Switch, boolean>, eveningTime: v.eveningTime, morningTime: v.morningTime, devices: v.devices as number};
}

/** Exactly the keys the checked RPC accepts. */
export function settingsPayload(state: NotificationSettings): NotificationSettings {
  if (!validTime(state.eveningTime) || !validTime(state.morningTime)) throw Error('Invalid notification time');
  return {deadlines: state.deadlines, published: state.published, swaps: state.swaps, edits: state.edits, evening: state.evening,
    eveningTime: state.eveningTime, morning: state.morning, morningTime: state.morningTime, members: state.members};
}

/** Where a notification opens (issue #89): a tab and month, plus the exact target —
 * `day` (show that day; with `or`, whichever of the two is the member's duty now), `duty` (the member's own duty on that day), `swap` (an open
 * request on Home) or `focus=approvals` (the join requests). */
export type DeepLink = {tab?: 'home' | 'schedule' | 'availability' | 'team'; month?: string; day?: string; or?: string; duty?: string; swap?: string; focus?: 'approvals'};
export const DEEP_LINK_KEYS = ['tab', 'month', 'day', 'or', 'duty', 'swap', 'focus'] as const;
const DAY = /^\d{4}-(0[1-9]|1[0-2])-(0[1-9]|[12]\d|3[01])$/;
export function deepLink(search: string): DeepLink {
  const query = new URLSearchParams(search), tab = query.get('tab'), month = query.get('month'), day = query.get('day'), or = query.get('or'), duty = query.get('duty'), swap = query.get('swap');
  return {...(tab === 'home' || tab === 'schedule' || tab === 'availability' || tab === 'team' ? {tab} : {}), ...(month && /^\d{4}-(0[1-9]|1[0-2])$/.test(month) ? {month} : {}),
    ...(day && DAY.test(day) ? {day} : {}), ...(or && DAY.test(or) ? {or} : {}), ...(duty && DAY.test(duty) ? {duty} : {}), ...(swap && /^[A-Za-z0-9-]{1,64}$/.test(swap) ? {swap} : {}),
    ...(query.get('focus') === 'approvals' ? {focus: 'approvals' as const} : {})};
}
