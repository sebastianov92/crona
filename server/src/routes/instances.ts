import type { FastifyInstance } from "fastify";
import { z } from "zod";
import { customAlphabet } from "nanoid";
import type { Instance, InstanceStatus, Prisma } from "@prisma/client";
import { prisma } from "../db.js";
import { authenticate } from "../plugins/auth.js";
import { errors } from "../lib/errors.js";
import { encrypt, decrypt } from "../services/crypto.js";
import { evolution } from "../services/evolution.js";
import { config } from "../config.js";
import { encodeCursor, decodeCursor } from "../lib/pagination.js";

const shortid = customAlphabet("abcdefghjkmnpqrstuvwxyz23456789", 4);

const slug = (s: string) =>
  s
    .normalize("NFD")
    .replace(/[\u0300-\u036f]/g, "")
    .toLowerCase()
    .replace(/[^a-z0-9]+/g, "-")
    .replace(/^-+|-+$/g, "")
    .slice(0, 24) || "instancia";

export const instanceDTO = (i: Instance) => ({
  id: i.id,
  name: i.name,
  instanceName: i.instanceName,
  phoneNumber: i.phoneNumber,
  profilePicUrl: i.profilePicUrl,
  status: i.status,
  lastConnectedAt: i.lastConnectedAt,
  createdAt: i.createdAt,
});

/** Instancia del usuario o NOT_FOUND (nunca filtra instancias ajenas). */
export async function ownInstance(userId: string, id: string): Promise<Instance> {
  const inst = await prisma.instance.findFirst({ where: { id, userId } });
  if (!inst) throw errors.notFound("La instancia");
  return inst;
}

export const instanceKey = (inst: Instance) => decrypt(inst.tokenEnc);

function mapState(state: string): InstanceStatus {
  if (state === "open") return "CONNECTED";
  if (state === "connecting") return "CONNECTING";
  return "DISCONNECTED";
}

// La respuesta de /instance/create varía entre 2.x: hash puede ser string u objeto { apikey }
function extractHash(res: any): string {
  const h = res?.hash;
  if (typeof h === "string") return h;
  if (h?.apikey) return h.apikey;
  throw errors.evolutionUnreachable("la respuesta de create no incluyó la apikey de la instancia");
}

const extractQr = (res: any) => ({
  qrBase64: res?.qrcode?.base64 ?? res?.base64 ?? null,
  // res.code es el string crudo del QR (2@…), NO un pairing code — no confundirlos
  pairingCode: res?.qrcode?.pairingCode ?? res?.pairingCode ?? null,
});

export function registerInstanceRoutes(app: FastifyInstance) {
  app.get("/instances", { preHandler: authenticate }, async (req) => {
    const items = await prisma.instance.findMany({
      where: { userId: req.userId },
      orderBy: { createdAt: "asc" },
    });
    return { items: items.map(instanceDTO), nextCursor: null };
  });

  const CreateBody = z.object({
    name: z.string().min(1).max(40),
    // dígitos con código de país, SIN "+": si viene, Evolution devuelve pairingCode además del QR
    phoneNumber: z.string().regex(/^\d{8,15}$/).optional(),
  });

  app.post("/instances", { preHandler: authenticate }, async (req, reply) => {
    const body = CreateBody.parse(req.body);
    const instanceName = `u${shortid()}-${slug(body.name)}`;

    const res = await evolution.createInstance({
      instanceName,
      ...(body.phoneNumber ? { number: body.phoneNumber } : {}),
      qrcode: true,
      integration: "WHATSAPP-BAILEYS",
      rejectCall: false,
      groupsIgnore: false,
      alwaysOnline: false,
      readMessages: false,
      readStatus: false,
      syncFullHistory: false,
      webhook: {
        url: `${config.INTERNAL_URL}/webhooks/evolution/${config.WEBHOOK_SECRET}`,
        byEvents: false,
        base64: false,
        events: ["QRCODE_UPDATED", "CONNECTION_UPDATE", "MESSAGES_UPDATE", "MESSAGES_UPSERT", "SEND_MESSAGE"],
      },
    });

    const instance = await prisma.instance.create({
      data: {
        userId: req.userId,
        name: body.name,
        instanceName,
        tokenEnc: encrypt(extractHash(res)),
        status: "CREATED",
      },
    });

    let { qrBase64, pairingCode } = extractQr(res);
    // Gotcha: create con `number` a veces responde sin pairingCode (Baileys aún arrancando).
    // Reintentar vía connect hasta 2 veces con espera — el código que devuelve connect sí vincula.
    if (body.phoneNumber && !pairingCode) {
      for (let i = 0; i < 2 && !pairingCode; i++) {
        await new Promise((r) => setTimeout(r, 2000));
        const retry = await evolution.connect(instanceName, body.phoneNumber).catch(() => null);
        const q = extractQr(retry);
        pairingCode = q.pairingCode ?? pairingCode;
        qrBase64 = q.qrBase64 ?? qrBase64;
      }
    }
    return reply.status(201).send({ instance: instanceDTO(instance), qrBase64, pairingCode });
  });

  app.get("/instances/:id/qr", { preHandler: authenticate }, async (req) => {
    const { id } = req.params as { id: string };
    const Query = z.object({ number: z.string().regex(/^\d{8,15}$/).optional() });
    const q = Query.parse(req.query);
    const inst = await ownInstance(req.userId, id);
    const res = await evolution.connect(inst.instanceName, q.number);
    let out = extractQr(res);
    // Pidieron código pero Evolution aún no lo generó → reintentar una vez
    if (q.number && !out.pairingCode) {
      await new Promise((r) => setTimeout(r, 2000));
      const retry = await evolution.connect(inst.instanceName, q.number).catch(() => null);
      const again = extractQr(retry);
      out = { qrBase64: again.qrBase64 ?? out.qrBase64, pairingCode: again.pairingCode ?? out.pairingCode };
    }
    return out;
  });

  app.get("/instances/:id/status", { preHandler: authenticate }, async (req) => {
    const { id } = req.params as { id: string };
    const inst = await ownInstance(req.userId, id);
    evolution.invalidateStateCache(inst.instanceName);
    const res = await evolution.state(inst.instanceName);
    const status = mapState(res?.instance?.state ?? "close");
    const updated = await prisma.instance.update({
      where: { id: inst.id },
      data: { status, ...(status === "CONNECTED" ? { lastConnectedAt: new Date() } : {}) },
    });
    return instanceDTO(updated);
  });

  app.post("/instances/:id/sync", { preHandler: authenticate }, async (req) => {
    const { id } = req.params as { id: string };
    const inst = await ownInstance(req.userId, id);
    const key = instanceKey(inst);

    // Contactos: findContacts mezcla contactos, grupos y participantes (@lid) → filtrar (SPEC §5.4).
    // En 2.3.x `id` es un cuid interno y el JID viene en `remoteJid`; en otras 2.x el JID viene en `id`.
    const rawContacts: any[] = (await evolution.findContacts(inst.instanceName, key)) ?? [];
    const pickJid = (c: any): string => {
      const rj = typeof c?.remoteJid === "string" && c.remoteJid.includes("@") ? c.remoteJid : "";
      const id = typeof c?.id === "string" && c.id.includes("@") ? c.id : "";
      return rj || id;
    };
    const contacts = rawContacts
      .map((c) => ({
        jid: pickJid(c),
        name: (c?.pushName ?? c?.name ?? "") as string,
        pictureUrl: (c?.profilePicUrl ?? null) as string | null,
      }))
      .filter((c) => c.jid.endsWith("@s.whatsapp.net") && c.name.trim().length > 0);

    const rawGroups: any[] = (await evolution.fetchAllGroups(inst.instanceName, key).catch(() => [])) ?? [];
    // Fallback: en 2.3.7 groupFetchAllParticipating suele devolver [] — los grupos con actividad
    // reciente sí aparecen como chats (@g.us) en findChats, con nombre en pushName/name.
    const rawChats: any[] =
      rawGroups.length > 0 ? [] : ((await evolution.findChats(inst.instanceName, key).catch(() => [])) ?? []);
    const groups = [
      ...rawGroups.map((g) => ({
        jid: (g?.id ?? "") as string,
        name: (g?.subject ?? "") as string,
        pictureUrl: (g?.pictureUrl ?? null) as string | null,
      })),
      ...rawChats.map((c) => ({
        jid: pickJid(c),
        name: (c?.pushName ?? c?.name ?? "") as string,
        pictureUrl: (c?.profilePicUrl ?? null) as string | null,
      })),
    ]
      // Bug conocido: grupos sin subject/nombre → descartarlos del picker (SPEC §5.4)
      .filter((g) => g.jid.endsWith("@g.us") && g.name.trim().length > 0);

    await prisma.$transaction([
      ...contacts.map((c) =>
        prisma.recipient.upsert({
          where: { instanceId_jid: { instanceId: inst.id, jid: c.jid } },
          create: {
            instanceId: inst.id,
            jid: c.jid,
            displayName: c.name,
            pictureUrl: c.pictureUrl,
            kind: "CONTACT",
            phoneNumber: c.jid.split("@")[0],
          },
          update: { displayName: c.name, pictureUrl: c.pictureUrl, syncedAt: new Date() },
        }),
      ),
      ...groups.map((g) =>
        prisma.recipient.upsert({
          where: { instanceId_jid: { instanceId: inst.id, jid: g.jid } },
          create: { instanceId: inst.id, jid: g.jid, displayName: g.name, pictureUrl: g.pictureUrl, kind: "GROUP" },
          update: { displayName: g.name, pictureUrl: g.pictureUrl, syncedAt: new Date() },
        }),
      ),
    ]);

    return { contacts: contacts.length, groups: groups.length };
  });

  // Búsqueda tolerante: sin tildes, b=v, y también por dígitos del número (parciales, ej. últimos 4)
  const normalize = (s: string) =>
    s
      .toLowerCase()
      .normalize("NFD")
      .replace(/[\u0300-\u036f]/g, "")
      // marcas invisibles de direccion/formato que WhatsApp mete en nombres tipo "+593..."
      .replace(/[\u200e\u200f\u202a-\u202e\u2066-\u2069]/g, "")
      .replace(/\s+/g, " ") // NBSP y espacios raros -> espacio normal
      .replaceAll("v", "b");

  // Digitos de busqueda: sin ceros iniciales del formato local (0991... -> 991..., el jid es 593991...)
  const searchDigits = (s: string) => s.replace(/\D/g, "").replace(/^0+/, "");

  app.get("/instances/:id/recipients", { preHandler: authenticate }, async (req) => {
    const { id } = req.params as { id: string };
    const Query = z.object({
      kind: z.enum(["CONTACT", "GROUP"]).optional(),
      search: z.string().optional(),
      cursor: z.string().optional(),
      limit: z.coerce.number().min(1).max(200).default(50),
    });
    const q = Query.parse(req.query);
    const inst = await ownInstance(req.userId, id);

    // el cache por instancia son cientos de filas: filtrar en memoria permite normalización real
    const all = await prisma.recipient.findMany({
      where: { instanceId: inst.id, ...(q.kind ? { kind: q.kind } : {}) },
    });

    const term = q.search ? normalize(q.search) : "";
    const digits = q.search ? searchDigits(q.search) : "";
    const filtered = q.search
      ? all.filter((r) => {
          const hay = normalize(`${r.alias ?? ""} ${r.displayName}`);
          const phone = r.phoneNumber ?? r.jid.split("@")[0];
          return (term.length > 0 && hay.includes(term)) || (digits.length >= 2 && phone.includes(digits));
        })
      : all;

    filtered.sort((a, b) => (a.alias ?? a.displayName).localeCompare(b.alias ?? b.displayName, "es"));

    const offset = Number(decodeCursor(q.cursor) ?? 0) || 0;
    const page = filtered.slice(offset, offset + q.limit);
    return {
      items: page.map((r) => ({
        id: r.id,
        jid: r.jid,
        displayName: r.displayName,
        alias: r.alias,
        pictureUrl: r.pictureUrl,
        kind: r.kind,
        phoneNumber: r.phoneNumber,
      })),
      nextCursor: offset + q.limit < filtered.length ? encodeCursor(String(offset + q.limit)) : null,
    };
  });

  // Renombrar contacto en Crona (los pushName de WhatsApp no siempre coinciden con tu agenda)
  app.patch("/instances/:id/recipients/:rid", { preHandler: authenticate }, async (req) => {
    const { id, rid } = req.params as { id: string; rid: string };
    // optional porque JSONEncoder de Swift omite claves nil → ausente = quitar alias
    const Body = z.object({ alias: z.string().min(1).max(80).nullable().optional() });
    const body = Body.parse(req.body);
    const inst = await ownInstance(req.userId, id);
    const rec = await prisma.recipient.findFirst({ where: { id: rid, instanceId: inst.id } });
    if (!rec) throw errors.notFound("El contacto");
    const updated = await prisma.recipient.update({ where: { id: rid }, data: { alias: body.alias ?? null } });
    return {
      id: updated.id,
      jid: updated.jid,
      displayName: updated.displayName,
      alias: updated.alias,
      pictureUrl: updated.pictureUrl,
      kind: updated.kind,
      phoneNumber: updated.phoneNumber,
    };
  });

  app.delete("/instances/:id", { preHandler: authenticate }, async (req) => {
    const { id } = req.params as { id: string };
    const inst = await ownInstance(req.userId, id);
    try {
      await evolution.logout(inst.instanceName);
    } catch {
      // ya desconectada — seguir con el borrado
    }
    try {
      await evolution.remove(inst.instanceName);
    } catch {
      // si Evolution no la conoce, igual borramos localmente
    }
    // ScheduledMessage → Instance no tiene onDelete: borrar mensajes primero (logs caen en cascada)
    await prisma.$transaction([
      prisma.scheduledMessage.deleteMany({ where: { instanceId: inst.id } }),
      prisma.instance.delete({ where: { id: inst.id } }),
    ]);
    return { ok: true };
  });
}
