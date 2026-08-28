/**
 * Metro asset modules for this fusion's own Noir circuits (assets/circuits/*.circuit).
 *
 * `require()` of an asset returns an opaque numeric module id, which is what `Asset.fromModule`
 * takes. The files are JSON in content, but they are registered under a distinct extension in
 * metro.config.js so Metro treats them as ASSETS rather than parsing a 3.3 MB object into the JS
 * bundle - see that file's comment.
 */
declare module '*.circuit' {
  const moduleId: number;
  export default moduleId;
}
