// Expo requires a babel config; `app/` had none after the ibiza merge while
// `babel-preset-expo` sat in devDependencies — the dependency came across and the
// config that uses it did not, so the app could not bundle.
//
// ⛔ IBIZA'S THREE PLUGINS ARE DELIBERATELY NOT CARRIED. Each was a workaround for
// something this project solves better, and re-adding one would be a clamp:
//
//   `module-resolver` alias `@rarimo/rarime-rn-sdk` -> `./src/sdk/index`
//     Obsolete. That alias existed while the SDK was a forked in-tree copy. It is
//     now a real dependency (`github:quidmints/rarime-rn-sdk#main`) and resolves
//     out of node_modules — ibiza's own metro.config.js says so in the comment
//     that removed the matching metro mapping.
//
//   `module-resolver` alias `@iden3/js-crypto` -> `dist/browser/esm/index.js`
//     Obsolete, and this is the interesting one. The package publishes NO `main`,
//     `module`, `browser` or `react-native` field — only an `exports` map, whose
//     `browser` condition IS `./dist/browser/esm/index.js`, i.e. exactly what the
//     alias hard-coded. `metro.config.js` sets `unstable_enablePackageExports`,
//     and Metro's resolver conditions include `browser`, so the correct build is
//     selected by the package's own contract. Hard-coding the path again would
//     pin an internal file the package is free to move.
//
//   `react-native-dotenv` providing `@env`
//     Unused: zero `from "@env"` imports in this app.
module.exports = (api) => {
  api.cache(true);
  return { presets: [["babel-preset-expo", { jsxRuntime: "automatic" }]] };
};
