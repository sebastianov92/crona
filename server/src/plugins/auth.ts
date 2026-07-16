import type { FastifyReply, FastifyRequest } from "fastify";
import { verifyAccess } from "../lib/jwt.js";
import { errors } from "../lib/errors.js";

declare module "fastify" {
  interface FastifyRequest {
    userId: string;
    userRole: "ADMIN" | "USER";
  }
}

export async function authenticate(req: FastifyRequest, _reply: FastifyReply) {
  const header = req.headers.authorization;
  if (!header?.startsWith("Bearer ")) throw errors.tokenExpired();
  try {
    const { payload } = await verifyAccess(header.slice(7));
    req.userId = payload.sub as string;
    req.userRole = (payload.role as "ADMIN" | "USER") ?? "USER";
  } catch {
    throw errors.tokenExpired();
  }
}

export async function requireAdmin(req: FastifyRequest, reply: FastifyReply) {
  await authenticate(req, reply);
  if (req.userRole !== "ADMIN") throw errors.forbidden();
}
