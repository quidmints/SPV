// The identity-wallet's former `App.tsx`, carried over verbatim apart from its imports and
// its name. It was a standalone Expo entry point; seeker owns the entry point now, so this is
// the SCREEN and `app/identity.tsx` is the route that mounts it.
//
// ⚠️ The placeholder addresses below are the ORIGINAL's and are still placeholders — they were
// never pointed at our deployed HolderStateKeeper / HolderRegistration. Carrying them across
// unchanged is deliberate: the merge must not invent deployment values it cannot verify.
import React from "react";
import { SafeAreaView, ScrollView, Text, View } from "react-native";

import { styles } from "./ui/theme";

import { IdentityVault, IdentityVaultConfig } from "./identity/IdentityVault";
import { InMemoryIdentityVaultStore } from "./identity/store";
import { StoredDocument } from "./identity/IdentityVault";

// TODO(fork wiring): point these at OUR deployed HolderStateKeeper / HolderRegistration
// (app/contracts/holder) + our relayer/RPC. Placeholders until deploy.
const CONFIG: IdentityVaultConfig = {
  contractsConfiguration: {
    stateKeeperAddress: "0x0000000000000000000000000000000000000000",
    registerSimpleContractAddress: "0x0000000000000000000000000000000000000000",
    poseidonSmtAddress: "0x0000000000000000000000000000000000000000",
    holderRegistrationAddress: "0x0000000000000000000000000000000000000000",
  },
  apiConfiguration: {
    jsonRpcEvmUrl: "https://rpc.example/holder-tree",
    rarimeApiUrl: "https://relayer.example",
  },
};

export default function IdentityScreen() {
  const vaultRef = React.useRef(new IdentityVault(CONFIG, new InMemoryIdentityVaultStore()));
  const [holderRoot, setHolderRoot] = React.useState<string>("…");
  const [docs, setDocs] = React.useState<StoredDocument[]>([]);
  const [citizenships, setCitizenships] = React.useState<string[]>([]);

  React.useEffect(() => {
    (async () => {
      const vault = vaultRef.current;
      const root = await vault.holderRoot();
      setHolderRoot(root.profileKey);
      setDocs(await vault.listDocuments());
      setCitizenships(await vault.citizenships());
    })();
  }, []);

  return (
    <SafeAreaView style={styles.safe}>
      <ScrollView contentContainerStyle={styles.container}>
        <Text style={styles.h1}>Identity Wallet</Text>
        <Text style={styles.subtle}>One holder key · many documents (multi-citizenship + renewal/revocation)</Text>

        <View style={styles.card}>
          <Text style={styles.label}>Holder root (the ONE key all documents bind to)</Text>
          <Text style={styles.mono} numberOfLines={1} ellipsizeMode="middle">0x{holderRoot}</Text>
        </View>

        <View style={styles.card}>
          <Text style={styles.label}>Citizenships ({citizenships.length})</Text>
          <Text style={styles.value}>{citizenships.length ? citizenships.join(", ") : "— (no current documents yet)"}</Text>
        </View>

        <Text style={styles.section}>Documents ({docs.length})</Text>
        {docs.length === 0 ? (
          <Text style={styles.subtle}>No documents. Scan a passport to add one (multi-citizenship: add several under the same holder key).</Text>
        ) : (
          docs.map((d) => (
            <View key={d.documentKey} style={styles.card}>
              <Text style={styles.value}>{d.docType}{d.country ? ` · ${d.country}` : ""}</Text>
              <Text style={styles.mono} numberOfLines={1} ellipsizeMode="middle">{d.documentKey}</Text>
              <Text style={styles.subtle}>status: {d.status}{d.notAfter ? ` · expires ${new Date(d.notAfter * 1000).toISOString().slice(0, 10)}` : ""}</Text>
            </View>
          ))
        )}

        <View style={styles.note}>
          <Text style={styles.noteText}>
            This shell drives <Text style={styles.bold}>IdentityVault</Text> (one-key-multiple-documents). Live add/renew/revoke need: (1) a scanned passport (RarimePassport from NFC), (2) OUR deployed HolderStateKeeper/HolderRegistration, (3) the forked query circuit for "current document". See README — three forks.
          </Text>
        </View>
      </ScrollView>
    </SafeAreaView>
  );
}
