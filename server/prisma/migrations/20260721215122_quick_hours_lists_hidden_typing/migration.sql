-- AlterTable
ALTER TABLE "ScheduledMessage" ADD COLUMN     "typingMs" INTEGER;

-- AlterTable
ALTER TABLE "User" ADD COLUMN     "quickHours" JSONB;

-- CreateTable
CREATE TABLE "HiddenChat" (
    "id" TEXT NOT NULL,
    "userId" TEXT NOT NULL,
    "instanceId" TEXT NOT NULL,
    "jid" TEXT NOT NULL,
    "hiddenAt" TIMESTAMP(3) NOT NULL DEFAULT CURRENT_TIMESTAMP,

    CONSTRAINT "HiddenChat_pkey" PRIMARY KEY ("id")
);

-- CreateTable
CREATE TABLE "ContactList" (
    "id" TEXT NOT NULL,
    "userId" TEXT NOT NULL,
    "instanceId" TEXT NOT NULL,
    "name" TEXT NOT NULL,
    "createdAt" TIMESTAMP(3) NOT NULL DEFAULT CURRENT_TIMESTAMP,

    CONSTRAINT "ContactList_pkey" PRIMARY KEY ("id")
);

-- CreateTable
CREATE TABLE "ContactListMember" (
    "id" TEXT NOT NULL,
    "listId" TEXT NOT NULL,
    "jid" TEXT NOT NULL,
    "name" TEXT NOT NULL,
    "pictureUrl" TEXT,
    "kind" "RecipientKind" NOT NULL DEFAULT 'CONTACT',

    CONSTRAINT "ContactListMember_pkey" PRIMARY KEY ("id")
);

-- CreateIndex
CREATE UNIQUE INDEX "HiddenChat_userId_instanceId_jid_key" ON "HiddenChat"("userId", "instanceId", "jid");

-- CreateIndex
CREATE UNIQUE INDEX "ContactListMember_listId_jid_key" ON "ContactListMember"("listId", "jid");

-- AddForeignKey
ALTER TABLE "HiddenChat" ADD CONSTRAINT "HiddenChat_userId_fkey" FOREIGN KEY ("userId") REFERENCES "User"("id") ON DELETE CASCADE ON UPDATE CASCADE;

-- AddForeignKey
ALTER TABLE "ContactList" ADD CONSTRAINT "ContactList_userId_fkey" FOREIGN KEY ("userId") REFERENCES "User"("id") ON DELETE CASCADE ON UPDATE CASCADE;

-- AddForeignKey
ALTER TABLE "ContactListMember" ADD CONSTRAINT "ContactListMember_listId_fkey" FOREIGN KEY ("listId") REFERENCES "ContactList"("id") ON DELETE CASCADE ON UPDATE CASCADE;
