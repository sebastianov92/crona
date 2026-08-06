-- Plantillas con media (F3 follow-up): cada parte puede ser texto o media
ALTER TABLE "TemplatePart" ADD COLUMN "type" "MessageType" NOT NULL DEFAULT 'TEXT';
ALTER TABLE "TemplatePart" ADD COLUMN "mediaId" TEXT;
ALTER TABLE "TemplatePart" ALTER COLUMN "body" DROP NOT NULL;
