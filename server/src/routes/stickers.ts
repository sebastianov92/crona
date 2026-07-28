import type { FastifyInstance } from "fastify";
import { z } from "zod";
import { createHash } from "node:crypto";
import { prisma } from "../db.js";
import { authenticate } from "../plugins/auth.js";
import { errors } from "../lib/errors.js";
import { saveMedia } from "../services/media.js";

// Biblioteca de stickers del usuario (buzón). El webp vive como Media; aquí se lista,
// se sube manualmente y se borra. Al programar un sticker se usa su mediaId.

export function registerStickerRoutes(app: FastifyInstance) {
  app.get("/stickers", { preHandler: authenticate }, async (req) => {
    const items = await prisma.stickerAsset.findMany({
      where: { userId: req.userId },
      orderBy: [{ lastUsedAt: { sort: "desc", nulls: "last" } }, { createdAt: "desc" }],
      take: 200,
    });
    return { items: items.map((s) => ({ id: s.id, mediaId: s.mediaId, createdAt: s.createdAt })), nextCursor: null };
  });

  // Subir una imagen a la biblioteca sin pasar por WhatsApp (multipart file)
  app.post("/stickers", { preHandler: authenticate }, async (req, reply) => {
    const file = await req.file();
    if (!file) throw errors.validation("Falta el archivo del sticker.");
    const buf: Buffer = await file.toBuffer();
    if (buf.length === 0 || buf.length > 2 * 1024 * 1024) throw errors.validation("El sticker debe pesar menos de 2 MB.");
    const mime = String(file.mimetype || "");
    if (!["image/webp", "image/png", "image/jpeg"].includes(mime)) {
      throw errors.validation("El sticker debe ser una imagen (webp, png o jpg).");
    }

    const hash = createHash("sha256").update(buf).digest("hex");
    const existing = await prisma.stickerAsset.findUnique({
      where: { userId_hash: { userId: req.userId, hash } },
    });
    if (existing) {
      const bumped = await prisma.stickerAsset.update({ where: { id: existing.id }, data: { lastUsedAt: new Date() } });
      return reply.status(200).send({ id: bumped.id, mediaId: bumped.mediaId, createdAt: bumped.createdAt });
    }

    const media = await saveMedia(req.userId, file.filename || "sticker.webp", mime, buf);
    const asset = await prisma.stickerAsset.create({
      data: { userId: req.userId, mediaId: media.id, hash, lastUsedAt: new Date() },
    });
    return reply.status(201).send({ id: asset.id, mediaId: asset.mediaId, createdAt: asset.createdAt });
  });

  // Marcar como recién usado (para ordenar "recientes" al reenviar uno)
  app.post("/stickers/:id/used", { preHandler: authenticate }, async (req) => {
    const { id } = req.params as { id: string };
    const asset = await prisma.stickerAsset.findFirst({ where: { id, userId: req.userId } });
    if (!asset) throw errors.notFound("El sticker");
    await prisma.stickerAsset.update({ where: { id }, data: { lastUsedAt: new Date() } });
    return { ok: true };
  });

  app.delete("/stickers/:id", { preHandler: authenticate }, async (req) => {
    const { id } = req.params as { id: string };
    const asset = await prisma.stickerAsset.findFirst({ where: { id, userId: req.userId } });
    if (!asset) throw errors.notFound("El sticker");
    // borrar el asset; el Media queda y la limpieza diaria lo recoge si nadie lo usa
    await prisma.stickerAsset.delete({ where: { id } });
    return { ok: true };
  });
}
