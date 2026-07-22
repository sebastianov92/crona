import { readFile } from "node:fs/promises";
import { prisma } from "../db.js";
import { evolution } from "./evolution.js";
import { decrypt } from "./crypto.js";
import { mediaAbsPath } from "./media.js";
import { broadcast } from "../ws/hub.js";

/// Crea grupos de WhatsApp pendientes: grupo → foto → espera 5-10 s → mensaje inicial
/// (cada parte con su "escribiendo…" y pausa de 1-3 s entre partes, igual que el split).

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
    const groupJid: string | undefined = res?.id ?? res?.groupJid ?? res?.jid;
    if (!groupJid) throw new Error("Evolution no devolvió el identificador del grupo.");

    await prisma.groupCreation.update({ where: { id }, data: { groupJid } });

    // Foto del grupo (base64 puro, sin prefijo data:)
    if (gc.pictureMediaId) {
      const media = await prisma.media.findUnique({ where: { id: gc.pictureMediaId } });
      if (media) {
        const b64 = (await readFile(mediaAbsPath(media))).toString("base64");
        await evolution.updateGroupPicture(instance.instanceName, key, groupJid, b64).catch(() => {
          /* la foto es opcional: si falla, el grupo ya está creado */
        });
      }
    }

    // Mensaje inicial: 5-10 s después de crear el grupo
    if (gc.parts.length > 0) {
      await sleep(5000 + rand(0, 5000));
      for (const [i, part] of gc.parts.entries()) {
        if (i > 0) await sleep(1000 + rand(0, 2000)); // pausa entre partes del split
        await evolution.sendText(instance.instanceName, key, {
          number: groupJid,
          text: part.body,
          delay: part.typingMs ?? 1800,
        });
      }
    }

    await prisma.groupCreation.update({
      where: { id },
      data: { status: "DONE", claimedAt: null, lastError: null },
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
