import { defineConfig } from "vite";
import path from "path";

export default defineConfig({
  root: "demo",
  publicDir: path.resolve(__dirname, "public"),
  build: {
    outDir: path.resolve(__dirname, "dist/demo"),
    emptyOutDir: true,
  },
  server: {
    port: 3000,
    open: true,
    headers: {
      // Required for SharedArrayBuffer / OPFS
      "Cross-Origin-Opener-Policy": "same-origin",
      "Cross-Origin-Embedder-Policy": "require-corp",
    },
  },
  assetsInclude: ["**/*.wasm"],
  resolve: {
    alias: {
      "@": path.resolve(__dirname, "src"),
    },
  },
});
