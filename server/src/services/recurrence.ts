import { DateTime } from "luxon";

type Msg = {
  recurrence: "DAILY" | "WEEKLY" | "MONTHLY";
  recurrenceDays: number[];
  timezone: string;
  nextRunAt: Date;
};

export function nextOccurrence(m: Msg): Date {
  const cur = DateTime.fromJSDate(m.nextRunAt, { zone: m.timezone });
  if (m.recurrence === "DAILY") return cur.plus({ days: 1 }).toJSDate();
  if (m.recurrence === "MONTHLY") return cur.plus({ months: 1 }).toJSDate(); // Luxon clampa: 31 ene → 28/29 feb
  const days = [...m.recurrenceDays].sort((a, b) => a - b); // ISO: 1=lun … 7=dom
  for (let i = 1; i <= 7; i++) {
    const cand = cur.plus({ days: i });
    if (days.includes(cand.weekday)) return cand.toJSDate();
  }
  return cur.plus({ days: 7 }).toJSDate();
}
