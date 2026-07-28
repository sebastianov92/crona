import { createHash } from "node:crypto";
import type { Instance } from "@prisma/client";
import { prisma } from "../db.js";
import { evolution } from "./evolution.js";
import { decrypt } from "./crypto.js";
import { saveMedia } from "./media.js";
import { broadcast } from "../ws/hub.js";

/// Buzón de stickers: cuando el usuario tiene el modo activo y se envía un sticker A SÍ MISMO
/// (chat contigo mismo), el webhook lo captura y lo guarda en su biblioteca.
/// Los stickers/packs de WhatsApp no se exponen por API; este es el modo de llenarla.

/** Solo los dígitos de un jid/número, sin código de dispositivo (":12") ni sufijo (@…). */
function digitsOf(jidOrNumber: string): string {
  return jidOrNumber.split("@")[0].split(":")[0].replace(/\D/g, "");
}

/** Extrae el número propio del payload de fetchInstances (formato varía entre 2.x). */
function ownerFromFetch(res: any): string {
  const arr = Array.isArray(res) ? res : (res?.instance ? [res.instance] : [res]);
  for (const it of arr) {
    const owner = it?.ownerJid ?? it?.owner ?? it?.wuid ?? it?.number ?? it?.instance?.ownerJid ?? "";
    const d = digitsOf(String(owner));
    if (d.length >= 8) return d;
  }
  return "";
}

/** Número propio de la instancia (WhatsApp conectado). Lo cachea en phoneNumber la 1ª vez. */
async function ownNumber(instance: Instance): Promise<string> {
  const stored = digitsOf(instance.phoneNumber ?? "");
  if (stored.length >= 8) return stored;
  // no se guardó al conectar: pedírselo a Evolution y persistirlo
  try {
    const res = await evolution.fetchInstance(instance.instanceName);
    const own = ownerFromFetch(res);
    if (own.length >= 8) {
      await prisma.instance.update({ where: { id: instance.id }, data: { phoneNumber: own } });
      return own;
    }
  } catch {
    /* Evolution no respondió: sin número no se puede distinguir el self-chat */
  }
  return "";
}

/** Procesa un MESSAGES_UPSERT buscando un sticker propio del self-chat para guardarlo. */
export async function captureStickerFromWebhook(instanceName: string, data: any): Promise<void> {
  const key = data?.key;
  const stickerMsg = data?.message?.stickerMessage;
  if (!key || !key.fromMe || !stickerMsg) return; // solo los que YO envío, y solo stickers

  const jid: string = key.remoteJid ?? "";
  const to = digitsOf(jid);
  if (!to) return;

  const instance = await prisma.instance.findUnique({
    where: { instanceName },
    include: { user: true },
  });
  if (!instance || !instance.user.captureStickers) return;

  // self-chat: el destinatario del sticker es TU propio número (el de esta instancia).
  // Con varias instancias esto funciona por instancia: cada una compara con su propio número.
  const own = await ownNumber(instance);
  // comparación tolerante: uno puede venir con código de país y el otro no (últimos 8 dígitos)
  if (!own) return;
  const matches = to === own || to.endsWith(own.slice(-8)) || own.endsWith(to.slice(-8));
  if (!matches) return;

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
