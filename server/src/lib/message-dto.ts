import type { MessageLog, MessagePart, ScheduledMessage } from "@prisma/client";

export const messageDTO = (m: ScheduledMessage & { parts?: MessagePart[] }) => ({
  id: m.id,
  instanceId: m.instanceId,
  recipientJid: m.recipientJid,
  recipientName: m.recipientName,
  recipientKind: m.recipientKind,
  recipientPictureUrl: m.recipientPictureUrl,
  type: m.type,
  body: m.body,
  mediaId: m.mediaId,
  timezone: m.timezone,
  scheduledAt: m.scheduledAt,
  recurrence: m.recurrence,
  recurrenceDays: m.recurrenceDays,
  recurrenceUntil: m.recurrenceUntil,
  nextRunAt: m.nextRunAt,
  status: m.status,
  isAutoReply: m.isAutoReply,
  randomDelay: m.randomDelay,
  typingMs: m.typingMs,
  attempts: m.attempts,
  lastError: m.lastError,
  createdAt: m.createdAt,
  updatedAt: m.updatedAt,
  // partes adicionales del split (vacío = mensaje normal de una sola parte)
  parts: [...(m.parts ?? [])]
    .sort((a, b) => a.order - b.order)
    .map((p) => ({ type: p.type, body: p.body, mediaId: p.mediaId, typingMs: p.typingMs })),
});

export const logDTO = (l: MessageLog) => ({
  id: l.id,
  scheduledMessageId: l.scheduledMessageId,
  runAt: l.runAt,
  status: l.status,
  evolutionMessageId: l.evolutionMessageId,
  remoteJid: l.remoteJid,
  error: l.error,
  sentAt: l.sentAt,
  deliveredAt: l.deliveredAt,
  readAt: l.readAt,
});

// HistoryItem (§15): log enriquecido con snapshot del padre
export const historyItemDTO = (l: MessageLog & { scheduledMessage: ScheduledMessage }) => ({
  id: l.id,
  scheduledMessageId: l.scheduledMessageId,
  runAt: l.runAt,
  status: l.status,
  recipientName: l.scheduledMessage.recipientName,
  recipientKind: l.scheduledMessage.recipientKind,
  recipientPictureUrl: l.scheduledMessage.recipientPictureUrl,
  type: l.scheduledMessage.type,
  body: l.scheduledMessage.body,
  mediaId: l.scheduledMessage.mediaId,
  error: l.error,
});
