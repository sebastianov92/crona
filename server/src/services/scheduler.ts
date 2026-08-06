import type { Instance, MessageLog, ScheduledMessage, User } from "@prisma/client";
import { DateTime } from "luxon";
import { prisma } from "../db.js";
import { evolution } from "./evolution.js";
import { decrypt } from "./crypto.js";
import { nextOccurrence } from "./recurrence.js";
import { ntfyPublish } from "./ntfy.js";
import { broadcast } from "../ws/hub.js";
import { messageDTO, logDTO } from "../lib/message-dto.js";
import { buildAudioPayload, buildMediaPayload, buildStickerPayload, deleteMediaFile } from "./media.js";
import { cleanupAutoReplyHits, cleanupChatMessages } from "./autoreply.js";
import { groupTick, recoverGroupsOnBoot } from "./groups.js";
import { renderVariables } from "../lib/variables.js";
import { instanceDTO } from "../routes/instances.js";

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
  // Variación aleatoria configurable por instancia (default 60–300 s = el antiguo +1–5 min).
  const minMs = Math.max(0, msg.instance.jitterMinSec) * 1000;
  const maxMs = Math.max(msg.instance.jitterMinSec, msg.instance.jitterMaxSec) * 1000;
  return new Date(next.getTime() + minMs + rand(0, Math.max(1, maxMs - minMs)));
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

async function onOccurrenceFailure(msg: FullMessage, rawErr: string) {
  const info = classifySendError(rawErr);
  const errText = info.message; // se guarda ya legible en lastError
  const attempts = msg.attempts + 1;

  // Sesión cerrada: marcar la instancia caída para que se vea en toda la app.
  if (info.sessionClosed && msg.instance.status !== "DISCONNECTED") {
    const inst = await prisma.instance
      .update({ where: { id: msg.instanceId }, data: { status: "DISCONNECTED" } })
      .catch(() => null);
    if (inst) broadcast(msg.userId, "instance.updated", instanceDTO(inst));
  }

  // Reintentar solo si NO es un error definitivo (número inválido, sesión cerrada, adjunto malo).
  if (!info.definitive && attempts < MAX_ATTEMPTS) {
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

  // Sin más reintentos: aviso por ntfy (distinto si fue sesión cerrada).
  await ntfyPublish(
    msg.user,
    info.sessionClosed
      ? {
          title: "WhatsApp desconectado",
          message: `No se envió a ${msg.recipientName}: la sesión se cerró. Ábrela en Crona y re-escanea el QR.`,
          priority: 5,
          tags: ["electric_plug"],
        }
      : {
          title: "Mensaje no enviado",
          message: `No se envió a ${msg.recipientName}: ${errText}`,
          priority: 4,
          tags: ["x"],
        },
  );

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

/// Traduce un error crudo de Evolution/Baileys a algo legible + banderas de decisión:
/// `definitive` = no vale reintentar; `sessionClosed` = la sesión de WhatsApp se cerró/cayó.
type SendErrorInfo = { message: string; definitive: boolean; sessionClosed: boolean };
function classifySendError(raw: string): SendErrorInfo {
  const low = raw.toLowerCase();
  if (/respondió 401|respondió 403|unauthorized|forbidden|not connected|connection closed|instancia_desconectada|logged out|loggedout|\bconflict\b|replaced|precondition/.test(low)) {
    return { message: "Tu WhatsApp está desconectado o la sesión se cerró. Ábrela en Crona y re-escanea el QR.", definitive: true, sessionClosed: true };
  }
  if (/exists.*false|"exists":false|not.*on.*whatsapp|no está en whatsapp|invalid.*(jid|number)|number does not exist|bad jid/.test(low)) {
    return { message: "Ese número no está en WhatsApp o no es válido.", definitive: true, sessionClosed: false };
  }
  if (/must be a url or base64|owned media|unsupported|mimetype|media.*(url|base64)|archivo/.test(low)) {
    return { message: "No se pudo enviar el archivo adjunto (formato o tamaño no válido).", definitive: true, sessionClosed: false };
  }
  if (/rate|too many|429|flood|spam/.test(low)) {
    return { message: "WhatsApp está limitando los envíos. Se reintentará más tarde.", definitive: false, sessionClosed: false };
  }
  if (/timeout|unreachable|econn|network|fetch failed|no se pudo conectar|socket/.test(low)) {
    return { message: "No se pudo contactar al servidor de WhatsApp. Se reintentará.", definitive: false, sessionClosed: false };
  }
  return { message: "No se pudo enviar el mensaje. " + raw.replace(/^Evolution API respondió \d+:\s*/i, "").slice(0, 160), definitive: false, sessionClosed: false };
}

/// Envía una parte concreta y devuelve el id de Evolution.
/// `part` null = la parte 0 (los campos del propio ScheduledMessage).
async function sendPart(
  msg: FullMessage,
  key: string,
  part: { type: string; body: string | null; mediaId: string | null; typingMs: number | null } | null,
): Promise<string | undefined> {
  const type = part ? part.type : msg.type;
  const body = part ? part.body : msg.body;
  const delay = (part ? part.typingMs : msg.typingMs) ?? 1800; // "escribiendo…" el tiempo real de redacción
  // buildMediaPayload/buildAudioPayload leen del mensaje: para partes con adjunto propio
  // se les pasa una copia con el mediaId y el texto de esa parte
  const asMessage = part
    ? ({ ...msg, type: part.type, body: part.body, mediaId: part.mediaId, typingMs: part.typingMs } as FullMessage)
    : msg;

  const res =
    type === "TEXT"
      ? await evolution.sendText(msg.instance.instanceName, key, {
          number: msg.recipientJid, // regla §5.2: usar el jid guardado tal cual
          text: renderVariables(body ?? "", msg),
          delay,
          linkPreview: true, // muestra vista previa de enlaces
        })
      : type === "AUDIO"
        ? await evolution.sendAudio(msg.instance.instanceName, key, await buildAudioPayload(asMessage))
        : type === "STICKER"
          ? await evolution.sendSticker(msg.instance.instanceName, key, await buildStickerPayload(asMessage))
          : await evolution.sendMedia(msg.instance.instanceName, key, await buildMediaPayload(asMessage));

  return res?.key?.id ?? res?.response?.key?.id;
}

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
    const keyId = await sendPart(msg, key, null);

    // Split: el resto de partes salen seguidas, con pausa aleatoria de 0.5-1 s entre cada una
    // (cada parte muestra su propio "escribiendo…" antes de enviarse).
    const parts = await prisma.messagePart.findMany({
      where: { messageId: msg.id },
      orderBy: { order: "asc" },
    });
    for (const p of parts) {
      await sleep(500 + rand(0, 500));
      await sendPart(msg, key, p);
    }

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
    const raw = errMsg(e);
    await markLog(msg, log, "FAILED", undefined, classifySendError(raw).message);
    await onOccurrenceFailure(msg, raw);
  }
}

/// Envelope anti-baneo por instancia: si el mensaje no debe salir AÚN, devuelve la fecha a la
/// que diferirlo (sin enviar ni marcar fallo). null = puede enviarse ya.
/// Combina horas de silencio, caudal por hora (dripping) y tope diario; toma el más tardío.
async function deferUntil(msg: FullMessage): Promise<Date | null> {
  const inst = msg.instance;
  const now = new Date();
  const local = DateTime.fromJSDate(now, { zone: msg.timezone });
  let deferMs = 0;
  const bump = (d: DateTime) => { deferMs = Math.max(deferMs, d.toMillis()); };

  // 1. Horas de silencio (en la zona horaria del mensaje)
  if (inst.quietStart != null && inst.quietEnd != null && inst.quietStart !== inst.quietEnd) {
    const minute = local.hour * 60 + local.minute;
    const inQuiet =
      inst.quietStart < inst.quietEnd
        ? minute >= inst.quietStart && minute < inst.quietEnd
        : minute >= inst.quietStart || minute < inst.quietEnd; // cruza medianoche
    if (inQuiet) {
      let end = local.set({
        hour: Math.floor(inst.quietEnd / 60),
        minute: inst.quietEnd % 60,
        second: 0,
        millisecond: 0,
      });
      if (end <= local) end = end.plus({ days: 1 });
      bump(end.plus({ seconds: rand(0, 120) })); // jitter: no reanudar todos a la hora exacta
    }
  }

  // 2. Caudal por hora (dripping: espaciado mínimo entre envíos de la instancia)
  if (inst.maxPerHour != null && inst.maxPerHour > 0) {
    const spacingSec = Math.ceil(3600 / inst.maxPerHour);
    const last = await prisma.messageLog.findFirst({
      where: { status: "SENT", scheduledMessage: { instanceId: inst.id } },
      orderBy: { sentAt: "desc" },
      select: { sentAt: true },
    });
    if (last?.sentAt) {
      const nextSlot = DateTime.fromJSDate(last.sentAt).plus({ seconds: spacingSec });
      if (nextSlot > local) bump(nextSlot);
    }
  }

  // 3. Tope diario (por día natural en la zona horaria del mensaje)
  if (inst.maxPerDay != null && inst.maxPerDay > 0) {
    const startOfDay = local.startOf("day").toJSDate();
    const count = await prisma.messageLog.count({
      where: { status: "SENT", sentAt: { gte: startOfDay }, scheduledMessage: { instanceId: inst.id } },
    });
    if (count >= inst.maxPerDay) {
      bump(local.plus({ days: 1 }).startOf("day").plus({ minutes: rand(0, 30) }));
    }
  }

  return deferMs > now.getTime() ? new Date(deferMs) : null;
}

let running = false;

export async function tick(): Promise<void> {
  if (running) return; // nunca dos ticks solapados
  running = true;
  try {
    // 25 por tick: una lista se envía completa en secuencia (escribiendo → envía → pausa 3-9 s)
    // dentro del mismo ciclo; `running` garantiza que nunca hay dos envíos en paralelo.
    const ids = await claimDue(25);
    if (!ids.length) return;
    const msgs = await prisma.scheduledMessage.findMany({
      where: { id: { in: ids } },
      include: { instance: true, user: true },
      orderBy: { nextRunAt: "asc" },
    });
    let sentAny = false; // espaciar 3-9 s solo ENTRE envíos reales (no tras un diferido)
    for (const msg of msgs) {
      const deferTo = await deferUntil(msg as FullMessage);
      if (deferTo) {
        const updated = await prisma.scheduledMessage.update({
          where: { id: msg.id },
          data: { nextRunAt: deferTo, claimedAt: null },
        });
        broadcast(msg.userId, "message.updated", messageDTO(updated));
        continue;
      }
      if (sentAny) await sleep(3000 + rand(0, 6000)); // 3-9 s entre mensajes (anti-ban, ritmo de listas)
      await sendOne(msg as FullMessage);
      sentAny = true;
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
      // Media referenciado por algo que NO es el mediaId raíz de un ScheduledMessage NUNCA es
      // huérfano: stickers del buzón, partes de un split, foto de un grupo por crear, o la foto
      // de grupo por defecto del usuario. (Antes solo se contaban ScheduledMessage.mediaId, así
      // que estos medios se borraban a las 24 h y el sticker/parte desaparecía por cascade.)
      const [stickerRefs, partRefs, groupRefs, userRefs, tplRefs] = await Promise.all([
        prisma.stickerAsset.count({ where: { mediaId: m.id } }),
        prisma.messagePart.count({ where: { mediaId: m.id } }),
        prisma.groupCreation.count({ where: { pictureMediaId: m.id } }),
        prisma.user.count({ where: { defaultGroupPictureMediaId: m.id } }),
        prisma.templatePart.count({ where: { mediaId: m.id } }),
      ]);
      if (stickerRefs + partRefs + groupRefs + userRefs + tplRefs > 0) continue;

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

// Respaldo del webhook connection.update: si Evolution no avisó (reinicio del contenedor,
// webhook perdido), detecta una instancia caída consultando su estado y avisa por WS + ntfy,
// para que el usuario no descubra la desconexión recién cuando ya falló un envío.
async function watchConnections() {
  try {
    const insts = await prisma.instance.findMany({
      where: { status: "CONNECTED" },
      include: { user: true },
    });
    for (const inst of insts) {
      let state: string | null;
      try {
        const res = await evolution.state(inst.instanceName);
        state = res?.instance?.state ?? "close";
      } catch {
        state = null; // Evolution no respondió: no marcar caída por un fallo puntual
      }
      if (state === null || state === "open") continue;
      evolution.invalidateStateCache(inst.instanceName);
      const status = state === "connecting" ? "CONNECTING" : "DISCONNECTED";
      const updated = await prisma.instance.update({ where: { id: inst.id }, data: { status } });
      broadcast(inst.userId, "instance.updated", instanceDTO(updated));
      if (status === "DISCONNECTED") {
        await ntfyPublish(inst.user, {
          title: "WhatsApp desconectado",
          message: `WhatsApp (${inst.name}) se desconectó. Ábrela en Crona y re-escanea el QR`,
          priority: 4,
          tags: ["electric_plug"],
        });
      }
    }
  } catch (err) {
    console.warn("watch connections failed", err);
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
  // creación de grupos: ciclo propio y más frecuente (los "al instante" no deben esperar 30 s)
  void recoverGroupsOnBoot().then(() => groupTick());
  setInterval(() => void groupTick(), 5_000).unref();
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
  // Vigilancia de conexión: cada 3 min, respaldo del webhook para no perder una caída.
  setInterval(() => void watchConnections(), 3 * 60_000).unref();
}
