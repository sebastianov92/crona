import { defineConfig } from "vite";
import react from "@vitejs/plugin-react";

export default defineConfig({
  plugins: [react()],
  base: "/app/",
  server: {
    proxy: {
      // dev: la API corre en :3000
      "^/(auth|me|admin|instances|messages|media|autoreplies|health)": {
        target: "http://localhost:3000",
        changeOrigin: true,
      },
      "/ws": { target: "ws://localhost:3000", ws: true },
    },
  },
});
