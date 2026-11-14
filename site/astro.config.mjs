// @ts-check
import { defineConfig } from 'astro/config';

// The Saylark launch page: one static page, no client JS beyond a few lines inline.
export default defineConfig({
  site: 'https://saylark.shiptiffin.app',
  trailingSlash: 'ignore',
  build: { inlineStylesheets: 'always' },
});
