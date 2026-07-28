-- AlterTable
ALTER TABLE "User" ADD COLUMN     "captureStickers" BOOLEAN NOT NULL DEFAULT false;

-- CreateTable
CREATE TABLE "StickerAsset" (
    "id" TEXT NOT NULL,
    "userId" TEXT NOT NULL,
    "mediaId" TEXT NOT NULL,
    "hash" TEXT NOT NULL,
    "lastUsedAt" TIMESTAMP(3),
    "createdAt" TIMESTAMP(3) NOT NULL DEFAULT CURRENT_TIMESTAMP,

    CONSTRAINT "StickerAsset_pkey" PRIMARY KEY ("id")
);

-- CreateIndex
CREATE UNIQUE INDEX "StickerAsset_mediaId_key" ON "StickerAsset"("mediaId");

-- CreateIndex
CREATE INDEX "StickerAsset_userId_createdAt_idx" ON "StickerAsset"("userId", "createdAt");

-- CreateIndex
CREATE UNIQUE INDEX "StickerAsset_userId_hash_key" ON "StickerAsset"("userId", "hash");

-- AddForeignKey
ALTER TABLE "StickerAsset" ADD CONSTRAINT "StickerAsset_userId_fkey" FOREIGN KEY ("userId") REFERENCES "User"("id") ON DELETE CASCADE ON UPDATE CASCADE;

-- AddForeignKey
ALTER TABLE "StickerAsset" ADD CONSTRAINT "StickerAsset_mediaId_fkey" FOREIGN KEY ("mediaId") REFERENCES "Media"("id") ON DELETE CASCADE ON UPDATE CASCADE;
