// Types for the `npm:` specifiers the Edge Functions import.
//
// Deno resolves `npm:<pkg>@<range>` when it bundles a function, so the runtime
// half of this needs nothing. A TypeScript server cannot resolve that scheme,
// though, and reports TS2307 ("Cannot find module 'npm:@supabase/supabase-js@2'")
// on the one import `admin-create-user/index.ts` makes — so each specifier is
// declared here as the npm package it names (the same package Deno downloads at
// deploy time), and the editor sees its real types instead of an unresolved
// import. The packages themselves are this folder's `package.json`
// devDependencies; `tsconfig.json` includes this file.
//
// Nothing imports it: it is library-wide only, which is why the bundler never
// sees it and a deployment is unaffected.
//
// Importing another npm package from a function? Add its specifier below, and
// the package itself to `devDependencies`.

declare module "npm:@supabase/supabase-js@2" {
  export * from "@supabase/supabase-js";
}
