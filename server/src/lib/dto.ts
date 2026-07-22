import type { User } from "@prisma/client";

// Franjas por defecto de los botones rápidos (minutos del día)
export const DEFAULT_QUICK_HOURS = {
  morning: { start: 8 * 60, end: 9 * 60 },
  afternoon: { start: 15 * 60, end: 16 * 60 },
  evening: { start: 20 * 60, end: 21 * 60 },
};

// §15: User nunca expone passwordHash ni ntfyToken
export const userDTO = (u: User) => ({
  id: u.id,
  email: u.email,
  name: u.name,
  role: u.role,
  ntfyTopic: u.ntfyTopic,
  notifyOnSent: u.notifyOnSent,
  chatListCount: u.chatListCount,
  chatIncomingCount: u.chatIncomingCount,
  defaultInstanceId: u.defaultInstanceId,
  quickHours: (u.quickHours as object | null) ?? DEFAULT_QUICK_HOURS,
  createdAt: u.createdAt,
});
