import Fastify from "fastify";
import helmet from "@fastify/helmet";
import rateLimit from "@fastify/rate-limit";
import { config } from "./config.js";
import { prisma } from "./db.js";
import { registerErrorHandler } from "./plugins/error-handler.js";
import { registerAuthRoutes } from "./routes/auth.js";
import { registerUserRoutes } from "./routes/users.js";
import { registerAdminRoutes } from "./routes/admin.js";
import { registerInstanceRoutes } from "./routes/instances.js";
import { registerWebhookRoutes } from "./routes/webhooks.js";
import { registerMessageRoutes } from "./routes/messages.js";
import * as scheduler from "./services/scheduler.js";

async function main() {
  await prisma.$connect();
  await scheduler.recoverOnBoot(); // logs SENDING → FAILED "INTERRUMPIDO", claims liberados (§17.6)

  const app = Fastify({ logger: true });

  await app.register(helmet);
  await app.register(rateLimit, { global: false }); // solo rutas /auth/* lo activan vía config

  registerErrorHandler(app);

  app.get("/health", async () => ({ ok: true, service: "catchapp", ts: new Date().toISOString() }));

  registerAuthRoutes(app);
  registerUserRoutes(app);
  registerAdminRoutes(app);
  registerInstanceRoutes(app);
  registerWebhookRoutes(app);
  registerMessageRoutes(app);

  await app.listen({ host: "0.0.0.0", port: config.PORT });
  scheduler.start(); // tick inmediato + setInterval 30 s
}

main().catch((err) => {
  console.error(err);
  process.exit(1);
});
