import Fastify from "fastify";
import helmet from "@fastify/helmet";
import rateLimit from "@fastify/rate-limit";
import multipart from "@fastify/multipart";
import websocket from "@fastify/websocket";
import fastifyStatic from "@fastify/static";
import { mkdir } from "node:fs/promises";
import { existsSync } from "node:fs";
import path from "node:path";
import { fileURLToPath } from "node:url";
import { config } from "./config.js";
import { prisma } from "./db.js";
import { registerErrorHandler } from "./plugins/error-handler.js";
import { registerAuthRoutes } from "./routes/auth.js";
import { registerUserRoutes } from "./routes/users.js";
import { registerAdminRoutes } from "./routes/admin.js";
import { registerInstanceRoutes } from "./routes/instances.js";
import { registerWebhookRoutes } from "./routes/webhooks.js";
import { registerMessageRoutes } from "./routes/messages.js";
import { registerChatRoutes } from "./routes/chats.js";
import { registerListRoutes } from "./routes/lists.js";
import { registerTemplateRoutes } from "./routes/templates.js";
import { registerGroupRoutes } from "./routes/groups.js";
import { registerMediaRoutes } from "./routes/media.js";
import { registerWsRoutes } from "./routes/ws.js";
import { registerAutoReplyRoutes } from "./routes/autoreplies.js";
import * as scheduler from "./services/scheduler.js";

async function main() {
  await prisma.$connect();
  await seedSettingsFromEnv();
  await scheduler.recoverOnBoot(); // logs SENDING → FAILED "INTERRUMPIDO", claims liberados (§17.6)

  // maxParamLength: los tokens firmados de /internal/media/:signedToken miden ~105 chars (default 100)
  const app = Fastify({ logger: true, maxParamLength: 512 });

  await mkdir(config.MEDIA_DIR, { recursive: true });

  await app.register(helmet);
  await app.register(rateLimit, { global: false }); // solo rutas /auth/* lo activan vía config
  await app.register(multipart, { limits: { fileSize: 64 * 1024 * 1024 } });
  await app.register(websocket);

  // Web app (SPA) en /app — si existe el build (web/dist se copia a ./web en la imagen Docker)
  const webDist = [
    path.resolve(path.dirname(fileURLToPath(import.meta.url)), "../web"),
    path.resolve(path.dirname(fileURLToPath(import.meta.url)), "../../web/dist"),
  ].find((p) => existsSync(path.join(p, "index.html")));
  if (webDist) {
    await app.register(fastifyStatic, { root: webDist, prefix: "/app/" });
    app.get("/app", (_req, reply) => reply.redirect("/app/"));
    app.get("/", (_req, reply) => reply.redirect("/app/"));
  }

  registerErrorHandler(app, { spaRoot: webDist });

  app.get("/health", async () => ({ ok: true, service: "crona", ts: new Date().toISOString() }));

  registerAuthRoutes(app);
  registerUserRoutes(app);
  registerAdminRoutes(app);
  registerInstanceRoutes(app);
  registerWebhookRoutes(app);
  registerMessageRoutes(app);
  registerChatRoutes(app);
  registerListRoutes(app);
  registerTemplateRoutes(app);
  registerGroupRoutes(app);
  registerMediaRoutes(app);
  registerWsRoutes(app);
  registerAutoReplyRoutes(app);

  await app.listen({ host: "0.0.0.0", port: config.PORT });
  scheduler.start(); // tick inmediato + setInterval 30 s
}

// Compose todo-en-uno: config de Evolution vía env en el PRIMER arranque (luego manda el panel admin)
async function seedSettingsFromEnv() {
  if (!config.EVOLUTION_BASE_URL || !config.EVOLUTION_API_KEY) return;
  const existing = await prisma.serverSettings.findUnique({ where: { id: 1 } });
  if (existing) return;
  const { updateSettings } = await import("./services/settings.js");
  await updateSettings({
    evolutionBaseUrl: config.EVOLUTION_BASE_URL,
    evolutionGlobalApiKey: config.EVOLUTION_API_KEY,
    ntfyBaseUrl: config.NTFY_BASE_URL,
  });
  console.log("ServerSettings sembrados desde el entorno (Evolution preconfigurada)");
}

main().catch((err) => {
  console.error(err);
  process.exit(1);
});
