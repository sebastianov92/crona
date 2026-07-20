-- AlterTable
ALTER TABLE "AutoReply" ADD COLUMN     "contactJid" TEXT,
ADD COLUMN     "contactName" TEXT;

-- AlterTable
ALTER TABLE "ScheduledMessage" ADD COLUMN     "isAutoReply" BOOLEAN NOT NULL DEFAULT false,
ADD COLUMN     "randomDelay" BOOLEAN NOT NULL DEFAULT false;
