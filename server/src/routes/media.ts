import type { FastifyInstance } from "fastify";
import { prisma } from "../db.js";
import { authenticate } from "../plugins/auth.js";
import { errors } from "../lib/errors.js";
import { consumeMediaToken, mediaStream, saveMedia } from "../services/media.js";

export function registerMediaRoutes(app: FastifyInstance) {
  app.post("/media", { preHandler: authenticate }, async (req, reply) => {
    const file = await req.file();
    if (!file) throw errors.validation("Falta el archivo (campo multipart `file`).");
    const data = await file.toBuffer();
    const media = await saveMedia(req.userId, file.filename || "archivo", file.mimetype, data);
    return reply.status(201).send({
      mediaId: media.id,
      fileName: media.fileName,
      mimeType: media.mimeType,
      sizeBytes: media.sizeBytes,
    });
  });

  // Descarga autenticada (preview en la app; solo dueño)
  app.get("/media/:id", { preHandler: authenticate }, async (req, reply) => {
    const { id } = req.params as { id: string };
    const media = await prisma.media.findFirst({ where: { id, userId: req.userId } });
    if (!media) throw errors.notFound("El archivo");
    reply.header("content-type", media.mimeType);
    reply.header("content-length", String(media.sizeBytes));
    return reply.send(mediaStream(media));
  });

  // Sin auth de usuario — token HMAC firmado de un solo uso, TTL 15 min.
  // Solo lo consume Evolution por red interna (SPEC §5.3)
  app.get("/internal/media/:signedToken", async (req, reply) => {
    const { signedToken } = req.params as { signedToken: string };
    const mediaId = consumeMediaToken(signedToken);
    if (!mediaId) return reply.status(404).send({ error: { code: "NOT_FOUND", message: "Token inválido o usado." } });
    const media = await prisma.media.findUnique({ where: { id: mediaId } });
    if (!media) return reply.status(404).send({ error: { code: "NOT_FOUND", message: "El archivo no existe." } });
    reply.header("content-type", media.mimeType);
    reply.header("content-length", String(media.sizeBytes));
    return reply.send(mediaStream(media));
  });
}
