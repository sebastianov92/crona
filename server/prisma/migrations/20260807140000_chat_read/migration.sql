-- Marca de "visto" por chat para contar no leídos (ChatMessage entrantes con sentAt > seenAt).
CREATE TABLE "ChatRead" (
  "id" TEXT NOT NULL,
  "userId" TEXT NOT NULL,
  "instanceId" TEXT NOT NULL,
  "jid" TEXT NOT NULL,
  "seenAt" TIMESTAMP(3) NOT NULL DEFAULT CURRENT_TIMESTAMP,
  CONSTRAINT "ChatRead_pkey" PRIMARY KEY ("id")
);
CREATE UNIQUE INDEX "ChatRead_userId_instanceId_jid_key" ON "ChatRead"("userId", "instanceId", "jid");
ALTER TABLE "ChatRead" ADD CONSTRAINT "ChatRead_userId_fkey" FOREIGN KEY ("userId") REFERENCES "User"("id") ON DELETE CASCADE ON UPDATE CASCADE;
