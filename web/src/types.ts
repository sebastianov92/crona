export type Role = "ADMIN" | "USER";
export type InstanceStatus = "CREATED" | "CONNECTING" | "CONNECTED" | "DISCONNECTED";
export type RecipientKind = "CONTACT" | "GROUP";
export type MessageType = "TEXT" | "IMAGE" | "VIDEO" | "DOCUMENT" | "AUDIO";
export type Recurrence = "NONE" | "DAILY" | "WEEKLY" | "MONTHLY" | "YEARLY";
export type ScheduleStatus = "ACTIVE" | "PAUSED" | "COMPLETED" | "CANCELLED" | "FAILED";
export type LogStatus = "SENDING" | "SENT" | "DELIVERED" | "READ" | "FAILED";
export type AutoReplyAction = "REPLY" | "NOTIFY";

export interface User {
  id: string;
  email: string;
  name: string;
  role: Role;
  ntfyTopic: string | null;
  notifyOnSent: boolean;
  chatListCount: number;
  chatIncomingCount: number;
  defaultInstanceId: string | null;
  quickHours: QuickHours;
  createdAt: string;
}

export interface QuickRange {
  start: number; // minuto del día 0-1439
  end: number; // == start → hora exacta (envía +1..5 min); si no, aleatorio dentro del rango
}

export interface QuickHours {
  morning: QuickRange;
  afternoon: QuickRange;
  evening: QuickRange;
}

/** Fecha para un botón rápido: antes de la hora → hoy; dentro del rango o después → mañana. */
export function quickDate(r: QuickRange): Date {
  const now = new Date();
  const nowMin = now.getHours() * 60 + now.getMinutes();
  const d = new Date(now);
  if (nowMin >= r.start) d.setDate(d.getDate() + 1);
  const minute =
    r.start === r.end
      ? r.start + 1 + Math.floor(Math.random() * 5)
      : r.start + Math.floor(Math.random() * (r.end - r.start + 1));
  d.setHours(Math.floor(minute / 60), minute % 60, 0, 0);
  return d;
}

export interface ContactList {
  id: string;
  instanceId: string;
  name: string;
  createdAt: string;
  members: { jid: string; name: string; pictureUrl: string | null; kind: RecipientKind }[];
}

export interface ChatSummary {
  instanceId: string;
  jid: string;
  name: string;
  pictureUrl: string | null;
  kind: RecipientKind;
  pendingCount: number;
  last: { fromMe: boolean; type: MessageType; body: string | null; at: string } | null;
  lastAt: string;
}

export interface ChatBubble {
  id: string;
  direction: "in" | "out" | "scheduled";
  type: MessageType;
  body: string | null;
  at: string;
  status: string | null;
  scheduledMessageId: string | null;
}

export interface Instance {
  id: string;
  name: string;
  instanceName: string;
  phoneNumber: string | null;
  profilePicUrl: string | null;
  status: InstanceStatus;
  lastConnectedAt: string | null;
  createdAt: string;
}

export interface Recipient {
  id: string;
  jid: string;
  displayName: string;
  alias: string | null;
  pictureUrl: string | null;
  kind: RecipientKind;
  phoneNumber: string | null;
}

/** Nombre a mostrar: alias local de Crona si existe, si no el pushName de WhatsApp. */
export const shownName = (r: Recipient) => r.alias || r.displayName;

export interface ScheduledMessage {
  id: string;
  instanceId: string;
  recipientJid: string;
  recipientName: string;
  recipientKind: RecipientKind;
  recipientPictureUrl: string | null;
  type: MessageType;
  body: string | null;
  mediaId: string | null;
  timezone: string;
  scheduledAt: string;
  recurrence: Recurrence;
  recurrenceDays: number[];
  recurrenceUntil: string | null;
  nextRunAt: string;
  status: ScheduleStatus;
  isAutoReply: boolean;
  randomDelay: boolean;
  attempts: number;
  lastError: string | null;
  createdAt: string;
  updatedAt: string;
}

export interface MessageLog {
  id: string;
  scheduledMessageId: string;
  runAt: string;
  status: LogStatus;
  evolutionMessageId: string | null;
  remoteJid: string;
  error: string | null;
  sentAt: string | null;
  deliveredAt: string | null;
  readAt: string | null;
}

export interface HistoryItem {
  id: string;
  scheduledMessageId: string;
  runAt: string;
  status: LogStatus;
  recipientName: string;
  recipientKind: RecipientKind;
  recipientPictureUrl: string | null;
  type: MessageType;
  body: string | null;
  mediaId: string | null;
  error: string | null;
}

export interface AutoReply {
  id: string;
  instanceId: string;
  action: AutoReplyAction;
  contactJid: string | null;
  contactName: string | null;
  keyword: string | null;
  replyText: string | null;
  activeFromHour: number | null;
  activeToHour: number | null;
  activeDays: number[];
  timezone: string;
  cooldownMinutes: number;
  enabled: boolean;
  createdAt: string;
}

export interface AdminSettings {
  evolutionBaseUrl: string;
  evolutionGlobalApiKeySet: boolean;
  ntfyBaseUrl: string;
}

export interface Paginated<T> {
  items: T[];
  nextCursor: string | null;
}
