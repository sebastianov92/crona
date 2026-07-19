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

/** Procesa un mensaje entrante (webhook MESSAGES_UPSERT) contra las reglas de la instancia. */
export async function handleIncomingMessage(instanceName: string, data: any): Promise<void> {
  const key = data?.key;
  if (!key || key.fromMe) return; // solo mensajes que RECIBES
  const jid: string = key.remoteJid ?? "";
  // v1: solo chats directos (contactos); grupos y estados fuera
  if (!jid || jid.endsWith("@g.us") || jid.includes("@broadcast")) return;

  const text = extractText(data?.message);
  if (!text.trim()) return;
  const senderName: string = data?.pushName ?? jid.split("@")[0];

  const instance = await prisma.instance.findUnique({
    where: { instanceName },
    include: { user: true },
  });
  if (!instance) return;

  const rules = await prisma.autoReply.findMany({
    where: { instanceId: instance.id, enabled: true },
  });

  for (const rule of rules) {
    if (rule.keyword && !text.toLowerCase().includes(rule.keyword.toLowerCase())) continue;
    if (!inWindow(rule.activeFromHour, rule.activeToHour, rule.timezone)) continue;

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
