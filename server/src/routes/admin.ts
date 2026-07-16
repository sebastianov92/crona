import type { FastifyInstance } from "fastify";
import { z } from "zod";
import { customAlphabet } from "nanoid";
import { prisma } from "../db.js";
import { requireAdmin } from "../plugins/auth.js";
import { settingsSummary, updateSettings } from "../services/settings.js";
import { evolution } from "../services/evolution.js";
import { userDTO } from "../lib/dto.js";

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
