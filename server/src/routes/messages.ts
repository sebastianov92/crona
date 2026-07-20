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

const MIN_LEAD_MS = 60_000; // scheduledAt mínimo now()+60s

const RecurrenceEnum = z.enum(["NONE", "DAILY", "WEEKLY", "MONTHLY", "YEARLY"]);

const CreateBody = z.object({
  instanceId: z.string().uuid(),
  recipient: z.object({
    jid: z.string().min(3),
    name: z.string().min(1),
    kind: z.enum(["CONTACT", "GROUP"]),
    pictureUrl: z.string().nullable().optional(),
  }),
  type: z.enum(["TEXT", "IMAGE", "VIDEO", "DOCUMENT"]),
  body: z.string().max(4096).nullable().optional(),
  mediaId: z.string().uuid().nullable().optional(),
  scheduledAt: z.coerce.date(),
  timezone: z.string().default("America/Guayaquil"),
  recurrence: RecurrenceEnum.default("NONE"),
  recurrenceDays: z.array(z.number().int().min(1).max(7)).default([]),
  recurrenceUntil: z.coerce.date().nullable().optional(),
  randomDelay: z.boolean().default(false),
});

function validateContent(input: {
  type: string;
  body?: string | null;
  mediaId?: string | null;
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
  if (input.type !== "TEXT" && !input.mediaId) {
    throw errors.validation("Los mensajes con foto, video o documento necesitan un archivo adjunto.");
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
        timezone: body.timezone,
        scheduledAt: body.scheduledAt,
        recurrence: body.recurrence,
        recurrenceDays: body.recurrenceDays,
        recurrenceUntil: body.recurrenceUntil ?? null,
        randomDelay: body.randomDelay,
        nextRunAt: body.scheduledAt,
      },
    });
    broadcast(req.userId, "message.updated", messageDTO(msg));
    return reply.status(201).send(messageDTO(msg));
  });

  app.get("/messages/:id", { preHandler: authenticate }, async (req) => {
    const { id } = req.params as { id: string };
    const msg = await ownMessage(req.userId, id);
    const logs = await prisma.messageLog.findMany({
      where: { scheduledMessageId: msg.id },
      orderBy: { runAt: "desc" },
    });
    return { message: messageDTO(msg), logs: logs.map(logDTO) };
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
      recurrence: patch.recurrence ?? msg.recurrence,
      recurrenceDays: patch.recurrenceDays ?? msg.recurrenceDays,
      scheduledAt: patch.scheduledAt,
    };
    validateContent(merged);
    if (patch.mediaId) await assertOwnMedia(req.userId, patch.mediaId);

    const updated = await prisma.scheduledMessage.update({
      where: { id: msg.id },
      data: {
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
    const copy = await prisma.scheduledMessage.create({
      data: {
        userId: req.userId,
        instanceId: msg.instanceId,
        recipientJid: msg.recipientJid,
        recipientName: msg.recipientName,
        recipientKind: msg.recipientKind,
        recipientPictureUrl: msg.recipientPictureUrl,
        type: msg.type,
        body: msg.body,
        mediaId: msg.mediaId,
        timezone: msg.timezone,
        scheduledAt,
        recurrence: msg.recurrence,
        recurrenceDays: msg.recurrenceDays,
        recurrenceUntil: msg.recurrenceUntil,
        nextRunAt: scheduledAt,
        status: "PAUSED",
      },
    });
    broadcast(req.userId, "message.updated", messageDTO(copy));
    return reply.status(201).send(messageDTO(copy));
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
