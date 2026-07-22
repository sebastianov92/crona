-- CreateEnum
CREATE TYPE "TemplateKind" AS ENUM ('MESSAGE', 'GROUP_INITIAL');

-- CreateEnum
CREATE TYPE "GroupCreationStatus" AS ENUM ('PENDING', 'CREATING', 'DONE', 'FAILED');

-- AlterTable
ALTER TABLE "User" ADD COLUMN     "defaultGroupPictureMediaId" TEXT;

-- CreateTable
CREATE TABLE "Template" (
    "id" TEXT NOT NULL,
    "userId" TEXT NOT NULL,
    "name" TEXT NOT NULL,
    "kind" "TemplateKind" NOT NULL DEFAULT 'MESSAGE',
    "isPublic" BOOLEAN NOT NULL DEFAULT false,
    "createdAt" TIMESTAMP(3) NOT NULL DEFAULT CURRENT_TIMESTAMP,
    "updatedAt" TIMESTAMP(3) NOT NULL,

    CONSTRAINT "Template_pkey" PRIMARY KEY ("id")
);

-- CreateTable
CREATE TABLE "TemplatePart" (
    "id" TEXT NOT NULL,
    "templateId" TEXT NOT NULL,
    "order" INTEGER NOT NULL,
    "body" TEXT NOT NULL,
    "typingMs" INTEGER,

    CONSTRAINT "TemplatePart_pkey" PRIMARY KEY ("id")
);

-- CreateTable
CREATE TABLE "GroupCreation" (
    "id" TEXT NOT NULL,
    "userId" TEXT NOT NULL,
    "instanceId" TEXT NOT NULL,
    "name" TEXT NOT NULL,
    "pictureMediaId" TEXT,
    "participants" JSONB NOT NULL,
    "runAt" TIMESTAMP(3) NOT NULL,
    "status" "GroupCreationStatus" NOT NULL DEFAULT 'PENDING',
    "claimedAt" TIMESTAMP(3),
    "groupJid" TEXT,
    "lastError" TEXT,
    "createdAt" TIMESTAMP(3) NOT NULL DEFAULT CURRENT_TIMESTAMP,

    CONSTRAINT "GroupCreation_pkey" PRIMARY KEY ("id")
);

-- CreateTable
CREATE TABLE "GroupMessagePart" (
    "id" TEXT NOT NULL,
    "creationId" TEXT NOT NULL,
    "order" INTEGER NOT NULL,
    "body" TEXT NOT NULL,
    "typingMs" INTEGER,

    CONSTRAINT "GroupMessagePart_pkey" PRIMARY KEY ("id")
);

-- CreateTable
CREATE TABLE "MessagePart" (
    "id" TEXT NOT NULL,
    "messageId" TEXT NOT NULL,
    "order" INTEGER NOT NULL,
    "type" "MessageType" NOT NULL DEFAULT 'TEXT',
    "body" TEXT,
    "mediaId" TEXT,
    "typingMs" INTEGER,

    CONSTRAINT "MessagePart_pkey" PRIMARY KEY ("id")
);

-- CreateIndex
CREATE INDEX "Template_userId_idx" ON "Template"("userId");

-- CreateIndex
CREATE INDEX "TemplatePart_templateId_order_idx" ON "TemplatePart"("templateId", "order");

-- CreateIndex
CREATE INDEX "GroupCreation_status_runAt_idx" ON "GroupCreation"("status", "runAt");

-- CreateIndex
CREATE INDEX "GroupMessagePart_creationId_order_idx" ON "GroupMessagePart"("creationId", "order");

-- CreateIndex
CREATE INDEX "MessagePart_messageId_order_idx" ON "MessagePart"("messageId", "order");

-- AddForeignKey
ALTER TABLE "Template" ADD CONSTRAINT "Template_userId_fkey" FOREIGN KEY ("userId") REFERENCES "User"("id") ON DELETE CASCADE ON UPDATE CASCADE;

-- AddForeignKey
ALTER TABLE "TemplatePart" ADD CONSTRAINT "TemplatePart_templateId_fkey" FOREIGN KEY ("templateId") REFERENCES "Template"("id") ON DELETE CASCADE ON UPDATE CASCADE;

-- AddForeignKey
ALTER TABLE "GroupCreation" ADD CONSTRAINT "GroupCreation_userId_fkey" FOREIGN KEY ("userId") REFERENCES "User"("id") ON DELETE CASCADE ON UPDATE CASCADE;

-- AddForeignKey
ALTER TABLE "GroupMessagePart" ADD CONSTRAINT "GroupMessagePart_creationId_fkey" FOREIGN KEY ("creationId") REFERENCES "GroupCreation"("id") ON DELETE CASCADE ON UPDATE CASCADE;

-- AddForeignKey
ALTER TABLE "MessagePart" ADD CONSTRAINT "MessagePart_messageId_fkey" FOREIGN KEY ("messageId") REFERENCES "ScheduledMessage"("id") ON DELETE CASCADE ON UPDATE CASCADE;
