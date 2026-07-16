import type { FastifyInstance } from "fastify";
import { z } from "zod";
import argon2 from "argon2";
import { prisma } from "../db.js";
import { authenticate } from "../plugins/auth.js";
import { errors } from "../lib/errors.js";
import { userDTO } from "../lib/dto.js";

export function registerUserRoutes(app: FastifyInstance) {
  app.get("/me", { preHandler: authenticate }, async (req) => {
    const user = await prisma.user.findUnique({ where: { id: req.userId } });
    if (!user) throw errors.notFound("El usuario");
    return userDTO(user);
  });

  const PatchBody = z.object({
    name: z.string().min(1).optional(),
    ntfyTopic: z.string().nullable().optional(),
    ntfyToken: z.string().nullable().optional(),
    notifyOnSent: z.boolean().optional(),
    password: z.string().min(8).optional(),
  });

  app.patch("/me", { preHandler: authenticate }, async (req) => {
    const body = PatchBody.parse(req.body);
    const data: Record<string, unknown> = {};
    if (body.name !== undefined) data.name = body.name;
    if (body.ntfyTopic !== undefined) data.ntfyTopic = body.ntfyTopic;
    if (body.ntfyToken !== undefined) data.ntfyToken = body.ntfyToken;
    if (body.notifyOnSent !== undefined) data.notifyOnSent = body.notifyOnSent;
    if (body.password !== undefined) data.passwordHash = await argon2.hash(body.password, { type: argon2.argon2id });
    const user = await prisma.user.update({ where: { id: req.userId }, data });
    return userDTO(user);
  });
}
