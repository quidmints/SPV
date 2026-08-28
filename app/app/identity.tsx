// Route: /identity — mounts the identity wallet inside seeker's expo-router tree.
// Kept thin on purpose. The screen itself lives with the rest of the feature under
// `features/identity/`, matching `features/account` and `features/network`.
export { default } from "../features/identity/IdentityScreen";
