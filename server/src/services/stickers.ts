import { createHash } from "node:crypto";
import { prisma } from "../db.js";
import { evolution } from "./evolution.js";
import { decrypt } from "./crypto.js";
import { saveMedia } from "./media.js";
import { broadcast } from "../ws/hub.js";

/// Buzón de stickers: cuando el usuario tiene el modo activo y se envía un sticker A SÍ MISMO
/// (chat contigo mismo), el webhook lo captura y lo guarda en su biblioteca.
/// Los stickers/packs de WhatsApp no se exponen por API; este es el modo de llenarla.

/** Procesa un MESSAGES_UPSERT buscando un sticker propio del self-chat para guardarlo. */
export async function captureStickerFromWebhook(instanceName: string, data: any): Promise<void> {
  const key = data?.key;
  const stickerMsg = data?.message?.stickerMessage;
  if (!key || !key.fromMe || !stickerMsg) return; // solo los que YO envío, y solo stickers

  const jid: string = key.remoteJid ?? "";
  const number = jid.split("@")[0];
  if (!number) return;

  const instance = await prisma.instance.findUnique({
    where: { instanceName },
    include: { user: true },
  });
  if (!instance || !instance.user.captureStickers) return;

  // self-chat: el destinatario es tu propio número (el de la instancia conectada)
  const own = (instance.phoneNumber ?? "").replace(/\D/g, "");
  if (!own || number.replace(/\D/g, "") !== own) return;

  try {
    const evoKey = decrypt(instance.tokenEnc);
    const res = await evolution.getBase64FromMedia(instance.instanceName, evoKey, key);
    const b64: string | undefined = res?.base64 ?? res?.media ?? res?.buffer;
    if (!b64) return;
    const buf = Buffer.from(b64, "base64");
    if (buf.length === 0 || buf.length > 2 * 1024 * 1024) return; // sticker sano ≤ 2 MB

    const hash = createHash("sha256").update(buf).digest("hex");
    const existing = await prisma.stickerAsset.findUnique({
      where: { userId_hash: { userId: instance.userId, hash } },
    });
    if (existing) {
      // ya lo tienes: solo súbelo al tope de recientes
      await prisma.stickerAsset.update({ where: { id: existing.id }, data: { lastUsedAt: new Date() } });
      return;
    }

    const media = await saveMedia(instance.userId, "sticker.webp", "image/webp", buf);
    const asset = await prisma.stickerAsset.create({
      data: { userId: instance.userId, mediaId: media.id, hash, lastUsedAt: new Date() },
    });
    broadcast(instance.userId, "sticker.saved", { id: asset.id, mediaId: media.id });
  } catch {
    // captura best-effort: si Evolution no devuelve el media, no pasa nada
  }
}
