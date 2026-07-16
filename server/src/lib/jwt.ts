import { SignJWT, jwtVerify } from "jose";
import { createHash, randomBytes } from "node:crypto";
import { config } from "../config.js";

const secret = new TextEncoder().encode(config.JWT_SECRET);

export const signAccess = (userId: string, role: string) =>
  new SignJWT({ role })
    .setProtectedHeader({ alg: "HS256" })
    .setSubject(userId)
    .setIssuedAt()
    .setExpirationTime("15m")
    .sign(secret);

export const verifyAccess = (jwt: string) => jwtVerify(jwt, secret); // lanza si expiró → 401 TOKEN_EXPIRED

export const newRefreshToken = () => randomBytes(48).toString("base64url");
export const hashToken = (t: string) => createHash("sha256").update(t).digest("hex");
// Al refrescar: buscar por hash, validar expiresAt/revokedAt, revocar el usado, emitir par nuevo (rotación).
