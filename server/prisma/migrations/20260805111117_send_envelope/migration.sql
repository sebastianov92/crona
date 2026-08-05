-- Anti-baneo: envelope de envío por instancia (F2)
ALTER TABLE "Instance" ADD COLUMN "maxPerHour" INTEGER;
ALTER TABLE "Instance" ADD COLUMN "maxPerDay" INTEGER;
ALTER TABLE "Instance" ADD COLUMN "quietStart" INTEGER;
ALTER TABLE "Instance" ADD COLUMN "quietEnd" INTEGER;
ALTER TABLE "Instance" ADD COLUMN "jitterMinSec" INTEGER NOT NULL DEFAULT 60;
ALTER TABLE "Instance" ADD COLUMN "jitterMaxSec" INTEGER NOT NULL DEFAULT 300;
