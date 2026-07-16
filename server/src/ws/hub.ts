import type { WebSocket } from "@fastify/websocket";

const conns = new Map<string, Set<WebSocket>>(); // userId → sockets

export function register(userId: string, socket: WebSocket) {
  if (!conns.has(userId)) conns.set(userId, new Set());
  conns.get(userId)!.add(socket);
  socket.on("close", () => conns.get(userId)?.delete(socket));
}

export function broadcast(userId: string, type: string, payload: unknown) {
  const msg = JSON.stringify({ type, payload });
  conns.get(userId)?.forEach((s) => s.readyState === 1 && s.send(msg));
}
