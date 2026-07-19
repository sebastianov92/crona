import type { FastifyInstance } from "fastify";
import { z } from "zod";
import { customAlphabet } from "nanoid";
import argon2 from "argon2";
import { prisma } from "../db.js";
import { requireAdmin } from "../plugins/auth.js";
import { settingsSummary, updateSettings } from "../services/settings.js";
import { evolution } from "../services/evolution.js";
import { userDTO } from "../lib/dto.js";
import { errors } from "../lib/errors.js";
import { deleteMediaFile } from "../services/media.js";

const inviteCode = customAlphabet("abcdefghjkmnpqrstuvwxyz23456789", 8);

export function registerAdminRoutes(app: FastifyInstance) {
  app.get("/admin/settings", { preHandler: requireAdmin }, async () => settingsSummary());

  const SettingsBody = z.object({
    // http y https por igual: tráfico servidor→servidor dentro del VPS (SPEC §5)
    evolutionBaseUrl: z.string().url().refine((u) => /^https?:\/\//.test(u), "Debe ser http:// o https://"),
    evolutionGlobalApiKey: z.string().min(1).optional(), // write-only
    ntfyBaseUrl: z.string().url().default("https://ntfy.sh"),
  });

  app.put("/admin/settings", { preHandler: requireAdmin }, async (req) => {
    const body = SettingsBody.parse(req.body);
    await updateSettings(body);
    return settingsSummary();
  });

  app.post("/admin/settings/test", { preHandler: requireAdmin }, async () => {
    const res = await evolution.version();
    const version: string = res?.version ?? "";
    return { ok: version.startsWith("2."), version };
  });

  app.get("/admin/users", { preHandler: requireAdmin }, async () => {
    const users = await prisma.user.findMany({ orderBy: { createdAt: "asc" } });
    return { items: users.map(userDTO), nextCursor: null };
  });

  const PatchUserBody = z.object({
    role: z.enum(["ADMIN", "USER"]).optional(),
    password: z.string().min(8).optional(), // reset directo por el admin
    name: z.string().min(1).optional(),
  });

  app.patch("/admin/users/:id", { preHandler: requireAdmin }, async (req) => {
    const { id } = req.params as { id: string };
    const body = PatchUserBody.parse(req.body);
    const user = await prisma.user.findUnique({ where: { id } });
    if (!user) throw errors.notFound("El usuario");
    if (body.role && id === req.userId) {
      throw errors.validation("No puedes cambiar tu propio rol.");
    }
    const updated = await prisma.user.update({
      where: { id },
      data: {
        ...(body.role ? { role: body.role } : {}),
        ...(body.name ? { name: body.name } : {}),
        ...(body.password ? { passwordHash: await argon2.hash(body.password, { type: argon2.argon2id }) } : {}),
      },
    });
    // reset de contraseña o cambio de rol: matar sus sesiones activas
    if (body.password || body.role) {
      await prisma.refreshToken.updateMany({ where: { userId: id, revokedAt: null }, data: { revokedAt: new Date() } });
    }
    return userDTO(updated);
  });

  app.delete("/admin/users/:id", { preHandler: requireAdmin }, async (req) => {
    const { id } = req.params as { id: string };
    if (id === req.userId) throw errors.validation("No puedes eliminar tu propia cuenta.");
    const user = await prisma.user.findUnique({ where: { id }, include: { instances: true } });
    if (!user) throw errors.notFound("El usuario");

    // desvincular sus números en Evolution (mejor esfuerzo)
    for (const inst of user.instances) {
      await evolution.logout(inst.instanceName).catch(() => {});
      await evolution.remove(inst.instanceName).catch(() => {});
    }
    // archivos de media en disco (las filas caen en cascada, los archivos no)
    const media = await prisma.media.findMany({ where: { userId: id } });
    for (const m of media) await deleteMediaFile(m);
    // ScheduledMessage.user no tiene onDelete → borrar mensajes primero; el resto cae en cascada
    await prisma.$transaction([
      prisma.scheduledMessage.deleteMany({ where: { userId: id } }),
      prisma.user.delete({ where: { id } }),
    ]);
    return { ok: true };
  });

  app.post("/admin/invites", { preHandler: requireAdmin }, async (req, reply) => {
    const invite = await prisma.invite.create({
      data: {
        code: inviteCode(),
        createdById: req.userId,
        expiresAt: new Date(Date.now() + 7 * 24 * 3600 * 1000), // expira 7 días
      },
    });
    return reply.status(201).send({ code: invite.code, expiresAt: invite.expiresAt });
  });
}
