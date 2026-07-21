import { DateTime } from "luxon";
import { prisma } from "../db.js";
import { ntfyPublish } from "./ntfy.js";
import { broadcast } from "../ws/hub.js";
import { messageDTO } from "../lib/message-dto.js";

// ¿La hora actual (en la zona de la regla) cae dentro de la ventana? Soporta cruce de medianoche (22 → 6).
function inWindow(from: number | null, to: number | null, timezone: string): boolean {
  if (from === null || to === null) return true;
  const h = DateTime.now().setZone(timezone).hour;
  return from <= to ? h >= from && h < to : h >= from || h < to;
}

function extractText(message: any): string {
  return (
    message?.conversation ??
    message?.extendedTextMessage?.text ??
    message?.imageMessage?.caption ??
    message?.videoMessage?.caption ??
    ""
  );
}

function detectType(message: any): "TEXT" | "IMAGE" | "VIDEO" | "DOCUMENT" | "AUDIO" {
  if (message?.audioMessage) return "AUDIO";
  if (message?.imageMessage) return "IMAGE";
  if (message?.videoMessage) return "VIDEO";
  if (message?.documentMessage) return "DOCUMENT";
  return "TEXT";
}

/** Procesa un mensaje entrante (webhook MESSAGES_UPSERT) contra las reglas de la instancia. */
export async function handleIncomingMessage(instanceName: string, data: any): Promise<void> {
  const key = data?.key;
  if (!key || key.fromMe) return; // solo mensajes que RECIBES
  const jid: string = key.remoteJid ?? "";
  // v1: solo chats directos (contactos); grupos y estados fuera
  if (!jid || jid.endsWith("@g.us") || jid.includes("@broadcast")) return;

  const text = extractText(data?.message);
  const senderName: string = data?.pushName ?? jid.split("@")[0];

  const instance = await prisma.instance.findUnique({
    where: { instanceName },
    include: { user: true },
  });
  if (!instance) return;

  // Guardar el mensaje recibido para la pestaña Chats (texto y media), con dedupe por key.id
  const type = detectType(data?.message);
  if (text.trim() || type !== "TEXT") {
    const evolutionMessageId: string | null = key.id ?? null;
    const tsRaw = Number(data?.messageTimestamp ?? 0);
    const sentAt = tsRaw > 0 ? new Date(tsRaw * 1000) : new Date();
    const exists = evolutionMessageId
      ? await prisma.chatMessage.findFirst({ where: { instanceId: instance.id, evolutionMessageId } })
      : null;
    if (!exists) {
      const stored = await prisma.chatMessage.create({
        data: {
          instanceId: instance.id,
          jid,
          fromMe: false,
          type,
          body: text.trim() || null,
          pushName: data?.pushName ?? null,
          evolutionMessageId,
          sentAt,
        },
      });
      broadcast(instance.userId, "chat.incoming", {
        instanceId: instance.id,
        jid,
        type: stored.type,
        body: stored.body,
        sentAt: stored.sentAt,
      });
    }
  }

  if (!text.trim()) return; // las reglas de respuesta automática solo aplican a texto

  const rules = await prisma.autoReply.findMany({
    where: { instanceId: instance.id, enabled: true },
  });

  for (const rule of rules) {
    if (rule.contactJid && rule.contactJid !== jid) continue; // regla para un contacto específico
    if (rule.keyword && !text.toLowerCase().includes(rule.keyword.toLowerCase())) continue;
    if (!inWindow(rule.activeFromHour, rule.activeToHour, rule.timezone)) continue;
    // días activos (ISO 1=lun … 7=dom, en la zona de la regla); vacío = todos
    if (rule.activeDays.length > 0 && !rule.activeDays.includes(DateTime.now().setZone(rule.timezone).weekday)) continue;

    // cooldown por contacto: máx. 1 disparo por regla+jid por ventana
    const since = new Date(Date.now() - rule.cooldownMinutes * 60_000);
    const recent = await prisma.autoReplyHit.findFirst({
      where: { autoReplyId: rule.id, jid, createdAt: { gte: since } },
    });
    if (recent) continue;
    await prisma.autoReplyHit.create({ data: { autoReplyId: rule.id, jid } });

    if (rule.action === "NOTIFY") {
      await ntfyPublish(instance.user, {
        title: `Mensaje de ${senderName}`,
        message: text.slice(0, 140),
        priority: 5,
        tags: ["speech_balloon"],
      });
      continue;
    }

    if (!rule.replyText) continue;
    // anti-detección: responder con retraso aleatorio de 1 a 5 minutos, vía el worker
    // (hereda claim idempotente, delay "escribiendo…", logs e historial)
    const delayMs = 60_000 + Math.floor(Math.random() * 240_000);
    const runAt = new Date(Date.now() + delayMs);
    const msg = await prisma.scheduledMessage.create({
      data: {
        userId: instance.userId,
        instanceId: instance.id,
        recipientJid: jid,
        recipientName: senderName,
        recipientKind: "CONTACT",
        type: "TEXT",
        body: rule.replyText,
        timezone: rule.timezone,
        scheduledAt: runAt,
        nextRunAt: runAt,
        isAutoReply: true,
      },
    });
    broadcast(instance.userId, "message.updated", messageDTO(msg));
  }
}

// limpieza de hits viejos (>7 días) — mismo espíritu que WebhookEventRaw
export async function cleanupAutoReplyHits(): Promise<void> {
  await prisma.autoReplyHit
    .deleteMany({ where: { createdAt: { lt: new Date(Date.now() - 7 * 24 * 3600_000) } } })
    .catch(() => {});
}

// mensajes recibidos: 30 días de retención (la pestaña Chats muestra pocos por chat)
export async function cleanupChatMessages(): Promise<void> {
  await prisma.chatMessage
    .deleteMany({ where: { sentAt: { lt: new Date(Date.now() - 30 * 24 * 3600_000) } } })
    .catch(() => {});
}
