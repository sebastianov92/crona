import type { FastifyInstance } from "fastify";
import { verifyAccess } from "../lib/jwt.js";
import { register } from "../ws/hub.js";

export function registerWsRoutes(app: FastifyInstance) {
  // GET /ws?token={accessJWT} — verifyAccess ANTES de register(); si falla, cerrar con 4401 (§17.9)
  app.get("/ws", { websocket: true }, async (socket, req) => {
    const { token } = req.query as { token?: string };
    if (!token) return socket.close(4401, "token requerido");
    try {
      const { payload } = await verifyAccess(token);
      register(payload.sub as string, socket);
    } catch {
      socket.close(4401, "token inválido o expirado");
    }
  });
}
