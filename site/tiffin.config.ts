// The Saylark launch page (saylark.shiptiffin.app) on ShipTiffin: a static Astro site, built on the box from this folder.
// Deploy: tiffin deploy. After a config edit: tiffin plan, then tiffin apply --confirm <hash>.
export default {
  project: "saylark",
  keepVersions: 2,
  apps: {
    site: {
      framework: "static",
      routes: ["saylark"],
      output: "dist",
    },
  },
};
