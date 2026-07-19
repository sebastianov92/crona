import Fastify from "fastify";
import helmet from "@fastify/helmet";
import rateLimit from "@fastify/rate-limit";
import multipart from "@fastify/multipart";
import websocket from "@fastify/websocket";
import { mkdir } from "node:fs/promises";
import { config } from "./config.js";
import { prisma } from "./db.js";
import { registerErrorHandler } from "./plugins/error-handler.js";
import { registerAuthRoutes } from "./routes/auth.js";
import { registerUserRoutes } from "./routes/users.js";
import { registerAdminRoutes } from "./routes/admin.js";
import { registerInstanceRoutes } from "./routes/instances.js";
import { registerWebhookRoutes } from "./routes/webhooks.js";
import { registerMessageRoutes } from "./routes/messages.js";
import { registerMediaRoutes } from "./routes/media.js";
import { registerWsRoutes } from "./routes/ws.js";
import { registerAutoReplyRoutes } from "./routes/autoreplies.js";
import * as scheduler from "./services/scheduler.js";

async function main() {
  await prisma.$connect();
  await scheduler.recoverOnBoot(); // logs SENDING → FAILED "INTERRUMPIDO", claims liberados (§17.6)

  // maxParamLength: los tokens firmados de /internal/media/:signedToken miden ~105 chars (default 100)
  const app = Fastify({ logger: true, maxParamLength: 512 });

  await mkdir(config.MEDIA_DIR, { recursive: true });

  await app.register(helmet);
  await app.register(rateLimit, { global: false }); // solo rutas /auth/* lo activan vía config
  await app.register(multipart, { limits: { fileSize: 64 * 1024 * 1024 } });
  await app.register(websocket);

  registerErrorHandler(app);

  app.get("/health", async () => ({ ok: true, service: "crona", ts: new Date().toISOString() }));

  registerAuthRoutes(app);
  registerUserRoutes(app);
  registerAdminRoutes(app);
  registerInstanceRoutes(app);
  registerWebhookRoutes(app);
  registerMessageRoutes(app);
  registerMediaRoutes(app);
  registerWsRoutes(app);
  registerAutoReplyRoutes(app);

  await app.listen({ host: "0.0.0.0", port: config.PORT });
  scheduler.start(); // tick inmediato + setInterval 30 s
}

main().catch((err) => {
  console.error(err);
  process.exit(1);
});
