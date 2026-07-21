-- AlterEnum
ALTER TYPE "MessageType" ADD VALUE 'AUDIO';

-- AlterTable
ALTER TABLE "Recipient" ADD COLUMN     "alias" TEXT;
