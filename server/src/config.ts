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
});

export const config = Env.parse(process.env);
