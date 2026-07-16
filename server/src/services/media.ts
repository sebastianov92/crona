import { createHmac, timingSafeEqual, randomUUID } from "node:crypto";
import { mkdir, readFile, writeFile, unlink } from "node:fs/promises";
import { createReadStream } from "node:fs";
import path from "node:path";
import type { Media, ScheduledMessage } from "@prisma/client";
import { prisma } from "../db.js";
import { config } from "../config.js";
import { errors } from "../lib/errors.js";

// Límites por tipo (SPEC §15): imagen ≤16 MB · video/pdf ≤64 MB
const LIMITS: Record<string, { maxBytes: number; ext: string; mediatype: "image" | "video" | "document" }> = {
  "image/jpeg": { maxBytes: 16 * 1024 * 1024, ext: "jpg", mediatype: "image" },
  "image/png": { maxBytes: 16 * 1024 * 1024, ext: "png", mediatype: "image" },
  "image/webp": { maxBytes: 16 * 1024 * 1024, ext: "webp", mediatype: "image" },
  "video/mp4": { maxBytes: 64 * 1024 * 1024, ext: "mp4", mediatype: "video" },
  "video/quicktime": { maxBytes: 64 * 1024 * 1024, ext: "mov", mediatype: "video" },
  "application/pdf": { maxBytes: 64 * 1024 * 1024, ext: "pdf", mediatype: "document" },
};

const BASE64_MAX = 3 * 1024 * 1024; // ≤3 MB base64; >3 MB URL firmada (SPEC §5.3)

export function mediaSpec(mimeType: string) {
  return LIMITS[mimeType] ?? null;
}

export async function saveMedia(userId: string, fileName: string, mimeType: string, data: Buffer): Promise<Media> {
  const spec = mediaSpec(mimeType);
  if (!spec) throw errors.mediaTypeUnsupported();
  if (data.length > spec.maxBytes) throw errors.mediaTooLarge(spec.maxBytes / 1024 / 1024);

  const storagePath = path.join(userId, `${randomUUID()}.${spec.ext}`);
  const abs = path.join(config.MEDIA_DIR, storagePath);
  await mkdir(path.dirname(abs), { recursive: true });
  await writeFile(abs, data);

  return prisma.media.create({
    data: { userId, fileName, mimeType, sizeBytes: data.length, storagePath },
  });
}

export function mediaAbsPath(media: Media): string {
  return path.join(config.MEDIA_DIR, media.storagePath);
}

export function mediaStream(media: Media) {
  return createReadStream(mediaAbsPath(media));
}

export async function deleteMediaFile(media: Media): Promise<void> {
  await unlink(mediaAbsPath(media)).catch(() => {});
}

// ── URLs internas firmadas de un solo uso (§17.3) ─────────────────────────────

const usedTokens = new Map<string, number>(); // token → exp (epoch s)
setInterval(() => {
  const now = Date.now() / 1000;
  for (const [t, e] of usedTokens) if (e < now) usedTokens.delete(t);
}, 60_000).unref();

export function signMediaToken(mediaId: string, ttlSec = 900): string {
  const exp = Math.floor(Date.now() / 1000) + ttlSec;
  const payload = Buffer.from(`${mediaId}.${exp}`).toString("base64url");
  const sig = createHmac("sha256", config.ENCRYPTION_KEY).update(payload).digest("base64url");
  return `${payload}.${sig}`;
}

export function consumeMediaToken(token: string): string | null {
  // → mediaId | null
  const [payload, sig] = token.split(".");
  if (!payload || !sig) return null;
  const expect = createHmac("sha256", config.ENCRYPTION_KEY).update(payload).digest("base64url");
  if (sig.length !== expect.length || !timingSafeEqual(Buffer.from(sig), Buffer.from(expect))) return null;
  const [mediaId, expStr] = Buffer.from(payload, "base64url").toString().split(".");
  const exp = Number(expStr);
  if (exp < Date.now() / 1000 || usedTokens.has(token)) return null;
  usedTokens.set(token, exp);
  return mediaId;
}

// ── Payload de sendMedia para el worker ───────────────────────────────────────

export async function buildMediaPayload(msg: ScheduledMessage): Promise<Record<string, unknown>> {
  if (!msg.mediaId) throw errors.validation("El mensaje no tiene archivo adjunto.");
  const media = await prisma.media.findUnique({ where: { id: msg.mediaId } });
  if (!media) throw errors.notFound("El archivo adjunto");
  const spec = mediaSpec(media.mimeType);
  if (!spec) throw errors.mediaTypeUnsupported();

  // ≤3 MB → base64 PURO (sin prefijo data: ni saltos de línea); >3 MB → URL interna firmada
  const mediaField =
    media.sizeBytes <= BASE64_MAX
      ? (await readFile(mediaAbsPath(media))).toString("base64")
      : `${config.INTERNAL_URL}/internal/media/${signMediaToken(media.id)}`;

  return {
    number: msg.recipientJid, // regla §5.2: jid guardado tal cual
    mediatype: spec.mediatype,
    mimetype: media.mimeType,
    caption: msg.body ?? "",
    media: mediaField,
    fileName: media.fileName,
    delay: 1800,
  };
}
