import type { Config } from "tailwindcss";

export default {
  darkMode: "class",
  content: ["./index.html", "./src/**/*.{ts,tsx}"],
  theme: {
    extend: {
      colors: {
        // Named tokens on top of Tailwind's slate/zinc scale so the
        // "supervisor room" feel (deep, cool, alert-ready) is a deliberate
        // choice rather than raw utility classes scattered everywhere.
        surface: {
          DEFAULT: "#0B0E14",   // app background — cooler & deeper than slate-950
          raised: "#12161F",    // cards
          inset: "#080A0F",     // wells (feed panels, code-like areas)
        },
        border: { DEFAULT: "#1E2430" },
        accent: {
          DEFAULT: "#3DD6C1",   // signal teal — "live/connected" color
          dim: "#1F5C54",
        },
        alert: {
          DEFAULT: "#F0475A",   // incident red
          dim: "#4A1F27",
        },
        warn: { DEFAULT: "#E8A33D" },
        ok: { DEFAULT: "#3DD68C" },
      },
      fontFamily: {
        sans: ["Inter", "system-ui", "sans-serif"],
        mono: ["'JetBrains Mono'", "ui-monospace", "monospace"],
      },
      boxShadow: {
        glow: "0 0 0 1px rgba(61,214,193,0.3), 0 0 12px rgba(61,214,193,0.25)",
      },
      keyframes: {
        pulseDot: {
          "0%,100%": { opacity: "1" },
          "50%": { opacity: "0.35" },
        },
        rowIn: {
          "0%": { opacity: "0", transform: "translateY(-4px)" },
          "100%": { opacity: "1", transform: "translateY(0)" },
        },
      },
      animation: {
        pulseDot: "pulseDot 1.6s ease-in-out infinite",
        rowIn: "rowIn 0.25s ease-out",
      },
    },
  },
  plugins: [],
} satisfies Config;
