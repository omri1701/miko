// Keep date-only display at noon UTC, using the caller's browser time zone.
export function shortDate(day:string,lang:'en'|'he'){
 return new Date(day+'T12:00:00Z').toLocaleDateString(lang==='en'?'en-GB':'he-IL',{day:'numeric',month:'short'});
}

// Sort date-only keys so reverse drags display the same chronological range.
export function dateRange(days:string[],lang:'en'|'he'){
 const ordered=[...days].sort(),first=ordered[0],last=ordered.at(-1);
 if(!first||!last)return '';
 const locale=lang==='en'?'en-GB':'he-IL';
 const format=(day:string)=>new Date(day+'T12:00:00Z').toLocaleDateString(locale,{day:'numeric',month:'long',...(first.slice(0,4)!==last.slice(0,4)?{year:'numeric' as const}:{})});
 if(first===last)return format(first);
 if(first.slice(0,7)===last.slice(0,7))return `${Number(first.slice(-2))}–${format(last)}`;
 return `${format(first)}–${format(last)}`;
}

/** "Sat 1 Jan" / "יום ש׳, 1 בינו׳". English is assembled from its parts: WebKit's en-GB adds a comma
 * after the weekday ("Sat, 1 Jan") that Chromium leaves out, and the app shows the same on both. */
export function weekdayDate(day:string,lang:'en'|'he'){
 const date=new Date(day+'T12:00:00Z'),options={weekday:'short',day:'numeric',month:'short',timeZone:'UTC'} as const;
 if(lang==='he')return date.toLocaleDateString('he-IL',options);
 const part=(type:string)=>new Intl.DateTimeFormat('en-GB',options).formatToParts(date).find(p=>p.type===type)?.value??'';
 return `${part('weekday')} ${part('day')} ${part('month')}`;
}
