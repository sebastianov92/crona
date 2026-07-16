import Fastify from "fastify";
import { config } from "./config.js";
import { prisma } from "./db.js";

async function main() {
  await prisma.$connect();

  const app = Fastify({ logger: true });

  app.get("/health", async () => ({ ok: true, service: "catchapp", ts: new Date().toISOString() }));

  await app.listen({ host: "0.0.0.0", port: config.PORT });
}

main().catch((err) => {
  console.error(err);
  process.exit(1);
});
