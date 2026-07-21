import type { FastifyInstance } from "fastify";
import { prisma } from "../db.js";
import { config } from "../config.js";
import { evolution } from "../services/evolution.js";
import { ntfyPublish } from "../services/ntfy.js";
import { broadcast } from "../ws/hub.js";
import { instanceDTO } from "./instances.js";
import { handleIncomingMessage } from "../services/autoreply.js";

// Payloads varían levemente entre 2.x → handler tolerante (SPEC §13.10)
const normEvent = (e: string) => e.toLowerCase().replace(/_/g, ".");

function mapAck(ack: unknown): "SENT" | "DELIVERED" | "READ" | null {
  // Baileys usa números o strings según versión — soportar ambos (SPEC §5.5)
  if (ack === 2 || ack === "2" || ack === "SERVER_ACK") return "SENT";
  if (ack === 3 || ack === "3" || ack === "DELIVERY_ACK") return "DELIVERED";
  if (ack === 4 || ack === "4" || ack === "READ") return "READ";
  return null;
}

async function handleConnectionUpdate(instanceName: string, data: any) {
  const state: string = data?.state ?? data?.connection ?? "";
  if (!state) return;
  const status = state === "open" ? "CONNECTED" : state === "connecting" ? "CONNECTING" : "DISCONNECTED";
  const inst = await prisma.instance.findUnique({
    where: { instanceName },
    include: { user: true },
  });
  if (!inst) return;
  evolution.invalidateStateCache(instanceName);

  const updated = await prisma.instance.update({
    where: { id: inst.id },
    data: { status, ...(status === "CONNECTED" ? { lastConnectedAt: new Date() } : {}) },
  });
  broadcast(inst.userId, "instance.updated", instanceDTO(updated));

  if (status === "DISCONNECTED" && inst.status !== "DISCONNECTED") {
    await ntfyPublish(inst.user, {
      title: "WhatsApp desconectado",
      message: `WhatsApp (${inst.name}) se desconectó. Ábrela en Crona y re-escanea el QR`,
      priority: 4,
      tags: ["electric_plug"],
    });
  }
}

async function handleQrUpdated(instanceName: string, data: any) {
  const qrBase64: string | null = data?.qrcode?.base64 ?? data?.base64 ?? null;
  if (!qrBase64) return;
  const inst = await prisma.instance.findUnique({ where: { instanceName } });
  if (!inst) return;
  broadcast(inst.userId, "qr.updated", { instanceId: inst.id, qrBase64 });
}

async function handleMessagesUpdate(data: any) {
  const keyId: string | null = data?.keyId ?? data?.key?.id ?? null;
  if (!keyId) return;
  const ack = mapAck(data?.status ?? data?.ack ?? data?.update?.status);
  if (!ack) return;

  const log = await prisma.messageLog.findFirst({
    where: { evolutionMessageId: keyId },
    include: { scheduledMessage: true },
  });
  if (!log) return;

  // nunca degradar estado (READ no vuelve a DELIVERED)
  const rank: Record<string, number> = { SENDING: 0, SENT: 1, DELIVERED: 2, READ: 3, FAILED: 0 };
  if (rank[ack] <= rank[log.status]) return;

  const updated = await prisma.messageLog.update({
    where: { id: log.id },
    data: {
      status: ack,
      ...(ack === "DELIVERED" ? { deliveredAt: new Date() } : {}),
      ...(ack === "READ" ? { readAt: new Date(), deliveredAt: log.deliveredAt ?? new Date() } : {}),
    },
  });
  broadcast(log.scheduledMessage.userId, "log.updated", updated);
}

async function handleSendMessage(data: any) {
  const keyId: string | null = data?.key?.id ?? data?.keyId ?? null;
  if (!keyId) return;
  const log = await prisma.messageLog.findFirst({
    where: { evolutionMessageId: keyId, status: "SENDING" },
    include: { scheduledMessage: true },
  });
  if (!log) return;
  const updated = await prisma.messageLog.update({
    where: { id: log.id },
    data: { status: "SENT", sentAt: log.sentAt ?? new Date() },
  });
  broadcast(log.scheduledMessage.userId, "log.updated", updated);
}

export function registerWebhookRoutes(app: FastifyInstance) {
  app.post("/webhooks/evolution/:secret", async (req, reply) => {
    const { secret } = req.params as { secret: string };
    if (secret !== config.WEBHOOK_SECRET) return reply.status(404).send();

    const body = req.body as { event?: string; instance?: string; data?: unknown } | null;
    const event = body?.event ?? "";
    const instanceName = body?.instance ?? "";

    // Guardar crudo los primeros días para calibrar el mapeo (SPEC §5.5)
    await prisma.webhookEventRaw
      .create({ data: { instanceName, event, payload: (body ?? {}) as object } })
      .catch(() => {});

    try {
      switch (normEvent(event)) {
        case "connection.update":
          await handleConnectionUpdate(instanceName, body?.data);
          break;
        case "qrcode.updated":
          await handleQrUpdated(instanceName, body?.data);
          break;
        case "messages.update":
          await handleMessagesUpdate(body?.data);
          break;
        case "messages.upsert":
          await handleIncomingMessage(instanceName, body?.data);
          break;
        case "send.message":
          await handleSendMessage(body?.data);
          break;
      }
    } catch (err) {
      req.log.error({ err, event }, "webhook handler failed");
    }
    return { ok: true };
  });
}
