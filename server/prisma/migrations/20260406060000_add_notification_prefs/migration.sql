-- Notification preferences on iPhone devices. Mac devices also get the
-- columns but they're meaningless there and stay at their defaults.
ALTER TABLE "Device" ADD COLUMN "notifyOnCompletion" BOOLEAN NOT NULL DEFAULT false;
ALTER TABLE "Device" ADD COLUMN "notifyOnApproval" BOOLEAN NOT NULL DEFAULT false;
ALTER TABLE "Device" ADD COLUMN "notifyOnError" BOOLEAN NOT NULL DEFAULT false;
