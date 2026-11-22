// Screen texts the user approved (#110, #111), kept together so they're easy to change.
// Every new user-facing text needs the user's approval before it ships.
type Language = 'en' | 'he';

/** "February" / "פברואר": a month's name without the year. */
export function monthName(month: string, lang: Language) {
  return new Date(`${month}-15T12:00:00Z`).toLocaleDateString(lang === 'en' ? 'en-GB' : 'he-IL', {month: 'long', timeZone: 'UTC'});
}
/** "22 Dec" / "22 בדצמ׳". */
function shortDay(day: string, lang: Language) {
  return new Date(`${day}T12:00:00Z`).toLocaleDateString(lang === 'en' ? 'en-GB' : 'he-IL', {day: 'numeric', month: 'short', timeZone: 'UTC'});
}

export const texts = {
  /** #110: one draft conflict, for admins (the note only when there is one). */
  conflictLine: (name: string, day: string, note: string | undefined, lang: Language) => {
    const tail = note?.trim() ? ` · ${note.trim()}` : '';
    return lang === 'en' ? `${name} marked ${shortDay(day, lang)} as unavailable${tail}` : `${name} סימן/ה את ${shortDay(day, lang)} כלא זמין${tail}`;
  },
  /** #111: a month after the open window (the database's refusal, or a tap on such a month). */
  monthNotOpen: (month: string, lang: Language) => lang === 'en' ? `${monthName(month, lang)} isn't open yet` : `${monthName(month, lang)} עוד לא נפתח`,
  /** #111: a tap on a day of a month before the current one. */
  monthClosed: (month: string, lang: Language) => lang === 'en' ? `${monthName(month, lang)} is closed` : `${monthName(month, lang)} כבר נסגר`,
  /** #111: a tap on a day of the current month that has passed (Israel time), or the database's refusal. */
  dayPassed: (lang: Language) => lang === 'en' ? 'This day has passed' : 'היום הזה כבר עבר',
  /** #105 rule 6: the admins' first picker choice on Constraints, every member at once. */
  everyone: (lang: Language) => lang === 'en' ? 'Everyone' : 'כולם',
};
