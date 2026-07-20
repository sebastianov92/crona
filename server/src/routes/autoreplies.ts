import type { FastifyInstance } from "fastify";
import { z } from "zod";
import type { AutoReply } from "@prisma/client";
import { prisma } from "../db.js";
import { authenticate } from "../plugins/auth.js";
import { errors } from "../lib/errors.js";
import { evolution } from "../services/evolution.js";
import { config } from "../config.js";

const autoReplyDTO = (r: AutoReply) => ({
  id: r.id,
  instanceId: r.instanceId,
  action: r.action,
  contactJid: r.contactJid,
  contactName: r.contactName,
  keyword: r.keyword,
  replyText: r.replyText,
  activeFromHour: r.activeFromHour,
  activeToHour: r.activeToHour,
  timezone: r.timezone,
  cooldownMinutes: r.cooldownMinutes,
  enabled: r.enabled,
  createdAt: r.createdAt,
});

const BaseBody = z.object({
  instanceId: z.string().uuid(),
  action: z.enum(["REPLY", "NOTIFY"]).default("REPLY"),
  contactJid: z.string().min(3).nullable().optional(),
  contactName: z.string().min(1).nullable().optional(),
  keyword: z.string().min(1).max(100).nullable().optional(),
  replyText: z.string().min(1).max(4096).nullable().optional(),
  activeFromHour: z.number().int().min(0).max(23).nullable().optional(),
  activeToHour: z.number().int().min(0).max(23).nullable().optional(),
  timezone: z.string().default("America/Guayaquil"),
  cooldownMinutes: z.number().int().min(1).max(1440).default(60),
  enabled: z.boolean().default(true),
});

const Body = BaseBody.refine((b) => b.action !== "REPLY" || (b.replyText ?? "").trim().length > 0, {
  message: "La respuesta automática necesita un texto de respuesta.",
});

// Suscribir MESSAGES_UPSERT en el webhook de la instancia (las creadas antes de esta feature no lo tenían)
async function ensureUpsertWebhook(instanceName: string) {
  const url = `${config.INTERNAL_URL}/webhooks/evolution/${config.WEBHOOK_SECRET}`;
  await evolution
    .setWebhook(instanceName, url, [
      "QRCODE_UPDATED",
      "CONNECTION_UPDATE",
      "MESSAGES_UPDATE",
      "MESSAGES_UPSERT",
      "SEND_MESSAGE",
    ])
    .catch((err) => console.warn("setWebhook failed", err));
}

export function registerAutoReplyRoutes(app: FastifyInstance) {
  app.get("/autoreplies", { preHandler: authenticate }, async (req) => {
    const items = await prisma.autoReply.findMany({
      where: { userId: req.userId },
      orderBy: { createdAt: "asc" },
    });
    return { items: items.map(autoReplyDTO), nextCursor: null };
  });

  app.post("/autoreplies", { preHandler: authenticate }, async (req, reply) => {
    const body = Body.parse(req.body);
    const instance = await prisma.instance.findFirst({ where: { id: body.instanceId, userId: req.userId } });
    if (!instance) throw errors.notFound("La instancia");
    const rule = await prisma.autoReply.create({
      data: { ...body, userId: req.userId },
    });
    await ensureUpsertWebhook(instance.instanceName);
    return reply.status(201).send(autoReplyDTO(rule));
  });

  app.patch("/autoreplies/:id", { preHandler: authenticate }, async (req) => {
    const { id } = req.params as { id: string };
    const existing = await prisma.autoReply.findFirst({ where: { id, userId: req.userId } });
    if (!existing) throw errors.notFound("La regla");
    const body = BaseBody.partial().parse(req.body);
    delete (body as Record<string, unknown>).instanceId; // la instancia no se cambia
    const rule = await prisma.autoReply.update({ where: { id }, data: body });
    return autoReplyDTO(rule);
  });

  app.delete("/autoreplies/:id", { preHandler: authenticate }, async (req) => {
    const { id } = req.params as { id: string };
    const existing = await prisma.autoReply.findFirst({ where: { id, userId: req.userId } });
    if (!existing) throw errors.notFound("La regla");
    await prisma.autoReply.delete({ where: { id } });
    return { ok: true };
  });
}
