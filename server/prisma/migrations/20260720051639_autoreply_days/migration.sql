-- AlterTable
ALTER TABLE "AutoReply" ADD COLUMN     "activeDays" INTEGER[] DEFAULT ARRAY[]::INTEGER[];
