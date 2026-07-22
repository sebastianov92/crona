import type { FastifyInstance } from "fastify";
import { z } from "zod";
import { prisma } from "../db.js";
import { authenticate } from "../plugins/auth.js";
import { errors } from "../lib/errors.js";

// Plantillas de mensaje. Privadas (solo su dueño) o públicas (todos las ven y usan,
// pero solo el creador puede editarlas o borrarlas; un ADMIN también puede borrarlas).

const PartInput = z.object({
  body: z.string().min(1).max(4096),
  typingMs: z.number().int().min(500).max(25_000).nullable().optional(),
});

const templateDTO = (t: {
  id: string;
  userId: string;
  name: string;
  kind: string;
  isPublic: boolean;
  createdAt: Date;
  parts: { order: number; body: string; typingMs: number | null }[];
  user?: { name: string } | null;
}) => ({
  id: t.id,
  name: t.name,
  kind: t.kind,
  isPublic: t.isPublic,
  ownerId: t.userId,
  ownerName: t.user?.name ?? null,
  createdAt: t.createdAt,
  parts: [...t.parts]
    .sort((a, b) => a.order - b.order)
    .map((p) => ({ body: p.body, typingMs: p.typingMs })),
});

export function registerTemplateRoutes(app: FastifyInstance) {
  app.get("/templates", { preHandler: authenticate }, async (req) => {
    const Query = z.object({ kind: z.enum(["MESSAGE", "GROUP_INITIAL"]).optional() });
    const q = Query.parse(req.query);
    const items = await prisma.template.findMany({
      where: {
        ...(q.kind ? { kind: q.kind } : {}),
        OR: [{ userId: req.userId }, { isPublic: true }],
      },
      orderBy: [{ name: "asc" }],
      include: { parts: true, user: { select: { name: true } } },
    });
    return { items: items.map(templateDTO), nextCursor: null };
  });

  const CreateBody = z.object({
    name: z.string().min(1).max(60),
    kind: z.enum(["MESSAGE", "GROUP_INITIAL"]).default("MESSAGE"),
    isPublic: z.boolean().default(false),
    parts: z.array(PartInput).min(1).max(10),
  });

  app.post("/templates", { preHandler: authenticate }, async (req, reply) => {
    const body = CreateBody.parse(req.body);
    const created = await prisma.template.create({
      data: {
        userId: req.userId,
        name: body.name.trim(),
        kind: body.kind,
        isPublic: body.isPublic,
        parts: {
          create: body.parts.map((p, i) => ({ order: i, body: p.body, typingMs: p.typingMs ?? null })),
        },
      },
      include: { parts: true, user: { select: { name: true } } },
    });
    return reply.status(201).send(templateDTO(created));
  });

  const PatchBody = z.object({
    name: z.string().min(1).max(60).optional(),
    isPublic: z.boolean().optional(),
    parts: z.array(PartInput).min(1).max(10).optional(),
  });

  app.patch("/templates/:id", { preHandler: authenticate }, async (req) => {
    const { id } = req.params as { id: string };
    const body = PatchBody.parse(req.body);
    const tpl = await prisma.template.findUnique({ where: { id } });
    if (!tpl) throw errors.notFound("La plantilla");
    // pública o no, editar es solo del creador
    if (tpl.userId !== req.userId) throw errors.forbidden();

    const updated = await prisma.template.update({
      where: { id },
      data: {
        ...(body.name !== undefined ? { name: body.name.trim() } : {}),
        ...(body.isPublic !== undefined ? { isPublic: body.isPublic } : {}),
        ...(body.parts !== undefined
          ? {
              parts: {
                deleteMany: {},
                create: body.parts.map((p, i) => ({ order: i, body: p.body, typingMs: p.typingMs ?? null })),
              },
            }
          : {}),
      },
      include: { parts: true, user: { select: { name: true } } },
    });
    return templateDTO(updated);
  });

  app.delete("/templates/:id", { preHandler: authenticate }, async (req) => {
    const { id } = req.params as { id: string };
    const tpl = await prisma.template.findUnique({ where: { id } });
    if (!tpl) throw errors.notFound("La plantilla");
    const me = await prisma.user.findUnique({ where: { id: req.userId } });
    if (tpl.userId !== req.userId && me?.role !== "ADMIN") throw errors.forbidden();
    await prisma.template.delete({ where: { id } });
    return { ok: true };
  });
}
