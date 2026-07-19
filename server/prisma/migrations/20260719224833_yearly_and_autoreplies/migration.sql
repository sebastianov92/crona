-- CreateEnum
CREATE TYPE "AutoReplyAction" AS ENUM ('REPLY', 'NOTIFY');

-- AlterEnum
ALTER TYPE "Recurrence" ADD VALUE 'YEARLY';

-- CreateTable
CREATE TABLE "AutoReply" (
    "id" TEXT NOT NULL,
    "userId" TEXT NOT NULL,
    "instanceId" TEXT NOT NULL,
    "action" "AutoReplyAction" NOT NULL DEFAULT 'REPLY',
    "keyword" TEXT,
    "replyText" TEXT,
    "activeFromHour" INTEGER,
    "activeToHour" INTEGER,
    "timezone" TEXT NOT NULL DEFAULT 'America/Guayaquil',
    "cooldownMinutes" INTEGER NOT NULL DEFAULT 60,
    "enabled" BOOLEAN NOT NULL DEFAULT true,
    "createdAt" TIMESTAMP(3) NOT NULL DEFAULT CURRENT_TIMESTAMP,

    CONSTRAINT "AutoReply_pkey" PRIMARY KEY ("id")
);

-- CreateTable
CREATE TABLE "AutoReplyHit" (
    "id" TEXT NOT NULL,
    "autoReplyId" TEXT NOT NULL,
    "jid" TEXT NOT NULL,
    "createdAt" TIMESTAMP(3) NOT NULL DEFAULT CURRENT_TIMESTAMP,

    CONSTRAINT "AutoReplyHit_pkey" PRIMARY KEY ("id")
);

-- CreateIndex
CREATE INDEX "AutoReplyHit_autoReplyId_jid_createdAt_idx" ON "AutoReplyHit"("autoReplyId", "jid", "createdAt");

-- AddForeignKey
ALTER TABLE "AutoReply" ADD CONSTRAINT "AutoReply_userId_fkey" FOREIGN KEY ("userId") REFERENCES "User"("id") ON DELETE CASCADE ON UPDATE CASCADE;

-- AddForeignKey
ALTER TABLE "AutoReply" ADD CONSTRAINT "AutoReply_instanceId_fkey" FOREIGN KEY ("instanceId") REFERENCES "Instance"("id") ON DELETE CASCADE ON UPDATE CASCADE;

-- AddForeignKey
ALTER TABLE "AutoReplyHit" ADD CONSTRAINT "AutoReplyHit_autoReplyId_fkey" FOREIGN KEY ("autoReplyId") REFERENCES "AutoReply"("id") ON DELETE CASCADE ON UPDATE CASCADE;
