// Document persistence for IdentityVault. The host app supplies one of these.
// The holder secret is NOT persisted here — it is derived from the device-enclave RootSeed
// (see identity/root.ts: getOrCreateRootMnemonic + deriveSkIdentity).

import * as SecureStore from "expo-secure-store";
import { IdentityVaultStore, StoredDocument } from "./IdentityVault";

/** Volatile store — for the demo shell / tests only. */
export class InMemoryIdentityVaultStore implements IdentityVaultStore {
  private docs: StoredDocument[] = [];

  async getDocuments() {
    return [...this.docs];
  }
  async setDocuments(docs: StoredDocument[]) {
    this.docs = [...docs];
  }
}

/** Production store — document metadata in the secure store (the holder root lives in root.ts). */
export class SecureIdentityVaultStore implements IdentityVaultStore {
  private static readonly DOCS_KEY = "quid.wallet.documents";

  async getDocuments(): Promise<StoredDocument[]> {
    const raw = await SecureStore.getItemAsync(SecureIdentityVaultStore.DOCS_KEY);
    return raw ? (JSON.parse(raw) as StoredDocument[]) : [];
  }
  async setDocuments(docs: StoredDocument[]): Promise<void> {
    await SecureStore.setItemAsync(SecureIdentityVaultStore.DOCS_KEY, JSON.stringify(docs));
  }
}
