import type { FastifyInstance } from "fastify";
import { z } from "zod";
import { prisma } from "../db.js";
import { authenticate } from "../plugins/auth.js";
import { errors } from "../lib/errors.js";

// Listas de difusión: el cliente programa un mensaje por miembro, escalonado 3-9 s.

const MemberInput = z.object({
  jid: z.string().min(3),
  name: z.string().min(1),
  pictureUrl: z.string().nullable().optional(),
  kind: z.enum(["CONTACT", "GROUP"]).default("CONTACT"),
});

const listDTO = (l: { id: string; instanceId: string; name: string; createdAt: Date; members: any[] }) => ({
  id: l.id,
  instanceId: l.instanceId,
  name: l.name,
  createdAt: l.createdAt,
  members: l.members.map((m) => ({
    jid: m.jid,
    name: m.name,
    pictureUrl: m.pictureUrl,
    kind: m.kind,
  })),
});

export function registerListRoutes(app: FastifyInstance) {
  app.get("/lists", { preHandler: authenticate }, async (req) => {
    const lists = await prisma.contactList.findMany({
      where: { userId: req.userId },
      orderBy: { createdAt: "asc" },
      include: { members: true },
    });
    return { items: lists.map(listDTO), nextCursor: null };
  });

  const CreateBody = z.object({
    instanceId: z.string().uuid(),
    name: z.string().min(1).max(60),
    members: z.array(MemberInput).min(1).max(200),
  });

  app.post("/lists", { preHandler: authenticate }, async (req, reply) => {
    const body = CreateBody.parse(req.body);
    const inst = await prisma.instance.findFirst({ where: { id: body.instanceId, userId: req.userId } });
    if (!inst) throw errors.notFound("La instancia");
    const list = await prisma.contactList.create({
      data: {
        userId: req.userId,
        instanceId: body.instanceId,
        name: body.name,
        members: {
          create: body.members.map((m) => ({
            jid: m.jid,
            name: m.name,
            pictureUrl: m.pictureUrl ?? null,
            kind: m.kind,
          })),
        },
      },
      include: { members: true },
    });
    return reply.status(201).send(listDTO(list));
  });

  const PatchBody = z.object({
    name: z.string().min(1).max(60).optional(),
    members: z.array(MemberInput).min(1).max(200).optional(),
  });

  app.patch("/lists/:id", { preHandler: authenticate }, async (req) => {
    const { id } = req.params as { id: string };
    const body = PatchBody.parse(req.body);
    const existing = await prisma.contactList.findFirst({ where: { id, userId: req.userId } });
    if (!existing) throw errors.notFound("La lista");
    const list = await prisma.contactList.update({
      where: { id },
      data: {
        ...(body.name !== undefined ? { name: body.name } : {}),
        ...(body.members !== undefined
          ? {
              members: {
                deleteMany: {},
                create: body.members.map((m) => ({
                  jid: m.jid,
                  name: m.name,
                  pictureUrl: m.pictureUrl ?? null,
                  kind: m.kind,
                })),
              },
            }
          : {}),
      },
      include: { members: true },
    });
    return listDTO(list);
  });

  app.delete("/lists/:id", { preHandler: authenticate }, async (req) => {
    const { id } = req.params as { id: string };
    const existing = await prisma.contactList.findFirst({ where: { id, userId: req.userId } });
    if (!existing) throw errors.notFound("La lista");
    await prisma.contactList.delete({ where: { id } });
    return { ok: true };
  });
}
