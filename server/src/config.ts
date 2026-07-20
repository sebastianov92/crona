import { z } from "zod";

const Env = z.object({
  DATABASE_URL: z.string().min(1),
  JWT_SECRET: z.string().min(32),
  ENCRYPTION_KEY: z.string().length(64), // 32 bytes hex
  WEBHOOK_SECRET: z.string().min(16),
  MEDIA_DIR: z.string().default("/data/media"),
  PUBLIC_URL: z.string().min(1),
  INTERNAL_URL: z.string().default("http://crona:3000"),
  PORT: z.coerce.number().default(3000),
  // opcionales: si vienen, se siembran los ServerSettings al primer arranque (compose todo-en-uno)
  EVOLUTION_BASE_URL: z.string().optional(),
  EVOLUTION_API_KEY: z.string().optional(),
  NTFY_BASE_URL: z.string().default("https://ntfy.sh"),
});

export const config = Env.parse(process.env);
