import { defineConfig } from "@neon/config/v1";

export default defineConfig({
  // Postgres is included in every Neon branch. Preserve existing services
  // and branch settings; this app uses Ecto migrations to manage its schema.
});
