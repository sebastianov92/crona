import type { FastifyInstance } from "fastify";
import { ZodError } from "zod";
import { AppError } from "../lib/errors.js";
import { EvolutionError } from "../services/evolution.js";

export function registerErrorHandler(app: FastifyInstance) {
  app.setErrorHandler((err, req, reply) => {
    if (err instanceof AppError) {
      return reply.status(err.statusCode).send({ error: { code: err.code, message: err.message } });
    }
    if (err instanceof EvolutionError) {
      return reply
        .status(502)
        .send({ error: { code: "EVOLUTION_UNREACHABLE", message: `Evolution API devolvió un error (HTTP ${err.status}).` } });
    }
    if (err instanceof ZodError) {
      const detail = err.issues.map((i) => `${i.path.join(".")}: ${i.message}`).join(" · ");
      return reply.status(400).send({ error: { code: "VALIDATION_ERROR", message: `Datos inválidos — ${detail}` } });
    }
    const fe = err as { statusCode?: number; code?: string };
    if (fe.statusCode === 429) {
      return reply.status(429).send({ error: { code: "RATE_LIMITED", message: "Demasiados intentos. Espera un minuto." } });
    }
    // límite de multipart (@fastify/multipart lanza FST_REQ_FILE_TOO_LARGE)
    if (fe.code === "FST_REQ_FILE_TOO_LARGE") {
      return reply.status(413).send({ error: { code: "MEDIA_TOO_LARGE", message: "El archivo supera el límite de 64 MB." } });
    }
    req.log.error(err);
    return reply.status(500).send({ error: { code: "INTERNAL_ERROR", message: "Error interno del servidor." } });
  });

  app.setNotFoundHandler((_req, reply) =>
    reply.status(404).send({ error: { code: "NOT_FOUND", message: "La ruta no existe." } }),
  );
}
