-- F4: tipos de mensaje encuesta/ubicación/contacto + payload en `extra`
ALTER TYPE "MessageType" ADD VALUE IF NOT EXISTS 'POLL';
ALTER TYPE "MessageType" ADD VALUE IF NOT EXISTS 'LOCATION';
ALTER TYPE "MessageType" ADD VALUE IF NOT EXISTS 'CONTACT';
ALTER TABLE "ScheduledMessage" ADD COLUMN "extra" JSONB;
ALTER TABLE "MessagePart" ADD COLUMN "extra" JSONB;
