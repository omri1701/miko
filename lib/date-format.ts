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

// The English version list shows numeric, day-first dates (#113): "09/11/2026, 14:05", 24-hour.
export const numericDate=(day:string)=>`${day.slice(8,10)}/${day.slice(5,7)}/${day.slice(0,4)}`;
const jerusalemDay=new Intl.DateTimeFormat('en-CA',{timeZone:'Asia/Jerusalem',year:'numeric',month:'2-digit',day:'2-digit'});
const jerusalemTime=new Intl.DateTimeFormat('en-GB',{timeZone:'Asia/Jerusalem',hour:'2-digit',minute:'2-digit',hourCycle:'h23'});
/** An instant as its Israel date, "09/10/2026", or date and time, "09/10/2026, 14:30". */
export const jerusalemNumericDate=(iso:string)=>numericDate(jerusalemDay.format(new Date(iso)));
export const jerusalemNumericDateTime=(iso:string)=>`${jerusalemNumericDate(iso)}, ${jerusalemTime.format(new Date(iso))}`;

/** A date-only key with its weekday: "Sat 1 Jan" / "Saturday 1 January" in English, never with a comma
 * (WebKit's en-GB adds "Sat, 1 Jan"); Hebrew as Intl gives it, "יום ו׳, 6 בנוב׳". */
export function weekdayDate(day:string,lang:'en'|'he',style:'short'|'long'='short',timeZone='UTC'){
 const options={weekday:style,day:'numeric',month:style,timeZone} as const,date=new Date(day+'T12:00:00Z');
 if(lang==='he')return date.toLocaleDateString('he-IL',options);
 const parts=new Intl.DateTimeFormat('en-GB',options).formatToParts(date),part=(type:string)=>parts.find(p=>p.type===type)?.value??'';
 return `${part('weekday')} ${part('day')} ${part('month')}`;
}
