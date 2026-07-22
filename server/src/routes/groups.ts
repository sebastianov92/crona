import type { FastifyInstance } from "fastify";
import { z } from "zod";
import { prisma } from "../db.js";
import { authenticate } from "../plugins/auth.js";
import { errors } from "../lib/errors.js";
import { groupTick } from "../services/groups.js";

// Creación de grupos de WhatsApp: inmediata o programada (switch en la app).

const groupDTO = (g: {
  id: string;
  instanceId: string;
  name: string;
  pictureMediaId: string | null;
  participants: unknown;
  runAt: Date;
  status: string;
  groupJid: string | null;
  lastError: string | null;
  createdAt: Date;
  parts?: { order: number; body: string; typingMs: number | null }[];
}) => ({
  id: g.id,
  instanceId: g.instanceId,
  name: g.name,
  pictureMediaId: g.pictureMediaId,
  participants: g.participants,
  runAt: g.runAt,
  status: g.status,
  groupJid: g.groupJid,
  lastError: g.lastError,
  createdAt: g.createdAt,
  parts: [...(g.parts ?? [])].sort((a, b) => a.order - b.order).map((p) => ({ body: p.body, typingMs: p.typingMs })),
});

export function registerGroupRoutes(app: FastifyInstance) {
  app.get("/groups", { preHandler: authenticate }, async (req) => {
    const items = await prisma.groupCreation.findMany({
      where: { userId: req.userId },
      orderBy: { createdAt: "desc" },
      take: 50,
      include: { parts: true },
    });
    return { items: items.map(groupDTO), nextCursor: null };
  });

  const CreateBody = z.object({
    instanceId: z.string().uuid(),
    name: z.string().min(1).max(80),
    pictureMediaId: z.string().uuid().nullable().optional(),
    participants: z
      .array(z.object({ jid: z.string().min(3), name: z.string().optional() }))
      .min(1)
      .max(256),
    // mensaje inicial (opcional): una o varias partes, cada una con su tiempo de escritura
    parts: z
      .array(
        z.object({
          body: z.string().min(1).max(4096),
          typingMs: z.number().int().min(500).max(25_000).nullable().optional(),
        }),
      )
      .max(10)
      .default([]),
    // null/ausente = crear ya; con fecha = programado
    scheduledAt: z.coerce.date().nullable().optional(),
  });

  app.post("/groups", { preHandler: authenticate }, async (req, reply) => {
    const body = CreateBody.parse(req.body);
    const inst = await prisma.instance.findFirst({ where: { id: body.instanceId, userId: req.userId } });
    if (!inst) throw errors.notFound("La instancia");
    if (body.pictureMediaId) {
      const media = await prisma.media.findFirst({ where: { id: body.pictureMediaId, userId: req.userId } });
      if (!media) throw errors.notFound("La foto del grupo");
    }
    if (body.scheduledAt && body.scheduledAt.getTime() < Date.now() + 60_000) {
      throw errors.validation("La fecha de creación debe ser al menos 1 minuto en el futuro.");
    }

    const created = await prisma.groupCreation.create({
      data: {
        userId: req.userId,
        instanceId: body.instanceId,
        name: body.name.trim(),
        pictureMediaId: body.pictureMediaId ?? null,
        participants: body.participants,
        runAt: body.scheduledAt ?? new Date(),
        parts: {
          create: body.parts.map((p, i) => ({ order: i, body: p.body, typingMs: p.typingMs ?? null })),
        },
      },
      include: { parts: true },
    });

    if (!body.scheduledAt) void groupTick(); // "al instante": no esperar al siguiente ciclo
    return reply.status(201).send(groupDTO(created));
  });

  app.delete("/groups/:id", { preHandler: authenticate }, async (req) => {
    const { id } = req.params as { id: string };
    const gc = await prisma.groupCreation.findFirst({ where: { id, userId: req.userId } });
    if (!gc) throw errors.notFound("La creación de grupo");
    if (gc.status === "CREATING") throw errors.validation("El grupo se está creando ahora mismo.");
    await prisma.groupCreation.delete({ where: { id } });
    return { ok: true };
  });
}
