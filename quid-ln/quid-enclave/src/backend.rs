//! Trusted-execution BACKEND abstraction: which attested-execution environment
//! the node runs under, and the policy for what each hosting role may use.
//!
//! QU!D custody keys — the born-in-enclave [`RootSeed`] and everything derived
//! from it, including the EVM signing key — must be protected FROM THE HOST for
//! any node that serves OTHERS (the QuidMint fleet, or a shared family-plan hop).
//! That protection is a TEE + remote attestation: the served LP verifies the
//! node's measurement before trusting it, and the host operator can never see the
//! keys. Modifying the code changes the measurement, so a tampered node fails
//! attestation and the LPs refuse it.
//!
//! An INDIVIDUAL self-host is its own trust root: it runs its own node for its own
//! funds, so there is no one to defraud but itself. It MAY run without a TEE
//! (self-trust); a TEE there only adds protection against its own machine being
//! compromised.
//!
//! Backend split: SGX is a distinct *compile-time* target (`x86_64-fortanix-
//! unknown-sgx`). The confidential-VM backends (SEV-SNP / TDX / Nitro) run the
//! plain *host* build inside an attested VM and are distinguished at RUNTIME.
//!
//! [`RootSeed`]: https://docs.rs/quid-common
//!
//! Seal / attest wiring per backend lives in `platform` (SGX today); the
//! confidential-VM backends' report-fetch + measurement-bound sealing are the
//! hardware tail (verifiable only on real CC hardware, like SGX's own tail).

/// The trusted-execution backend the process is running under.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Backend {
    /// Intel SGX process enclave (compile-time target). EGETKEY seal, DCAP quote.
    Sgx,
    /// AMD SEV-SNP confidential VM. Plain host binary; `SNP_GET_REPORT`
    /// attestation (64-byte report_data), `SNP_GET_DERIVED_KEY` sealing.
    SevSnp,
    /// Intel TDX confidential VM. `TDREPORT` → `TDQUOTE` (64-byte report_data).
    Tdx,
    /// AWS Nitro Enclave. NSM attestation document (user_data + PCRs).
    Nitro,
    /// No TEE (plain host). Self-trust ONLY — individual self-host. No sealing
    /// against the host, no attestation; REFUSED for any serves-others role.
    None,
}

impl Backend {
    /// Whether this backend can, in principle, produce a remote-attestation
    /// document (so a counterparty could verify the exact code). Distinct from
    /// [`Self::custody_ready`]: a backend may be attestation-capable in hardware
    /// yet not have its sealing wired+verified here yet.
    pub fn is_attested(self) -> bool {
        !matches!(self, Backend::None)
    }

    /// Whether this backend's KEY SEALING is hardware-bound AND actually
    /// implemented + verified in *this* codebase — i.e. the custody keys are
    /// genuinely protected from the host. This is the property a serves-others
    /// role gates on, and it FAILS CLOSED: a backend is custody-ready ONLY when we
    /// have wired + verified its seal, never on the mere presence of the hardware.
    ///
    /// - `Sgx`: EGETKEY seal (implemented). → true
    /// - `SevSnp`: `SNP_GET_DERIVED_KEY` measurement-bound seal (implemented against
    ///   the documented ABI; fail-closed; the ioctl happy-path is a hardware tail
    ///   verified on real SEV-SNP, like SGX's own EGETKEY). → true
    /// - `None`: mock seal (the host can read the sealed blob). → false (self-trust)
    /// - `Tdx` / `Nitro`: attestation-capable, but their seal (TDX vTPM / Nitro KMS)
    ///   is NOT yet wired, so they fall back to the mock seal — INSECURE for serving
    ///   others — and are false here. Each flips to true in the same change that
    ///   lands + verifies its real seal, so we never *guess* a CVM is custody-safe.
    pub fn custody_ready(self) -> bool {
        matches!(self, Backend::Sgx | Backend::SevSnp)
    }

    pub fn as_str(self) -> &'static str {
        match self {
            Backend::Sgx => "sgx",
            Backend::SevSnp => "sev-snp",
            Backend::Tdx => "tdx",
            Backend::Nitro => "nitro",
            Backend::None => "none",
        }
    }
}

/// Detect the backend. SGX is a compile-time target; the confidential-VM backends
/// run the plain host build and are detected at runtime from the guest attestation
/// driver device nodes the kernel exposes only inside the respective CVM.
pub fn detect() -> Backend {
    #[cfg(target_env = "sgx")]
    {
        Backend::Sgx
    }
    #[cfg(not(target_env = "sgx"))]
    {
        detect_host()
    }
}

#[cfg(not(target_env = "sgx"))]
fn detect_host() -> Backend {
    use std::path::Path;
    // Guest attestation driver nodes, present only inside the respective CVM.
    // (First-pass detection by device-node presence; a CPUID/MSR cross-check is a
    // later hardening — a plain host simply exposes none of these.)
    if Path::new("/dev/sev-guest").exists() {
        Backend::SevSnp
    } else if Path::new("/dev/tdx_guest").exists()
        || Path::new("/dev/tdx-guest").exists()
        || Path::new("/sys/kernel/config/tsm/report").exists()
    {
        Backend::Tdx
    } else if Path::new("/dev/nsm").exists() {
        Backend::Nitro
    } else {
        Backend::None
    }
}

/// A node's HOSTING ROLE — who it serves — which drives the attestation
/// requirement. Read from configuration at boot (the operator declares it).
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum HostingRole {
    /// The QuidMint fleet: one deployment serves MANY unrelated LPs.
    Fleet,
    /// A shared family-plan hop: serves a defined group of LPs.
    Family,
    /// An individual self-host: serves only its own operator's funds.
    Individual,
}

impl HostingRole {
    /// Fleet + Family serve OTHERS, who rely on attestation to trust the node.
    pub fn serves_others(self) -> bool {
        matches!(self, HostingRole::Fleet | HostingRole::Family)
    }

    /// Parse from a config string (`QUID_HOSTING_ROLE`). Defaults are the
    /// caller's concern — this only maps known values.
    pub fn parse(s: &str) -> Option<Self> {
        match s.trim().to_ascii_lowercase().as_str() {
            "fleet" => Some(Self::Fleet),
            "family" => Some(Self::Family),
            "individual" | "self" | "self-host" => Some(Self::Individual),
            _ => None,
        }
    }
}

/// Error returned when a serves-others role is asked to run without hardware-bound
/// key custody that is actually wired + verified ([`Backend::custody_ready`]).
#[derive(Debug, Clone, Copy)]
pub struct RoleRequiresAttestation {
    pub role: HostingRole,
    pub backend: Backend,
}

impl core::fmt::Display for RoleRequiresAttestation {
    fn fmt(&self, f: &mut core::fmt::Formatter<'_>) -> core::fmt::Result {
        if self.backend.is_attested() {
            // A TEE was detected, but its sealed key custody isn't wired+verified
            // here yet — fail closed rather than fall back to the mock seal.
            write!(
                f,
                "hosting role {:?} serves other LPs, but the detected backend \
                 ({}) does not yet have verified hardware-bound key custody in \
                 this build (fail-closed — it would fall back to an insecure mock \
                 seal). Use SGX, or run this as an individual self-host.",
                self.role,
                self.backend.as_str(),
            )
        } else {
            write!(
                f,
                "hosting role {:?} serves other LPs and REQUIRES a TEE with \
                 hardware-bound key custody, but no TEE was detected \
                 (backend=none). A non-attested device may only run an individual \
                 self-host.",
                self.role,
            )
        }
    }
}

impl std::error::Error for RoleRequiresAttestation {}

/// Enforce the backend-vs-role policy: a serves-others role (fleet / family hop)
/// REQUIRES a [custody-ready][`Backend::custody_ready`] backend — its sealing must
/// be hardware-bound AND wired+verified here, so the host genuinely cannot read the
/// custody keys the served LPs depend on. This FAILS CLOSED: a detected-but-not-yet-
/// wired CVM is refused for serving others (never silently mock-sealed). An
/// individual self-host is its own trust root and may run on ANY backend, including
/// [`Backend::None`].
pub fn require_backend_for_role(
    role: HostingRole,
    backend: Backend,
) -> Result<(), RoleRequiresAttestation> {
    if role.serves_others() && !backend.custody_ready() {
        Err(RoleRequiresAttestation { role, backend })
    } else {
        Ok(())
    }
}

#[cfg(test)]
mod test {
    use super::*;

    #[test]
    fn only_none_is_unattested() {
        assert!(!Backend::None.is_attested());
        for b in [Backend::Sgx, Backend::SevSnp, Backend::Tdx, Backend::Nitro] {
            assert!(b.is_attested(), "{} must be attested", b.as_str());
        }
    }

    #[test]
    fn fleet_and_family_serve_others_individual_does_not() {
        assert!(HostingRole::Fleet.serves_others());
        assert!(HostingRole::Family.serves_others());
        assert!(!HostingRole::Individual.serves_others());
    }

    #[test]
    fn sgx_and_sevsnp_are_custody_ready() {
        assert!(Backend::Sgx.custody_ready());
        assert!(Backend::SevSnp.custody_ready());
        // No-TEE + the not-yet-wired CVM seals (TDX / Nitro) are NOT custody-ready.
        for b in [Backend::None, Backend::Tdx, Backend::Nitro] {
            assert!(!b.custody_ready(), "{} must not be custody-ready yet", b.as_str());
        }
    }

    #[test]
    fn serves_others_requires_custody_ready_individual_does_not() {
        // Serves-others is REFUSED with no TEE...
        assert!(require_backend_for_role(HostingRole::Fleet, Backend::None).is_err());
        assert!(require_backend_for_role(HostingRole::Family, Backend::None).is_err());
        // ...AND on a CVM whose seal isn't wired yet (TDX / Nitro) — fail-closed, no
        // silent mock-seal fallback.
        for b in [Backend::Tdx, Backend::Nitro] {
            assert!(
                require_backend_for_role(HostingRole::Fleet, b).is_err(),
                "{} must fail closed until its seal is wired+verified",
                b.as_str(),
            );
        }
        // Serves-others is allowed on a custody-ready backend (SGX + SEV-SNP).
        for b in [Backend::Sgx, Backend::SevSnp] {
            assert!(require_backend_for_role(HostingRole::Fleet, b).is_ok());
            assert!(require_backend_for_role(HostingRole::Family, b).is_ok());
        }
        // An individual self-host is allowed on ANY backend, incl. no-TEE.
        for b in [Backend::None, Backend::Sgx, Backend::Tdx] {
            assert!(require_backend_for_role(HostingRole::Individual, b).is_ok());
        }
    }

    #[test]
    fn hosting_role_parse() {
        assert_eq!(HostingRole::parse("fleet"), Some(HostingRole::Fleet));
        assert_eq!(HostingRole::parse("Family"), Some(HostingRole::Family));
        assert_eq!(HostingRole::parse("self-host"), Some(HostingRole::Individual));
        assert_eq!(HostingRole::parse("bogus"), None);
    }
}
