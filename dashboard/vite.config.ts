import { defineConfig } from "vite";
import react from "@vitejs/plugin-react";
import path from "path";

export default defineConfig({
  plugins: [react()],
  resolve: {
    alias: { "@": path.resolve(__dirname, "./src") },
  },
  build: {
    rollupOptions: {
      output: {
        /*
         * Split the vendor trees out of the app bundle.
         *
         * Everything used to land in one ~850 kB chunk (Vite warned about it),
         * so a one-line page change invalidated React, Recharts, d3, lodash and
         * the Supabase client along with it. These three groups change far less
         * often than app code, so a deploy now re-downloads only the small app
         * chunk while the vendor chunks stay cached.
         */
        manualChunks: {
          react: ["react", "react-dom", "react-router-dom"],
          charts: ["recharts"],
          supabase: ["@supabase/supabase-js"],
        },
      },
    },
  },
});
