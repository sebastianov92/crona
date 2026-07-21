import type { FastifyInstance } from "fastify";
import { z } from "zod";
import { prisma } from "../db.js";
import { authenticate } from "../plugins/auth.js";
import { errors } from "../lib/errors.js";

// Pestaña Chats: conversaciones con la gente a la que el usuario ya programó mensajes.
// Salientes = historial de envíos (MessageLog) + pendientes; entrantes = ChatMessage (webhook).

type Bubble = {
  id: string;
  direction: "in" | "out" | "scheduled";
  type: string;
  body: string | null;
  at: Date;
  status: string | null; // LogStatus para out, ScheduleStatus para scheduled, null para in
  scheduledMessageId: string | null;
};

export function registerChatRoutes(app: FastifyInstance) {
  app.get("/chats", { preHandler: authenticate }, async (req) => {
    const user = await prisma.user.findUnique({ where: { id: req.userId } });
    if (!user) throw errors.notFound("El usuario");

    // último mensaje programado (no auto-respuesta) por instancia+destinatario
    const msgs = await prisma.scheduledMessage.findMany({
      where: { userId: req.userId, isAutoReply: false, recipientJid: { not: "" } },
      orderBy: { updatedAt: "desc" },
      select: {
        instanceId: true,
        recipientJid: true,
        recipientName: true,
        recipientKind: true,
        recipientPictureUrl: true,
        updatedAt: true,
      },
    });

    const hidden = await prisma.hiddenChat.findMany({ where: { userId: req.userId } });
    const hiddenAt = new Map(hidden.map((h) => [`${h.instanceId}|${h.jid}`, h.hiddenAt]));

    const seen = new Set<string>();
    const chats: typeof msgs = [];
    for (const m of msgs) {
      const key = `${m.instanceId}|${m.recipientJid}`;
      if (seen.has(key)) continue;
      seen.add(key);
      chats.push(m);
    }

    const items = await Promise.all(
      chats.map(async (c) => {
        const [lastOut, lastIn, pending, recipient] = await Promise.all([
          prisma.messageLog.findFirst({
            where: {
              remoteJid: c.recipientJid,
              scheduledMessage: { userId: req.userId, instanceId: c.instanceId },
            },
            orderBy: { runAt: "desc" },
            include: { scheduledMessage: { select: { type: true, body: true } } },
          }),
          prisma.chatMessage.findFirst({
            where: { instanceId: c.instanceId, jid: c.recipientJid },
            orderBy: { sentAt: "desc" },
          }),
          prisma.scheduledMessage.count({
            where: {
              userId: req.userId,
              instanceId: c.instanceId,
              recipientJid: c.recipientJid,
              status: { in: ["ACTIVE", "PAUSED"] },
            },
          }),
          prisma.recipient.findFirst({
            where: { instanceId: c.instanceId, jid: c.recipientJid },
          }),
        ]);

        const outAt = lastOut?.runAt ?? null;
        const inAt = lastIn?.sentAt ?? null;
        const last =
          inAt && (!outAt || inAt > outAt)
            ? { fromMe: false, type: lastIn!.type as string, body: lastIn!.body, at: inAt }
            : lastOut
              ? { fromMe: true, type: lastOut.scheduledMessage.type as string, body: lastOut.scheduledMessage.body, at: outAt! }
              : null;

        return {
          instanceId: c.instanceId,
          jid: c.recipientJid,
          name: recipient?.alias || recipient?.displayName || c.recipientName,
          pictureUrl: recipient?.pictureUrl ?? c.recipientPictureUrl,
          kind: c.recipientKind,
          pendingCount: pending,
          last,
          lastAt: last?.at ?? c.updatedAt,
        };
      }),
    );

    // Chats "eliminados": ocultos hasta que haya actividad posterior a hiddenAt
    const visible = items.filter((i) => {
      const h = hiddenAt.get(`${i.instanceId}|${i.jid}`);
      return !h || i.lastAt > h;
    });
    visible.sort((a, b) => b.lastAt.getTime() - a.lastAt.getTime());
    return { items: visible.slice(0, user.chatListCount), nextCursor: null };
  });

  // "Eliminar" chat de la lista: se oculta hasta que haya un mensaje nuevo (enviado o recibido)
  app.delete("/chats", { preHandler: authenticate }, async (req) => {
    const Query = z.object({ instanceId: z.string().uuid(), jid: z.string().min(3) });
    const q = Query.parse(req.query);
    await prisma.hiddenChat.upsert({
      where: { userId_instanceId_jid: { userId: req.userId, instanceId: q.instanceId, jid: q.jid } },
      create: { userId: req.userId, instanceId: q.instanceId, jid: q.jid },
      update: { hiddenAt: new Date() },
    });
    return { ok: true };
  });

  app.get("/chats/messages", { preHandler: authenticate }, async (req) => {
    const Query = z.object({ instanceId: z.string().uuid(), jid: z.string().min(3) });
    const q = Query.parse(req.query);
    const user = await prisma.user.findUnique({ where: { id: req.userId } });
    if (!user) throw errors.notFound("El usuario");

    // la instancia debe ser del usuario (nunca chats ajenos)
    const inst = await prisma.instance.findFirst({ where: { id: q.instanceId, userId: req.userId } });
    if (!inst) throw errors.notFound("La instancia");

    const [logs, upcoming, incoming] = await Promise.all([
      prisma.messageLog.findMany({
        where: { remoteJid: q.jid, scheduledMessage: { userId: req.userId, instanceId: q.instanceId } },
        orderBy: { runAt: "desc" },
        take: 50,
        include: { scheduledMessage: { select: { id: true, type: true, body: true } } },
      }),
      prisma.scheduledMessage.findMany({
        where: {
          userId: req.userId,
          instanceId: q.instanceId,
          recipientJid: q.jid,
          status: { in: ["ACTIVE", "PAUSED"] },
        },
        orderBy: { nextRunAt: "asc" },
        take: 20,
      }),
      user.chatIncomingCount > 0
        ? prisma.chatMessage.findMany({
            where: { instanceId: q.instanceId, jid: q.jid },
            orderBy: { sentAt: "desc" },
            take: user.chatIncomingCount,
          })
        : Promise.resolve([]),
    ]);

    const bubbles: Bubble[] = [
      ...logs.map((l) => ({
        id: `log-${l.id}`,
        direction: "out" as const,
        type: l.scheduledMessage.type as string,
        body: l.error ?? l.scheduledMessage.body,
        at: l.runAt,
        status: l.status as string,
        scheduledMessageId: l.scheduledMessage.id,
      })),
      ...upcoming.map((m) => ({
        id: `sched-${m.id}`,
        direction: "scheduled" as const,
        type: m.type as string,
        body: m.body,
        at: m.nextRunAt,
        status: m.status as string,
        scheduledMessageId: m.id,
      })),
      ...incoming.map((c) => ({
        id: `in-${c.id}`,
        direction: "in" as const,
        type: c.type as string,
        body: c.body,
        at: c.sentAt,
        status: null,
        scheduledMessageId: null,
      })),
    ];

    bubbles.sort((a, b) => a.at.getTime() - b.at.getTime());
    return { items: bubbles, nextCursor: null };
  });
}
