-- AlterTable
ALTER TABLE "User" ADD COLUMN     "chatIncomingCount" INTEGER NOT NULL DEFAULT 5,
ADD COLUMN     "chatListCount" INTEGER NOT NULL DEFAULT 10;

-- CreateTable
CREATE TABLE "ChatMessage" (
    "id" TEXT NOT NULL,
    "instanceId" TEXT NOT NULL,
    "jid" TEXT NOT NULL,
    "fromMe" BOOLEAN NOT NULL DEFAULT false,
    "type" "MessageType" NOT NULL DEFAULT 'TEXT',
    "body" TEXT,
    "pushName" TEXT,
    "evolutionMessageId" TEXT,
    "sentAt" TIMESTAMP(3) NOT NULL,
    "createdAt" TIMESTAMP(3) NOT NULL DEFAULT CURRENT_TIMESTAMP,

    CONSTRAINT "ChatMessage_pkey" PRIMARY KEY ("id")
);

-- CreateIndex
CREATE INDEX "ChatMessage_instanceId_jid_sentAt_idx" ON "ChatMessage"("instanceId", "jid", "sentAt");

-- AddForeignKey
ALTER TABLE "ChatMessage" ADD CONSTRAINT "ChatMessage_instanceId_fkey" FOREIGN KEY ("instanceId") REFERENCES "Instance"("id") ON DELETE CASCADE ON UPDATE CASCADE;
