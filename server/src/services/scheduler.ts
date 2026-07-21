import type { Instance, MessageLog, ScheduledMessage, User } from "@prisma/client";
import { DateTime } from "luxon";
import { prisma } from "../db.js";
import { evolution } from "./evolution.js";
import { decrypt } from "./crypto.js";
import { nextOccurrence } from "./recurrence.js";
import { ntfyPublish } from "./ntfy.js";
import { broadcast } from "../ws/hub.js";
import { messageDTO, logDTO } from "../lib/message-dto.js";
import { buildAudioPayload, buildMediaPayload, deleteMediaFile } from "./media.js";
import { cleanupAutoReplyHits, cleanupChatMessages } from "./autoreply.js";
import { renderVariables } from "../lib/variables.js";

const TICK_MS = 30_000;
const MAX_ATTEMPTS = 3;
const BACKOFFS_MIN = [2, 10]; // reintento 1 → +2 min, reintento 2 → +10 min

type FullMessage = ScheduledMessage & { instance: Instance; user: User };

const sleep = (ms: number) => new Promise((r) => setTimeout(r, ms));
const rand = (min: number, max: number) => min + Math.floor(Math.random() * (max - min));

export async function recoverOnBoot() {
  await prisma.messageLog.updateMany({
    where: { status: "SENDING" },
    data: { status: "FAILED", error: "INTERRUMPIDO (reinicio del servidor)" },
  });
  await prisma.scheduledMessage.updateMany({
    where: { claimedAt: { not: null } },
    data: { claimedAt: null },
  });
}

export async function claimDue(limit = 10): Promise<string[]> {
  return prisma.$transaction(async (tx) => {
    const rows = await tx.$queryRaw<{ id: string }[]>`
      SELECT id FROM "ScheduledMessage"
      WHERE status = 'ACTIVE'
        AND "nextRunAt" <= now()
        AND ("claimedAt" IS NULL OR "claimedAt" < now() - interval '5 minutes')
      ORDER BY "nextRunAt" ASC
      FOR UPDATE SKIP LOCKED
      LIMIT ${limit}`;
    const ids = rows.map((r) => r.id);
    if (ids.length)
      await tx.scheduledMessage.updateMany({
        where: { id: { in: ids } },
        data: { claimedAt: new Date() },
      });
    return ids;
  });
}

// Recurrentes con randomDelay: cada ocurrencia se corre +1..5 min para no enviar
// siempre a la hora exacta (anti-detección). Antes de calcular la siguiente, se
// re-ancla a la hora original (scheduledAt) para que el jitter NO se acumule día a día.
function jitteredNext(msg: FullMessage): Date {
  let base = msg.nextRunAt;
  if (msg.randomDelay) {
    const sched = DateTime.fromJSDate(msg.scheduledAt, { zone: msg.timezone });
    let cur = DateTime.fromJSDate(msg.nextRunAt, { zone: msg.timezone }).set({
      hour: sched.hour,
      minute: sched.minute,
      second: sched.second,
    });
    // si el jitter cruzó medianoche, re-anclar puede saltar ±1 día — corregirlo
    const diffH = cur.diff(DateTime.fromJSDate(msg.nextRunAt), "hours").hours;
    if (diffH > 12) cur = cur.minus({ days: 1 });
    if (diffH < -12) cur = cur.plus({ days: 1 });
    base = cur.toJSDate();
  }
  const next = nextOccurrence({ ...msg, nextRunAt: base } as Parameters<typeof nextOccurrence>[0]);
  if (!msg.randomDelay) return next;
  return new Date(next.getTime() + 60_000 + Math.floor(Math.random() * 240_000));
}

async function onOccurrenceSuccess(msg: FullMessage) {
  let data: Record<string, unknown>;
  if (msg.recurrence === "NONE") {
    data = { status: "COMPLETED", attempts: 0, lastError: null, claimedAt: null };
  } else {
    const next = jitteredNext(msg);
    data =
      msg.recurrenceUntil && next > msg.recurrenceUntil
        ? { status: "COMPLETED", attempts: 0, lastError: null, claimedAt: null }
        : { nextRunAt: next, attempts: 0, lastError: null, claimedAt: null };
  }
  const updated = await prisma.scheduledMessage.update({ where: { id: msg.id }, data });
  broadcast(msg.userId, "message.updated", messageDTO(updated));
}

async function onOccurrenceFailure(msg: FullMessage, errText: string) {
  const attempts = msg.attempts + 1;

  if (attempts < MAX_ATTEMPTS) {
    const backoffMin = BACKOFFS_MIN[attempts - 1] ?? 10;
    const updated = await prisma.scheduledMessage.update({
      where: { id: msg.id },
      data: {
        attempts,
        lastError: errText,
        nextRunAt: new Date(Date.now() + backoffMin * 60_000),
        claimedAt: null,
      },
    });
    broadcast(msg.userId, "message.updated", messageDTO(updated));
    return;
  }

  // 3er fallo: notificar ntfy prioridad alta
  await ntfyPublish(msg.user, {
    title: "Mensaje no enviado",
    message: `No se envió tu mensaje a ${msg.recipientName}: ${errText}`,
    priority: 4,
    tags: ["x"],
  });

  let data: Record<string, unknown>;
  if (msg.recurrence === "NONE") {
    data = { status: "FAILED", attempts, lastError: errText, claimedAt: null };
  } else {
    // recurrente: registrar la ocurrencia fallida y saltar a la siguiente
    const next = jitteredNext(msg);
    data =
      msg.recurrenceUntil && next > msg.recurrenceUntil
        ? { status: "COMPLETED", attempts: 0, lastError: errText, claimedAt: null }
        : { nextRunAt: next, attempts: 0, lastError: errText, claimedAt: null };
  }
  const updated = await prisma.scheduledMessage.update({ where: { id: msg.id }, data });
  broadcast(msg.userId, "message.updated", messageDTO(updated));
}

async function createLog(msg: FullMessage): Promise<MessageLog> {
  return prisma.messageLog.create({
    data: {
      scheduledMessageId: msg.id,
      runAt: new Date(),
      status: "SENDING",
      remoteJid: msg.recipientJid,
    },
  });
}

async function markLog(msg: FullMessage, log: MessageLog, status: "SENT" | "FAILED", evolutionMessageId?: string, error?: string) {
  const updated = await prisma.messageLog.update({
    where: { id: log.id },
    data: {
      status,
      evolutionMessageId: evolutionMessageId ?? null,
      error: error ?? null,
      ...(status === "SENT" ? { sentAt: new Date() } : {}),
    },
  });
  broadcast(msg.userId, "log.updated", logDTO(updated));
  return updated;
}

const errMsg = (e: unknown) => (e instanceof Error ? e.message : String(e)).slice(0, 500);

async function sendOne(msg: FullMessage): Promise<void> {
  const state = await evolution.cachedState(msg.instance.instanceName).catch(() => "close");
  if (state !== "open") {
    // sin log por intento: no hubo envío real (SPEC §7); el error queda en lastError
    await onOccurrenceFailure(msg, "INSTANCIA_DESCONECTADA");
    return;
  }

  const key = decrypt(msg.instance.tokenEnc);
  const log = await createLog(msg);
  try {
    const res =
      msg.type === "TEXT"
        ? await evolution.sendText(msg.instance.instanceName, key, {
            number: msg.recipientJid, // regla §5.2: usar el jid guardado tal cual
            text: renderVariables(msg.body ?? "", msg),
            delay: 1800,
          })
        : msg.type === "AUDIO"
          ? await evolution.sendAudio(msg.instance.instanceName, key, await buildAudioPayload(msg))
          : await evolution.sendMedia(msg.instance.instanceName, key, await buildMediaPayload(msg));
    const keyId: string | undefined = res?.key?.id ?? res?.response?.key?.id;
    await markLog(msg, log, "SENT", keyId);
    await onOccurrenceSuccess(msg);
    if (msg.user.notifyOnSent) {
      const local = DateTime.now().setZone(msg.timezone).setLocale("es").toFormat("h:mm a");
      await ntfyPublish(msg.user, {
        title: "Mensaje enviado",
        message: `Enviado a ${msg.recipientName} · ${local}`,
        priority: 3,
        tags: ["white_check_mark"],
      });
    }
  } catch (e) {
    await markLog(msg, log, "FAILED", undefined, errMsg(e));
    await onOccurrenceFailure(msg, errMsg(e));
  }
}

let running = false;

export async function tick(): Promise<void> {
  if (running) return; // nunca dos ticks solapados
  running = true;
  try {
    const ids = await claimDue(10);
    if (!ids.length) return;
    const msgs = await prisma.scheduledMessage.findMany({
      where: { id: { in: ids } },
      include: { instance: true, user: true },
      orderBy: { nextRunAt: "asc" },
    });
    for (const [i, msg] of msgs.entries()) {
      await sleep(i === 0 ? 0 : 3000 + rand(0, 9000)); // jitter anti-ban entre mensajes del mismo tick
      await sendOne(msg as FullMessage);
    }
  } catch (err) {
    console.error("scheduler tick failed", err);
  } finally {
    running = false;
  }
}

// Ciclo de vida de media: los archivos suben ANTES de crear el mensaje. Se borran cuando
// ya no los necesita ningún mensaje: huérfanos (nunca adjuntados) a las 24 h; los usados,
// 7 días después de que todos sus mensajes terminen (COMPLETED/CANCELLED/FAILED) — margen
// para duplicar un mensaje reciente sin perder el adjunto.
async function cleanupMedia() {
  try {
    const media = await prisma.media.findMany();
    const now = Date.now();
    for (const m of media) {
      const refs = await prisma.scheduledMessage.findMany({
        where: { mediaId: m.id },
        select: { status: true, updatedAt: true },
      });
      let remove = false;
      if (refs.length === 0) {
        remove = m.createdAt.getTime() < now - 24 * 3600_000;
      } else if (!refs.some((r) => r.status === "ACTIVE" || r.status === "PAUSED")) {
        const newest = Math.max(...refs.map((r) => r.updatedAt.getTime()));
        remove = newest < now - 7 * 24 * 3600_000;
      }
      if (remove) {
        await deleteMediaFile(m);
        await prisma.media.delete({ where: { id: m.id } });
      }
    }
  } catch (err) {
    console.warn("media cleanup failed", err);
  }
}

async function cleanupRawWebhooks() {
  // WebhookEventRaw es solo para calibrar el mapeo — limpieza a 7 días (SPEC §4)
  await prisma.webhookEventRaw
    .deleteMany({ where: { createdAt: { lt: new Date(Date.now() - 7 * 24 * 3600 * 1000) } } })
    .catch((err) => console.warn("webhook cleanup failed", err));
}

export function start() {
  void tick(); // ejecución inmediata al arrancar
  setInterval(() => void tick(), TICK_MS).unref();
  void cleanupRawWebhooks();
  void cleanupMedia();
  void cleanupAutoReplyHits();
  void cleanupChatMessages();
  setInterval(() => {
    void cleanupRawWebhooks();
    void cleanupMedia();
    void cleanupAutoReplyHits();
    void cleanupChatMessages();
  }, 24 * 3600 * 1000).unref();
}
