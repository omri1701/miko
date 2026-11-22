// Keep date-only display at noon UTC, using the caller's browser time zone.
export function shortDate(day:string,lang:'en'|'he'){
 return new Date(day+'T12:00:00Z').toLocaleDateString(lang==='en'?'en-US':'he-IL',{day:'numeric',month:'short'});
}

// Sort date-only keys so reverse drags display the same chronological range.
// English is month first (#113): "October 12–17", "October 30–November 2"; Hebrew is day first.
// An English range across years is numeric and day first: "30/12/2026–02/01/2027".
export function dateRange(days:string[],lang:'en'|'he'){
 const ordered=[...days].sort(),first=ordered[0],last=ordered.at(-1);
 if(!first||!last)return '';
 const locale=lang==='en'?'en-US':'he-IL';
 const format=(day:string)=>new Date(day+'T12:00:00Z').toLocaleDateString(locale,{day:'numeric',month:'long',...(first.slice(0,4)!==last.slice(0,4)?{year:'numeric' as const}:{})});
 if(lang==='en'&&first.slice(0,4)!==last.slice(0,4))return `${numericDate(first)}–${numericDate(last)}`;
 if(first===last)return format(first);
 if(first.slice(0,7)===last.slice(0,7))return lang==='en'?`${format(first)}–${Number(last.slice(-2))}`:`${Number(first.slice(-2))}–${format(last)}`;
 return `${format(first)}–${format(last)}`;
}

// English dates with a year are numeric and day first (#113): "03/11/2026". Times are 24-hour.
export const numericDate=(day:string)=>`${day.slice(8,10)}/${day.slice(5,7)}/${day.slice(0,4)}`;
const jerusalemDay=new Intl.DateTimeFormat('en-CA',{timeZone:'Asia/Jerusalem',year:'numeric',month:'2-digit',day:'2-digit'});
const jerusalemTime=new Intl.DateTimeFormat('en-US',{timeZone:'Asia/Jerusalem',hour:'2-digit',minute:'2-digit',hourCycle:'h23'});
/** An instant as its Israel date, "09/10/2026", or date and time, "09/10/2026, 14:30". */
export const jerusalemNumericDate=(iso:string)=>numericDate(jerusalemDay.format(new Date(iso)));
export const jerusalemNumericDateTime=(iso:string)=>`${jerusalemNumericDate(iso)}, ${jerusalemTime.format(new Date(iso))}`;
