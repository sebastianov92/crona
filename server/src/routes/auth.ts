import type { FastifyInstance } from "fastify";
import { z } from "zod";
import argon2 from "argon2";
import { prisma } from "../db.js";
import { errors } from "../lib/errors.js";
import { hashToken, newRefreshToken, signAccess } from "../lib/jwt.js";
import { userDTO } from "../lib/dto.js";

const REFRESH_DAYS = 30;

async function issueTokens(userId: string, role: string) {
  const accessToken = await signAccess(userId, role);
  const refreshToken = newRefreshToken();
  await prisma.refreshToken.create({
    data: {
      userId,
      tokenHash: hashToken(refreshToken),
      expiresAt: new Date(Date.now() + REFRESH_DAYS * 24 * 3600 * 1000),
    },
  });
  return { accessToken, refreshToken };
}

const rateLimit = { rateLimit: { max: 10, timeWindow: "1 minute" } };

export function registerAuthRoutes(app: FastifyInstance) {
  const RegisterBody = z.object({
    email: z.string().email(),
    password: z.string().min(8),
    name: z.string().min(1),
    inviteCode: z.string().optional(),
  });

  app.post("/auth/register", { config: rateLimit }, async (req, reply) => {
    const body = RegisterBody.parse(req.body);
    const userCount = await prisma.user.count();

    let inviteId: string | null = null;
    if (userCount > 0) {
      if (!body.inviteCode) throw errors.inviteRequired();
      const invite = await prisma.invite.findUnique({ where: { code: body.inviteCode } });
      if (!invite || invite.usedById || invite.expiresAt < new Date()) throw errors.inviteInvalid();
      inviteId = invite.id;
    }

    const existing = await prisma.user.findUnique({ where: { email: body.email } });
    if (existing) throw errors.validation("Ya existe una cuenta con ese email.");

    const user = await prisma.user.create({
      data: {
        email: body.email,
        passwordHash: await argon2.hash(body.password, { type: argon2.argon2id }),
        name: body.name,
        role: userCount === 0 ? "ADMIN" : "USER",
      },
    });
    if (inviteId) await prisma.invite.update({ where: { id: inviteId }, data: { usedById: user.id } });

    const tokens = await issueTokens(user.id, user.role);
    return reply.status(201).send({ ...tokens, user: userDTO(user) });
  });

  const LoginBody = z.object({ email: z.string().email(), password: z.string().min(1) });

  app.post("/auth/login", { config: rateLimit }, async (req) => {
    const body = LoginBody.parse(req.body);
    const user = await prisma.user.findUnique({ where: { email: body.email } });
    if (!user || !(await argon2.verify(user.passwordHash, body.password))) {
      throw errors.invalidCredentials();
    }
    const tokens = await issueTokens(user.id, user.role);
    return { ...tokens, user: userDTO(user) };
  });

  const RefreshBody = z.object({ refreshToken: z.string().min(1) });

  app.post("/auth/refresh", { config: rateLimit }, async (req) => {
    const body = RefreshBody.parse(req.body);
    const row = await prisma.refreshToken.findUnique({
      where: { tokenHash: hashToken(body.refreshToken) },
      include: { user: true },
    });
    if (!row || row.revokedAt || row.expiresAt < new Date()) throw errors.tokenExpired();
    // rotación: invalida el usado, emite par nuevo
    await prisma.refreshToken.update({ where: { id: row.id }, data: { revokedAt: new Date() } });
    return issueTokens(row.userId, row.user.role);
  });

  app.post("/auth/logout", { config: rateLimit }, async (req) => {
    const body = RefreshBody.parse(req.body);
    await prisma.refreshToken.updateMany({
      where: { tokenHash: hashToken(body.refreshToken), revokedAt: null },
      data: { revokedAt: new Date() },
    });
    return { ok: true };
  });
}
