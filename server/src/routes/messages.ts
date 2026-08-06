import type { FastifyInstance } from "fastify";
import { z } from "zod";
import type { Prisma, ScheduledMessage } from "@prisma/client";
import { prisma } from "../db.js";
import { authenticate } from "../plugins/auth.js";
import { errors } from "../lib/errors.js";
import { messageDTO, logDTO, historyItemDTO } from "../lib/message-dto.js";
import { encodeCursor, decodeCursor } from "../lib/pagination.js";
import { broadcast } from "../ws/hub.js";
import { tick } from "../services/scheduler.js";
import { evolution } from "../services/evolution.js";
import { decrypt } from "../services/crypto.js";

const MIN_LEAD_MS = 60_000; // scheduledAt mínimo now()+60s

const RecurrenceEnum = z.enum(["NONE", "DAILY", "WEEKLY", "MONTHLY", "YEARLY"]);

const MSG_TYPES = ["TEXT", "IMAGE", "VIDEO", "DOCUMENT", "AUDIO", "STICKER", "POLL", "LOCATION", "CONTACT"] as const;
const NEEDS_MEDIA = new Set<string>(["IMAGE", "VIDEO", "DOCUMENT", "AUDIO", "STICKER"]);

// Payload de tipos especiales (F4): encuesta / ubicación / contacto / menciones.
const ExtraInput = z
  .object({
    question: z.string().max(300).optional(),
    options: z.array(z.string().min(1).max(100)).max(12).optional(),
    multiple: z.boolean().optional(),
    latitude: z.number().min(-90).max(90).optional(),
    longitude: z.number().min(-180).max(180).optional(),
    name: z.string().max(200).optional(),
    address: z.string().max(300).optional(),
    fullName: z.string().max(200).optional(),
    phone: z.string().max(20).optional(),
    mentions: z.array(z.string()).max(256).optional(),
  })
  .nullable()
  .optional();

const CreateBody = z.object({
  instanceId: z.string().uuid(),
  recipient: z.object({
    jid: z.string().min(3),
    name: z.string().min(1),
    kind: z.enum(["CONTACT", "GROUP"]),
    pictureUrl: z.string().nullable().optional(),
  }),
  type: z.enum(MSG_TYPES),
  body: z.string().max(4096).nullable().optional(),
  mediaId: z.string().uuid().nullable().optional(),
  extra: ExtraInput,
  scheduledAt: z.coerce.date(),
  timezone: z.string().default("America/Guayaquil"),
  recurrence: RecurrenceEnum.default("NONE"),
  recurrenceDays: z.array(z.number().int().min(1).max(7)).default([]),
  recurrenceUntil: z.coerce.date().nullable().optional(),
  randomDelay: z.boolean().default(false),
  // cuánto tardó el usuario redactando: se muestra "escribiendo…/grabando audio…" ese tiempo antes de enviar
  typingMs: z.number().int().min(500).max(25_000).nullable().optional(),
  // Split: partes ADICIONALES (la primera son los campos de arriba). Se envían seguidas,
  // con pausa de 1-3 s entre cada una y su propio "escribiendo…".
  parts: z
    .array(
      z.object({
        type: z.enum(MSG_TYPES).default("TEXT"),
        body: z.string().max(4096).nullable().optional(),
        mediaId: z.string().uuid().nullable().optional(),
        extra: ExtraInput,
        typingMs: z.number().int().min(500).max(25_000).nullable().optional(),
      }),
    )
    .max(9)
    .default([]),
});

type ExtraData = z.infer<typeof ExtraInput>;

function validateContent(input: {
  type: string;
  body?: string | null;
  mediaId?: string | null;
  extra?: ExtraData;
  recurrence: string;
  recurrenceDays: number[];
  scheduledAt?: Date;
}) {
  if (input.scheduledAt && input.scheduledAt.getTime() < Date.now() + MIN_LEAD_MS) {
    throw errors.validation("La fecha de envío debe ser al menos 1 minuto en el futuro.");
  }
  if (input.type === "TEXT" && !input.body?.trim()) {
    throw errors.validation("El mensaje de texto no puede estar vacío.");
  }
  if (NEEDS_MEDIA.has(input.type) && !input.mediaId) {
    throw errors.validation("Los mensajes con foto, video, documento, audio o sticker necesitan un archivo adjunto.");
  }
  if (input.type === "POLL") {
    const opts = (input.extra?.options ?? []).filter((o) => o?.trim());
    if (!input.extra?.question?.trim() || opts.length < 2) {
      throw errors.validation("La encuesta necesita una pregunta y al menos 2 opciones.");
    }
  }
  if (input.type === "LOCATION" && (typeof input.extra?.latitude !== "number" || typeof input.extra?.longitude !== "number")) {
    throw errors.validation("La ubicación necesita latitud y longitud.");
  }
  if (input.type === "CONTACT" && !String(input.extra?.phone ?? "").replace(/\D/g, "")) {
    throw errors.validation("El contacto necesita un número.");
  }
  if (input.recurrence === "WEEKLY" && input.recurrenceDays.length === 0) {
    throw errors.validation("La recurrencia semanal necesita al menos un día.");
  }
}

async function ownMessage(userId: string, id: string): Promise<ScheduledMessage> {
  const msg = await prisma.scheduledMessage.findFirst({ where: { id, userId } });
  if (!msg) throw errors.notFound("El mensaje");
  return msg;
}

async function assertOwnMedia(userId: string, mediaId: string) {
  const media = await prisma.media.findFirst({ where: { id: mediaId, userId } });
  if (!media) throw errors.notFound("El archivo adjunto");
}

export function registerMessageRoutes(app: FastifyInstance) {
  app.get("/messages", { preHandler: authenticate }, async (req) => {
    const Query = z.object({
      filter: z.enum(["upcoming", "history"]).default("upcoming"),
      cursor: z.string().optional(),
      limit: z.coerce.number().min(1).max(100).default(50),
    });
    const q = Query.parse(req.query);
    const cursorId = decodeCursor(q.cursor);

    if (q.filter === "upcoming") {
      const rows = await prisma.scheduledMessage.findMany({
        where: { userId: req.userId, status: { in: ["ACTIVE", "PAUSED"] } },
        include: { parts: true },
        orderBy: [{ nextRunAt: "asc" }, { id: "asc" }],
        take: q.limit + 1,
        ...(cursorId ? { cursor: { id: cursorId }, skip: 1 } : {}),
      });
      const page = rows.slice(0, q.limit);
      return {
        items: page.map(messageDTO),
        nextCursor: rows.length > q.limit ? encodeCursor(page[page.length - 1].id) : null,
      };
    }

    const rows = await prisma.messageLog.findMany({
      where: { scheduledMessage: { userId: req.userId } },
      include: { scheduledMessage: true },
      orderBy: [{ runAt: "desc" }, { id: "asc" }],
      take: q.limit + 1,
      ...(cursorId ? { cursor: { id: cursorId }, skip: 1 } : {}),
    });
    const page = rows.slice(0, q.limit);
    return {
      items: page.map(historyItemDTO),
      nextCursor: rows.length > q.limit ? encodeCursor(page[page.length - 1].id) : null,
    };
  });

  app.post("/messages", { preHandler: authenticate }, async (req, reply) => {
    const body = CreateBody.parse(req.body);
    validateContent(body);

    // el recipient.jid debe pertenecer a una instancia del usuario
    const instance = await prisma.instance.findFirst({ where: { id: body.instanceId, userId: req.userId } });
    if (!instance) throw errors.notFound("La instancia");
    if (body.mediaId) await assertOwnMedia(req.userId, body.mediaId);
    for (const p of body.parts) {
      validateContent({ type: p.type, body: p.body, mediaId: p.mediaId, extra: p.extra, recurrence: "NONE", recurrenceDays: [] });
      if (p.mediaId) await assertOwnMedia(req.userId, p.mediaId);
    }

    const msg = await prisma.scheduledMessage.create({
      data: {
        userId: req.userId,
        instanceId: instance.id,
        recipientJid: body.recipient.jid,
        recipientName: body.recipient.name,
        recipientKind: body.recipient.kind,
        recipientPictureUrl: body.recipient.pictureUrl ?? null,
        type: body.type,
        body: body.body ?? null,
        mediaId: body.mediaId ?? null,
        extra: body.extra ?? undefined,
        timezone: body.timezone,
        scheduledAt: body.scheduledAt,
        recurrence: body.recurrence,
        recurrenceDays: body.recurrenceDays,
        recurrenceUntil: body.recurrenceUntil ?? null,
        randomDelay: body.randomDelay,
        typingMs: body.typingMs ?? null,
        nextRunAt: body.scheduledAt,
        parts: {
          create: body.parts.map((p, i) => ({
            order: i + 1, // la 0 es el propio mensaje
            type: p.type,
            body: p.body ?? null,
            mediaId: p.mediaId ?? null,
            extra: p.extra ?? undefined,
            typingMs: p.typingMs ?? null,
          })),
        },
      },
      include: { parts: true },
    });
    broadcast(req.userId, "message.updated", messageDTO(msg));
    return reply.status(201).send(messageDTO(msg));
  });

  app.get("/messages/:id", { preHandler: authenticate }, async (req) => {
    const { id } = req.params as { id: string };
    const msg = await ownMessage(req.userId, id);
    const [full, logs] = await Promise.all([
      prisma.scheduledMessage.findUnique({ where: { id: msg.id }, include: { parts: true } }),
      prisma.messageLog.findMany({ where: { scheduledMessageId: msg.id }, orderBy: { runAt: "desc" } }),
    ]);
    return { message: messageDTO(full ?? msg), logs: logs.map(logDTO) };
  });

  const PatchBody = z.object({
    body: z.string().max(4096).nullable().optional(),
    mediaId: z.string().uuid().nullable().optional(),
    scheduledAt: z.coerce.date().optional(),
    timezone: z.string().optional(),
    recurrence: RecurrenceEnum.optional(),
    recurrenceDays: z.array(z.number().int().min(1).max(7)).optional(),
    recurrenceUntil: z.coerce.date().nullable().optional(),
    randomDelay: z.boolean().optional(),
    status: z.enum(["ACTIVE", "PAUSED"]).optional(), // pausar / reanudar
    instanceId: z.string().uuid().optional(), // cambiar desde qué WhatsApp se envía
  });

  app.patch("/messages/:id", { preHandler: authenticate }, async (req) => {
    const { id } = req.params as { id: string };
    const patch = PatchBody.parse(req.body);
    const msg = await ownMessage(req.userId, id);

    // Solo si status ∈ {ACTIVE, PAUSED} y nextRunAt > now()+60s (SPEC §6)
    if (msg.status !== "ACTIVE" && msg.status !== "PAUSED") throw errors.messageNotEditable();
    if (msg.nextRunAt.getTime() <= Date.now() + MIN_LEAD_MS) throw errors.messageNotEditable();

    const merged = {
      type: msg.type,
      body: patch.body !== undefined ? patch.body : msg.body,
      mediaId: patch.mediaId !== undefined ? patch.mediaId : msg.mediaId,
      extra: msg.extra as ExtraData, // conservar el payload especial (encuesta/ubicación/contacto) al posponer/editar
      recurrence: patch.recurrence ?? msg.recurrence,
      recurrenceDays: patch.recurrenceDays ?? msg.recurrenceDays,
      scheduledAt: patch.scheduledAt,
    };
    validateContent(merged);
    if (patch.mediaId) await assertOwnMedia(req.userId, patch.mediaId);
    if (patch.instanceId) {
      const inst = await prisma.instance.findFirst({ where: { id: patch.instanceId, userId: req.userId } });
      if (!inst) throw errors.notFound("La instancia");
    }

    const updated = await prisma.scheduledMessage.update({
      where: { id: msg.id },
      data: {
        ...(patch.instanceId ? { instanceId: patch.instanceId } : {}),
        ...(patch.body !== undefined ? { body: patch.body } : {}),
        ...(patch.mediaId !== undefined ? { mediaId: patch.mediaId } : {}),
        ...(patch.scheduledAt ? { scheduledAt: patch.scheduledAt, nextRunAt: patch.scheduledAt, attempts: 0, lastError: null } : {}),
        ...(patch.timezone ? { timezone: patch.timezone } : {}),
        ...(patch.recurrence ? { recurrence: patch.recurrence } : {}),
        ...(patch.recurrenceDays ? { recurrenceDays: patch.recurrenceDays } : {}),
        ...(patch.recurrenceUntil !== undefined ? { recurrenceUntil: patch.recurrenceUntil } : {}),
        ...(patch.randomDelay !== undefined ? { randomDelay: patch.randomDelay } : {}),
        ...(patch.status ? { status: patch.status } : {}),
      },
    });
    broadcast(req.userId, "message.updated", messageDTO(updated));
    return messageDTO(updated);
  });

  // Pausar todo / reanudar todo (modo vacaciones)
  app.post("/messages/pause-all", { preHandler: authenticate }, async (req) => {
    const Body = z.object({ paused: z.boolean() });
    const { paused } = Body.parse(req.body);
    const result = paused
      ? await prisma.scheduledMessage.updateMany({
          where: { userId: req.userId, status: "ACTIVE" },
          data: { status: "PAUSED", claimedAt: null },
        })
      : await prisma.scheduledMessage.updateMany({
          where: { userId: req.userId, status: "PAUSED" },
          data: { status: "ACTIVE" },
        });
    return { ok: true, changed: result.count };
  });

  // Enviar ahora (ACTIVE/PAUSED) o reintentar (FAILED): programa para ya y dispara un tick
  app.post("/messages/:id/send-now", { preHandler: authenticate }, async (req) => {
    const { id } = req.params as { id: string };
    const msg = await ownMessage(req.userId, id);
    if (!["ACTIVE", "PAUSED", "FAILED"].includes(msg.status)) throw errors.messageNotEditable();
    const updated = await prisma.scheduledMessage.update({
      where: { id: msg.id },
      data: { status: "ACTIVE", nextRunAt: new Date(), attempts: 0, lastError: null, claimedAt: null },
    });
    broadcast(req.userId, "message.updated", messageDTO(updated));
    setImmediate(() => void tick()); // sin esperar los 30 s del intervalo
    return messageDTO(updated);
  });

  app.post("/messages/:id/cancel", { preHandler: authenticate }, async (req) => {
    const { id } = req.params as { id: string };
    const msg = await ownMessage(req.userId, id);
    if (msg.status !== "ACTIVE" && msg.status !== "PAUSED") throw errors.messageNotEditable();
    const updated = await prisma.scheduledMessage.update({
      where: { id: msg.id },
      data: { status: "CANCELLED", claimedAt: null },
    });
    broadcast(req.userId, "message.updated", messageDTO(updated));
    return messageDTO(updated);
  });

  app.post("/messages/:id/duplicate", { preHandler: authenticate }, async (req, reply) => {
    const { id } = req.params as { id: string };
    const msg = await ownMessage(req.userId, id);
    // copia lista para editar: PAUSED para que el worker no la tome antes de ajustar la fecha
    const scheduledAt =
      msg.scheduledAt.getTime() > Date.now() + MIN_LEAD_MS
        ? msg.scheduledAt
        : new Date(Date.now() + 3600_000);
    // el split viaja con la copia: duplicar un mensaje de varias partes debe conservarlas
    const srcParts = await prisma.messagePart.findMany({
      where: { messageId: msg.id },
      orderBy: { order: "asc" },
    });
    const copy = await prisma.scheduledMessage.create({
      data: {
        userId: req.userId,
        parts: {
          create: srcParts.map((p) => ({
            order: p.order,
            type: p.type,
            body: p.body,
            mediaId: p.mediaId,
            extra: p.extra ?? undefined,
            typingMs: p.typingMs,
          })),
        },
        instanceId: msg.instanceId,
        recipientJid: msg.recipientJid,
        recipientName: msg.recipientName,
        recipientKind: msg.recipientKind,
        recipientPictureUrl: msg.recipientPictureUrl,
        type: msg.type,
        body: msg.body,
        mediaId: msg.mediaId,
        extra: msg.extra ?? undefined,
        timezone: msg.timezone,
        scheduledAt,
        recurrence: msg.recurrence,
        recurrenceDays: msg.recurrenceDays,
        recurrenceUntil: msg.recurrenceUntil,
        nextRunAt: scheduledAt,
        status: "PAUSED",
      },
      include: { parts: true },
    });
    broadcast(req.userId, "message.updated", messageDTO(copy));
    return reply.status(201).send(messageDTO(copy));
  });

  // borrar un item del historial (log individual)
  app.delete("/messages/logs/:id", { preHandler: authenticate }, async (req) => {
    const { id } = req.params as { id: string };
    const log = await prisma.messageLog.findFirst({
      where: { id, scheduledMessage: { userId: req.userId } },
    });
    if (!log) throw errors.notFound("El registro");
    await prisma.messageLog.delete({ where: { id } });
    return { ok: true };
  });

  // Eliminar para todos en WhatsApp un mensaje ya enviado (ventana ~2 días).
  app.post("/messages/logs/:id/delete-for-everyone", { preHandler: authenticate }, async (req) => {
    const { id } = req.params as { id: string };
    const log = await prisma.messageLog.findFirst({
      where: { id, scheduledMessage: { userId: req.userId } },
      include: { scheduledMessage: { include: { instance: true } } },
    });
    if (!log) throw errors.notFound("El registro");
    if (!["SENT", "DELIVERED", "READ"].includes(log.status)) {
      throw errors.validation("Solo se puede eliminar un mensaje que se envió correctamente.");
    }
    if (!log.evolutionMessageId) throw errors.validation("Este mensaje no tiene identificador de WhatsApp para eliminarlo.");
    const sent = log.sentAt ?? log.runAt;
    if (Date.now() - sent.getTime() > 2 * 24 * 3600_000) {
      throw errors.validation("Ya pasó el tiempo para eliminarlo para todos (WhatsApp permite ~2 días).");
    }
    const inst = log.scheduledMessage.instance;
    await evolution.deleteForEveryone(inst.instanceName, decrypt(inst.tokenEnc), {
      id: log.evolutionMessageId,
      remoteJid: log.remoteJid,
      fromMe: true,
    });
    return { ok: true };
  });

  app.delete("/messages/:id", { preHandler: authenticate }, async (req) => {
    const { id } = req.params as { id: string };
    const msg = await ownMessage(req.userId, id);
    if (!["CANCELLED", "COMPLETED", "FAILED"].includes(msg.status)) {
      throw errors.validation("Solo se pueden borrar mensajes cancelados, completados o fallidos.");
    }
    await prisma.scheduledMessage.delete({ where: { id: msg.id } });
    return { ok: true };
  });
}
