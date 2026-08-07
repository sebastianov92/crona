-- Mensaje inicial de grupo con media: tipo + adjunto, y body pasa a opcional (media sin caption).
ALTER TABLE "GroupMessagePart" ADD COLUMN "type" "MessageType" NOT NULL DEFAULT 'TEXT';
ALTER TABLE "GroupMessagePart" ADD COLUMN "mediaId" TEXT;
ALTER TABLE "GroupMessagePart" ALTER COLUMN "body" DROP NOT NULL;
