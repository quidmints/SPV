import { hexlify, JsonRpcProvider, toUtf8Bytes } from "ethers";
import { DocumentStatus, RarimePassport } from "@rarimo/rarime-rn-sdk";
import {
  PoseidonSMT__factory,
  RegistrationSimple,
  StateKeeper,
  StateKeeper__factory,
} from "@rarimo/rarime-rn-sdk";
import { NoirCircuitParams, NoirZKProof } from "@rarimo/rarime-rn-sdk";
import { Platform } from "react-native";
import { HashAlgorithm } from "@rarimo/rarime-rn-sdk";
import { createRegistrationSimpleContract } from "@rarimo/rarime-rn-sdk";
import { RarimeUtils } from "@rarimo/rarime-rn-sdk";
import { SignatureAlgorithm } from "@rarimo/rarime-rn-sdk";
import { toPaddedHex32, wrapPem } from "@rarimo/rarime-rn-sdk";
import { QueryProofParams } from "@rarimo/rarime-rn-sdk";
import { SparseMerkleTree } from "@rarimo/rarime-rn-sdk";
import { Poseidon } from "@iden3/js-crypto";
import { Time } from "@distributedlab/tools";
import {
  holderStateKeeper,
  getDocumentBond,
  DocStatus,
  DocumentBond,
} from "./holder/HolderContracts";

const ZERO_BYTES = new Uint8Array(64);

export interface RarimeUserConfiguration {
  userPrivateKey: string;
}

export interface RarimeAPIConfiguration {
  jsonRpcEvmUrl: string;
  rarimeApiUrl: string;
}

export interface RarimeContractsConfiguration {
  stateKeeperAddress: string;
  registerSimpleContractAddress: string;
  poseidonSmtAddress: string;
  /** OUR HolderRegistration contract — the holder-tree registration entrypoint
   *  (registerDocumentViaNoir/renewDocumentViaNoir/revokeDocumentViaSigner), distinct from
   *  upstream's registerSimpleContractAddress (whose addBond forbids a 2nd document per key). */
  holderRegistrationAddress: string;
}

export interface RarimeConfiguration {
  contractsConfiguration: RarimeContractsConfiguration;
  apiConfiguration: RarimeAPIConfiguration;
  userConfiguration: RarimeUserConfiguration;
}

export class Rarime {
  private config: RarimeConfiguration;

  constructor(config: RarimeConfiguration) {
    if (config.userConfiguration.userPrivateKey.startsWith("0x")) {
      config.userConfiguration.userPrivateKey =
        config.userConfiguration.userPrivateKey.slice(2);
    }

    if (config.userConfiguration.userPrivateKey.length !== 64) {
      throw new Error("Not valid private key");
    }

    this.config = config;
  }

  public async getPassportInfo(
    passport: RarimePassport
  ): Promise<
    [StateKeeper.PassportInfoStructOutput, StateKeeper.IdentityInfoStructOutput]
  > {
    const provider = new JsonRpcProvider(
      this.config.apiConfiguration.jsonRpcEvmUrl
    );

    const contract = StateKeeper__factory.connect(
      this.config.contractsConfiguration.stateKeeperAddress,
      provider
    );

    const passportKey = passport.getPassportKey();

    let passportKeyHex = toPaddedHex32(passportKey);

    const passportInfo = await contract.getPassportInfo(passportKeyHex);
    return passportInfo;
  }

  public async getDocumentStatus(
    passport: RarimePassport
  ): Promise<DocumentStatus> {
    const passportInfo = await this.getPassportInfo(passport);

    const activeIdentity = passportInfo?.[0].activeIdentity;

    const ZERO_BYTES_STRING =
      "0x" +
      Array.from(ZERO_BYTES)
        .map((b) => b.toString(16))
        .join("");
    if (activeIdentity === ZERO_BYTES_STRING) {
      return DocumentStatus.NotRegistered;
    }

    if (activeIdentity === this.config.userConfiguration.userPrivateKey) {
      return DocumentStatus.RegisteredWithThisPk;
    }

    return DocumentStatus.RegisteredWithOtherPk;
  }

  // Registers ONE document leaf under the holder root (profileKey). This is the SINGLE
  // issuance — its presentation doubles as the EUDI OpenID4VP presentation (see Eudi.ts).
  // Many-documents-one-holder and RENEWAL (supersede old leaf + link proof) are NOT done
  // here: they live in the holder tree (HolderTree.ts) and require the forked Rarimo
  // contracts/circuits (SCOPE.md §7.5/§7.8). The throws below are per-document guards
  // (idempotency + anti-theft), NOT the 1-key=1-document wall — that wall is the flat tree,
  // which the holder-rooted tree replaces.
  public async registerIdentity(passport: RarimePassport): Promise<String> {
    const passportStatus = await this.getDocumentStatus(passport);

    if (passportStatus === DocumentStatus.RegisteredWithOtherPk) {
      throw new Error("This document was registered with other Private Key");
    }

    if (passportStatus === DocumentStatus.RegisteredWithThisPk) {
      throw new Error("This document was registered with this Private Key");
    }

    const hashAlgoOID = passport.extractDGHashAlgo();

    const hashAlgo = HashAlgorithm.fromOID(hashAlgoOID);

    const hashLength = hashAlgo.getByteLength();

    const proof = await this.generateLiteRegisterProof(hashLength, passport);

    const verifySodResponse = await this.verifySodRequest(passport, proof);

    const verifySodResponseParsed = await verifySodResponse.json();

    const txCallData = this.buildLiteRegisterCalldata(
      verifySodResponseParsed,
      proof,
      passport
    );

    const liteRegisterResponse = await this.sendRegisterLiteTransaction(
      txCallData
    );

    const liteRegisterResponseParsed = await liteRegisterResponse.json();

    return liteRegisterResponseParsed.data.id;
  }

  /**
   * Generate the Noir register proof + get the backend signer's signature over it, WITHOUT
   * submitting to upstream's RegistrationSimple. Reuses the exact same on-device proof
   * generation and SOD-verification backend call as registerIdentity — HolderRegistration
   * deliberately reuses RegistrationSimple's signer set + signed-data format (see its own
   * docstring), so this material is valid for OUR registerDocumentViaNoir/renewDocumentViaNoir
   * too, not just upstream's registerSimpleViaNoir. Field mapping verified directly against
   * buildLiteRegisterCalldata below: dgCommit/dg1Hash come from the proof's own public signals,
   * publicKey/verifier/signature come from the backend's SOD-verification response.
   */
  public async generateRegistrationMaterial(passport: RarimePassport): Promise<{
    passport: {
      dgCommit: bigint;
      dg1Hash: string;
      publicKey: string;
      passportHash: string;
      verifier: string;
    };
    signature: string;
    zkPoints: string;
  }> {
    const hashAlgoOID = passport.extractDGHashAlgo();
    const hashAlgo = HashAlgorithm.fromOID(hashAlgoOID);
    const hashLength = hashAlgo.getByteLength();

    const proof = await this.generateLiteRegisterProof(hashLength, passport);
    const verifySodResponse = await this.verifySodRequest(passport, proof);
    const verifySodResponseParsed = await verifySodResponse.json();

    return {
      passport: {
        dgCommit: BigInt("0x" + proof.pub_signals[0]),
        dg1Hash: "0x" + proof.pub_signals[1],
        publicKey: verifySodResponseParsed.data.attributes.public_key,
        passportHash: toPaddedHex32(passport.getPassportHash()),
        verifier: verifySodResponseParsed.data.attributes.verifier,
      },
      signature: verifySodResponseParsed.data.attributes.signature,
      zkPoints: "0x" + proof.proof,
    };
  }

  /**
   * Submit arbitrary calldata to an arbitrary destination via the SAME registration-relayer
   * endpoint sendRegisterLiteTransaction uses — that endpoint is already generic (destination is
   * a request body field, not hardcoded), so this generalizes it instead of duplicating the HTTP
   * call. Used to submit to OUR HolderRegistration contract instead of upstream's
   * RegistrationSimple.
   */
  public async submitViaRelayer(txCallData: string, destination: string): Promise<string> {
    const response = await fetch(
      this.config.apiConfiguration.rarimeApiUrl +
        "/integrations/registration-relayer/v1/register",
      {
        method: "POST",
        headers: { "Content-Type": "application/json" },
        body: JSON.stringify({
          data: { tx_data: txCallData, no_send: false, destination },
        }),
      }
    );

    if (!response.ok) {
      throw new Error(`HTTP error ${response.status}`);
    }

    const parsed = await response.json();
    return parsed.data.id;
  }

  public async getSMTProof(
    passport: RarimePassport
  ): Promise<SparseMerkleTree.ProofStruct> {
    const provider = new JsonRpcProvider(
      this.config.apiConfiguration.jsonRpcEvmUrl
    );

    const contract = PoseidonSMT__factory.connect(
      this.config.contractsConfiguration.poseidonSmtAddress,
      provider
    );

    const smtProofIndex = this.getSMTProofIndex(passport);

    return contract.getProof(smtProofIndex);
  }

  /**
   * Read a document bond from OUR HolderStateKeeper (holder tree). Replaces the upstream
   * getPassportInfo for holder-tree documents — supplies seq + issueTimestamp the query circuit
   * needs (the circuit's value = Poseidon3(dgCommit, seq, timestamp)). See HOLDER-TREE-NOTES.
   */
  public async getDocumentBond(documentKey: string): Promise<DocumentBond> {
    const provider = new JsonRpcProvider(
      this.config.apiConfiguration.jsonRpcEvmUrl
    );
    const stateKeeper = holderStateKeeper(
      this.config.contractsConfiguration.stateKeeperAddress,
      provider
    );
    return getDocumentBond(stateKeeper, documentKey);
  }

  public async generateQueryProof(
    queryProofParams: QueryProofParams,
    passport: RarimePassport
  ): Promise<NoirZKProof> {
    const circuit = NoirCircuitParams.fromName("query_identity");

    await NoirCircuitParams.downloadTrustedSetup();

    const byteCode = await circuit.downloadByteCode();

    const profileKey =
      "0x" +
      RarimeUtils.getProfileKey(this.config.userConfiguration.userPrivateKey);

    // Holder tree: source (seq, timestamp) + binding from OUR HolderStateKeeper.getDocument,
    // NOT upstream getPassportInfo (which is empty for holder-tree documents).
    const documentKey = toPaddedHex32(passport.getPassportKey());
    const bond = await this.getDocumentBond(documentKey);

    if (bond.holderRoot.toLowerCase() !== profileKey.toLowerCase()) {
      throw new Error(
        `document not bound to this holder key. holderRoot = ${bond.holderRoot}, profileKey = ${profileKey}`
      );
    }
    if (bond.status !== DocStatus.Current) {
      throw new Error(
        `document is not current (status = ${DocStatus[bond.status]}); superseded/revoked/unregistered cannot be presented`
      );
    }

    const smtProof = await this.getSMTProof(passport);

    const isAndroid = Platform.OS === "android";
    const inputs = {
      event_id: isAndroid
        ? toPaddedHex32(queryProofParams.eventId)
        : queryProofParams.eventId, //from input
      event_data: isAndroid
        ? toPaddedHex32(queryProofParams.eventData)
        : queryProofParams.eventData,
      id_state_root: smtProof.root, //from SMT
      selector: isAndroid
        ? toPaddedHex32(queryProofParams.selector)
        : queryProofParams.selector, //from input
      current_date: hexlify(toUtf8Bytes(new Time().format("YYMMDD"))),
      timestamp_lowerbound: isAndroid
        ? toPaddedHex32(queryProofParams.timestampLowerbound)
        : queryProofParams.timestampLowerbound, //from input
      timestamp_upperbound: isAndroid
        ? toPaddedHex32(queryProofParams.timestampUpperbound)
        : queryProofParams.timestampUpperbound, //from input
      identity_count_lowerbound: isAndroid
        ? toPaddedHex32(queryProofParams.identityCountLowerbound)
        : queryProofParams.identityCountLowerbound, //from input
      identity_count_upperbound: isAndroid
        ? toPaddedHex32(queryProofParams.identityCountUpperbound)
        : queryProofParams.identityCountUpperbound, //from input
      birth_date_lowerbound: isAndroid
        ? toPaddedHex32(queryProofParams.birthDateLowerbound)
        : queryProofParams.birthDateLowerbound, //from input
      birth_date_upperbound: isAndroid
        ? toPaddedHex32(queryProofParams.birthDateUpperbound)
        : queryProofParams.birthDateUpperbound, //from input
      expiration_date_lowerbound: isAndroid
        ? toPaddedHex32(queryProofParams.expirationDateLowerbound)
        : queryProofParams.expirationDateLowerbound, //from input
      expiration_date_upperbound: isAndroid
        ? toPaddedHex32(queryProofParams.expirationDateUpperbound)
        : queryProofParams.expirationDateUpperbound, //from input
      citizenship_mask: isAndroid
        ? toPaddedHex32(queryProofParams.citizenshipMask)
        : queryProofParams.citizenshipMask, //from input
      sk_identity: "0x" + this.config.userConfiguration.userPrivateKey,
      pk_passport_hash: toPaddedHex32(passport.getPassportKey()),
      dg1: NoirCircuitParams.formatArray(
        Array.from(passport.dataGroup1).map((byteValue) =>
          byteValue.toString()
        ),
        isAndroid
      ),
      siblings: smtProof.siblings, //from SMT
      timestamp: toPaddedHex32(bond.issueTimestamp), // holder tree: leaf issueTimestamp
      identity_counter: toPaddedHex32(bond.seq), // holder tree: leaf supersession seq (== circuit identity_counter)
    };

    return circuit.prove(JSON.stringify(inputs), byteCode);
  }

  public getEventNullifier(eventId: bigint): string {
    const privateKeyPoseidonHash = Poseidon.hash([
      BigInt("0x" + this.config.userConfiguration.userPrivateKey),
    ]);

    const eventData = Poseidon.hash([
      BigInt("0x" + this.config.userConfiguration.userPrivateKey),
      privateKeyPoseidonHash,
      eventId,
    ]);

    return toPaddedHex32(eventData);
  }

  private buildLiteRegisterCalldata(
    verifySodResponseParsed: any,
    proof: NoirZKProof,
    passport: RarimePassport
  ): string {
    const registrationSimpleContract = createRegistrationSimpleContract(
      this.config.contractsConfiguration.registerSimpleContractAddress,
      new JsonRpcProvider(this.config.apiConfiguration.jsonRpcEvmUrl)
    );

    const passportStruct: RegistrationSimple.PassportStruct = {
      dgCommit: BigInt("0x" + proof.pub_signals[0]),
      dg1Hash: Buffer.from(proof.pub_signals[1], "hex"),
      publicKey: verifySodResponseParsed.data.attributes.public_key,
      passportHash: toPaddedHex32(passport.getPassportHash()),
      verifier: verifySodResponseParsed.data.attributes.verifier,
    };

    const txCallData =
      registrationSimpleContract.contractInterface.encodeFunctionData(
        "registerSimpleViaNoir",
        [
          "0x" +
            RarimeUtils.getProfileKey(
              this.config.userConfiguration.userPrivateKey
            ),
          passportStruct,
          verifySodResponseParsed.data.attributes.signature,
          "0x" + proof.proof,
        ]
      );

    return txCallData;
  }

  private async generateLiteRegisterProof(
    hashLength: number,
    passport: RarimePassport
  ): Promise<NoirZKProof> {
    const circuit = NoirCircuitParams.fromName("register_light_" + hashLength);

    await NoirCircuitParams.downloadTrustedSetup();

    const byteCode = await circuit.downloadByteCode();

    const isAndroid = Platform.OS === "android";
    let inputs = {
      dg1: NoirCircuitParams.formatArray(
        Array.from(passport.dataGroup1).map((byteValue) =>
          byteValue.toString()
        ),
        isAndroid
      ),
      sk_identity: "0x" + this.config.userConfiguration.userPrivateKey,
    };

    return circuit.prove(JSON.stringify(inputs), byteCode);
  }

  private getSMTProofIndex(passport: RarimePassport): string {
    const passportKey = passport.getPassportKey();

    const profileKey = RarimeUtils.getProfileKey(
      this.config.userConfiguration.userPrivateKey
    );

    const poseidonHash = Poseidon.hash([
      passportKey,
      BigInt("0x" + profileKey),
    ]);

    return toPaddedHex32(poseidonHash);
  }
  private async verifySodRequest(
    passport: RarimePassport,
    proof: NoirZKProof
  ): Promise<Response> {
    const pubSignalsBuffers = proof.pub_signals.map((sig) =>
      Buffer.from(sig, "hex")
    );

    const proofBuffer = Buffer.from(proof.proof, "hex");

    const proofBytes = Buffer.concat([...pubSignalsBuffers, proofBuffer]);

    const verifySodRequest = {
      data: {
        id: "",
        type_field: "register",
        attributes: {
          document_sod: {
            hash_algorithm: HashAlgorithm.fromOID(
              passport.extractDGHashAlgo()
            ).toString(),
            signature_algorithm: SignatureAlgorithm.fromOID(
              passport.getSignatureAlgorithm()
            ).toString(),
            signed_attributes:
              "0x" +
              Buffer.from(passport.extractSignedAttributes()).toString("hex"),
            encapsulated_content:
              "0x" +
              Buffer.from(passport.extractEncapsulatedContent()).toString(
                "hex"
              ),
            signature:
              "0x" + Buffer.from(passport.extractSignature()).toString("hex"),
            pem_file: wrapPem(passport.getCertificate()),
            dg15: passport.dataGroup15
              ? "0x" + Buffer.from(passport.dataGroup15).toString("hex")
              : "",
            aa_signature: passport.aaSignature
              ? "0x" + Buffer.from(passport.aaSignature).toString("hex")
              : "",
            sod: "0x" + Buffer.from(passport.sod).toString("hex"),
          },
          zk_proof: Buffer.from(proofBytes).toString("base64"),
        },
      },
    };

    const verifySodResponse = await fetch(
      this.config.apiConfiguration.rarimeApiUrl +
        "/integrations/incognito-light-registrator/v1/registerid",
      {
        method: "POST",
        headers: {
          "Content-Type": "application/json",
        },
        body: JSON.stringify(verifySodRequest),
      }
    );

    if (!verifySodResponse.ok) {
      throw new Error(`HTTP error ${verifySodResponse.status}`);
    }

    return verifySodResponse;
  }

  private async sendRegisterLiteTransaction(
    txCallData: string
  ): Promise<Response> {
    const lite_register_request = {
      data: {
        tx_data: txCallData,
        no_send: false,
        destination:
          this.config.contractsConfiguration.registerSimpleContractAddress,
      },
    };

    const liteRegisterResponse = await fetch(
      this.config.apiConfiguration.rarimeApiUrl +
        "/integrations/registration-relayer/v1/register",
      {
        method: "POST",
        headers: {
          "Content-Type": "application/json",
        },
        body: JSON.stringify(lite_register_request),
      }
    );

    if (!liteRegisterResponse.ok) {
      const errorData = await liteRegisterResponse.json();
      throw new Error(
        `HTTP error ${liteRegisterResponse.status}: ${JSON.stringify(
          errorData
        )}`
      );
    }

    return liteRegisterResponse;
  }
}
