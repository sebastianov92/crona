import type { ScheduledMessage } from "@prisma/client";
import { errors } from "../lib/errors.js";

// Fase 4 completa este servicio (storage + URLs firmadas + payload base64/URL).
export async function buildMediaPayload(_msg: ScheduledMessage): Promise<never> {
  throw errors.validation("El envío de media llega en la Fase 4.");
}
