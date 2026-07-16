import Fastify from "fastify";
import helmet from "@fastify/helmet";
import rateLimit from "@fastify/rate-limit";
import { config } from "./config.js";
import { prisma } from "./db.js";
import { registerErrorHandler } from "./plugins/error-handler.js";
import { registerAuthRoutes } from "./routes/auth.js";
import { registerUserRoutes } from "./routes/users.js";
import { registerAdminRoutes } from "./routes/admin.js";

async function main() {
  await prisma.$connect();

  const app = Fastify({ logger: true });

  await app.register(helmet);
  await app.register(rateLimit, { global: false }); // solo rutas /auth/* lo activan vía config

  registerErrorHandler(app);

  app.get("/health", async () => ({ ok: true, service: "catchapp", ts: new Date().toISOString() }));

  registerAuthRoutes(app);
  registerUserRoutes(app);
  registerAdminRoutes(app);

  await app.listen({ host: "0.0.0.0", port: config.PORT });
}

main().catch((err) => {
  console.error(err);
  process.exit(1);
});
