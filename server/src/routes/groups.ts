import type { FastifyInstance } from "fastify";
import { z } from "zod";
import { prisma } from "../db.js";
import { authenticate } from "../plugins/auth.js";
import { errors } from "../lib/errors.js";
import { groupTick } from "../services/groups.js";
import { evolution } from "../services/evolution.js";
import { decrypt } from "../services/crypto.js";

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
  // type/mediaId: las partes de grupo son texto; se incluyen para que TemplatePart decodifique en la app.
  parts: [...(g.parts ?? [])]
    .sort((a, b) => a.order - b.order)
    .map((p) => ({ type: "TEXT", body: p.body, mediaId: null, typingMs: p.typingMs })),
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

  // --- Gestión de un grupo ya creado (usa el groupJid del GroupCreation DONE) ---

  /// Devuelve la creación con su groupJid + la instancia (con la key desencriptada), validando dueño.
  async function liveGroup(userId: string, id: string) {
    const gc = await prisma.groupCreation.findFirst({ where: { id, userId } });
    if (!gc) throw errors.notFound("El grupo");
    if (!gc.groupJid) throw errors.validation("El grupo aún no se ha creado.");
    const inst = await prisma.instance.findFirst({ where: { id: gc.instanceId, userId } });
    if (!inst) throw errors.notFound("La instancia");
    return { gc, inst, jid: gc.groupJid, key: decrypt(inst.tokenEnc) };
  }
  const linkFor = (code: string) => `https://chat.whatsapp.com/${code}`;
  const inviteCodeOf = (r: any): string =>
    r?.inviteCode ?? r?.code ?? (typeof r?.inviteUrl === "string" ? r.inviteUrl.split("/").pop() : "") ?? "";

  app.get("/groups/:id/invite", { preHandler: authenticate }, async (req) => {
    const { gc, inst, jid, key } = await liveGroup(req.userId, (req.params as { id: string }).id);
    const code = inviteCodeOf(await evolution.groupInviteCode(inst.instanceName, key, jid));
    if (!code) throw errors.validation("No se pudo obtener el enlace del grupo.");
    return { code, link: linkFor(code) };
  });

  app.post("/groups/:id/invite/revoke", { preHandler: authenticate }, async (req) => {
    const { inst, jid, key } = await liveGroup(req.userId, (req.params as { id: string }).id);
    const code = inviteCodeOf(await evolution.groupRevokeInvite(inst.instanceName, key, jid));
    if (!code) throw errors.validation("No se pudo regenerar el enlace.");
    return { code, link: linkFor(code) };
  });

  app.get("/groups/:id/participants", { preHandler: authenticate }, async (req) => {
    const { gc, inst, jid, key } = await liveGroup(req.userId, (req.params as { id: string }).id);
    const r: any = await evolution.groupInfo(inst.instanceName, key, jid);
    const raw: any[] = Array.isArray(r?.participants) ? r.participants : [];
    const participants = raw
      .map((p) => ({ jid: (p.id ?? p.jid ?? "") as string, admin: (p.admin ?? null) as string | null }))
      .filter((p) => p.jid);
    return {
      subject: r?.subject ?? gc.name,
      description: r?.desc ?? r?.description ?? null,
      size: r?.size ?? participants.length,
      participants,
    };
  });

  const ParticipantsBody = z.object({
    action: z.enum(["add", "remove", "promote", "demote"]),
    jids: z.array(z.string().min(3)).min(1).max(50),
  });
  app.post("/groups/:id/participants", { preHandler: authenticate }, async (req) => {
    const b = ParticipantsBody.parse(req.body);
    const { inst, jid, key } = await liveGroup(req.userId, (req.params as { id: string }).id);
    await evolution.groupUpdateParticipant(inst.instanceName, key, jid, b.action, b.jids);
    return { ok: true };
  });

  const UpdateBody = z.object({
    subject: z.string().min(1).max(80).optional(),
    description: z.string().max(2000).optional(),
  });
  app.patch("/groups/:id", { preHandler: authenticate }, async (req) => {
    const b = UpdateBody.parse(req.body);
    const { gc, inst, jid, key } = await liveGroup(req.userId, (req.params as { id: string }).id);
    if (b.subject !== undefined) {
      await evolution.groupUpdateSubject(inst.instanceName, key, jid, b.subject.trim());
      await prisma.groupCreation.update({ where: { id: gc.id }, data: { name: b.subject.trim() } });
    }
    if (b.description !== undefined) {
      await evolution.groupUpdateDescription(inst.instanceName, key, jid, b.description);
    }
    return { ok: true };
  });
}
