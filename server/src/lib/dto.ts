import type { User } from "@prisma/client";

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
  createdAt: u.createdAt,
});
