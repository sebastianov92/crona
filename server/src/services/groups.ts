import { readFile } from "node:fs/promises";
import { prisma } from "../db.js";
import { evolution } from "./evolution.js";
import { decrypt } from "./crypto.js";
import { mediaAbsPath, buildMediaPayload, buildAudioPayload, buildStickerPayload } from "./media.js";
import { broadcast } from "../ws/hub.js";
import type { ScheduledMessage } from "@prisma/client";

/// Crea grupos de WhatsApp pendientes: grupo → foto → espera 5-10 s → mensaje inicial
/// (cada parte con su "escribiendo…" y pausa de 0.5-1 s entre partes, igual que el split).

const sleep = (ms: number) => new Promise((r) => setTimeout(r, ms));
const rand = (min: number, max: number) => min + Math.floor(Math.random() * (max - min));
const errMsg = (e: unknown) => (e instanceof Error ? e.message : String(e)).slice(0, 500);

/** Reclama creaciones vencidas sin que dos workers tomen la misma (§17). */
async function claimDue(limit = 5): Promise<string[]> {
  return prisma.$transaction(async (tx) => {
    const rows = await tx.$queryRaw<{ id: string }[]>`
      SELECT id FROM "GroupCreation"
      WHERE status = 'PENDING'
        AND "runAt" <= now()
        AND ("claimedAt" IS NULL OR "claimedAt" < now() - interval '5 minutes')
      ORDER BY "runAt" ASC
      FOR UPDATE SKIP LOCKED
      LIMIT ${limit}`;
    const ids = rows.map((r) => r.id);
    if (ids.length)
      await tx.groupCreation.updateMany({
        where: { id: { in: ids } },
        data: { claimedAt: new Date(), status: "CREATING" },
      });
    return ids;
  });
}

type Participant = { jid: string; name?: string };

/// El jid del grupo puede venir como string en varias claves, o como objeto {_serialized}/{id}.
function extractGroupJid(res: any): string | undefined {
  const cand = res?.id ?? res?.groupJid ?? res?.jid ?? res?.gid ?? res?.group?.id;
  if (typeof cand === "string" && cand.includes("@")) return cand;
  if (cand && typeof cand === "object") {
    const s = cand._serialized ?? cand.id ?? cand.user;
    if (typeof s === "string" && s.includes("@")) return s;
  }
  return undefined;
}

/// Envía una parte del mensaje inicial al grupo (texto o media), reusando los builders del worker.
async function sendGroupPart(
  n: string, key: string, groupJid: string, groupName: string,
  part: { type: string; body: string | null; mediaId: string | null; typingMs: number | null },
): Promise<void> {
  const delay = part.typingMs ?? 1800;
  // objeto tipo-mensaje para reusar los builders (solo leen recipientJid/mediaId/body/typingMs + recipientName/timezone)
  const like = {
    recipientJid: groupJid, recipientName: groupName, timezone: "UTC",
    type: part.type, body: part.body, mediaId: part.mediaId, typingMs: part.typingMs,
  } as unknown as ScheduledMessage;
  if (part.type === "TEXT") {
    await evolution.sendText(n, key, { number: groupJid, text: part.body ?? "", delay, linkPreview: true });
  } else if (part.type === "AUDIO") {
    await evolution.sendAudio(n, key, await buildAudioPayload(like));
  } else if (part.type === "STICKER") {
    await evolution.sendSticker(n, key, await buildStickerPayload(like));
  } else {
    await evolution.sendMedia(n, key, await buildMediaPayload(like));
  }
}

async function createOne(id: string): Promise<void> {
  const gc = await prisma.groupCreation.findUnique({
    where: { id },
    include: { parts: { orderBy: { order: "asc" } } },
  });
  if (!gc) return;

  const instance = await prisma.instance.findFirst({ where: { id: gc.instanceId, userId: gc.userId } });
  if (!instance) {
    await prisma.groupCreation.update({
      where: { id },
      data: { status: "FAILED", lastError: "La instancia ya no existe.", claimedAt: null },
    });
    return;
  }

  try {
    const state = await evolution.cachedState(instance.instanceName).catch(() => "close");
    if (state !== "open") throw new Error("INSTANCIA_DESCONECTADA");

    const key = decrypt(instance.tokenEnc);
    const participants = (gc.participants as unknown as Participant[])
      .map((p) => p.jid.split("@")[0]) // Evolution espera solo los dígitos
      .filter((n) => /^\d{8,15}$/.test(n));

    const res = await evolution.createGroup(instance.instanceName, key, {
      subject: gc.name,
      participants,
    });
    const groupJid = extractGroupJid(res);
    if (!groupJid) throw new Error("Evolution no devolvió el identificador del grupo.");

    // El grupo YA existe: a partir de aquí nada debe marcar FAILED (solo avisos suaves), porque
    // fallar aquí borraría de la vista un grupo que sí se creó en WhatsApp.
    await prisma.groupCreation.update({ where: { id }, data: { groupJid } });
    const warnings: string[] = [];

    // Foto del grupo (base64 puro, sin prefijo data:)
    if (gc.pictureMediaId) {
      const media = await prisma.media.findUnique({ where: { id: gc.pictureMediaId } });
      if (media) {
        const b64 = (await readFile(mediaAbsPath(media))).toString("base64");
        await evolution.updateGroupPicture(instance.instanceName, key, groupJid, b64).catch(() => {
          warnings.push("No se pudo poner la foto del grupo.");
        });
      }
    }

    // Mensaje inicial: 5-10 s después de crear el grupo. Su fallo NO invalida el grupo.
    if (gc.parts.length > 0) {
      try {
        await sleep(5000 + rand(0, 5000));
        for (const [i, part] of gc.parts.entries()) {
          if (i > 0) await sleep(500 + rand(0, 500)); // pausa 0.5-1 s entre partes del split
          await sendGroupPart(instance.instanceName, key, groupJid, gc.name, part);
        }
      } catch (e) {
        warnings.push("El grupo se creó, pero no se pudo enviar el mensaje inicial.");
      }
    }

    await prisma.groupCreation.update({
      where: { id },
      data: { status: "DONE", claimedAt: null, lastError: warnings.length ? warnings.join(" ") : null },
    });
    broadcast(gc.userId, "group.created", { id: gc.id, name: gc.name, groupJid });
  } catch (e) {
    await prisma.groupCreation.update({
      where: { id },
      data: { status: "FAILED", lastError: errMsg(e), claimedAt: null },
    });
    broadcast(gc.userId, "group.failed", { id: gc.id, name: gc.name, error: errMsg(e) });
  }
}

let running = false;

/** Un tick: procesa las creaciones vencidas de una en una. */
export async function groupTick(): Promise<void> {
  if (running) return;
  running = true;
  try {
    const ids = await claimDue(5);
    for (const id of ids) await createOne(id);
  } catch (err) {
    console.error("group tick failed", err);
  } finally {
    running = false;
  }
}

/** Deja las creaciones a medias como pendientes tras un reinicio. */
export async function recoverGroupsOnBoot(): Promise<void> {
  await prisma.groupCreation.updateMany({
    where: { status: "CREATING" },
    data: { status: "PENDING", claimedAt: null },
  });
}
