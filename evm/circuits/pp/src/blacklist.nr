//! ONE BLACKLIST, ONE PREDICATE — every disqualifying list, in one tree, keyed by domain.
//!
//! 🔑 **THE PREDICATE IS "NONE OF MY IDENTIFIERS IS LISTED", NOT THREE SEPARATE CHECKS.** An earlier
//! note in `withdraw.nr` read *"sanctions non-membership will be the same call again against a
//! DIFFERENT tree — one proof shape, three predicates"*. Three trees means three roots to anchor,
//! three publication paths, three activation windows and three ways for one of them to go stale
//! unnoticed. **One tree means one root, one anchor, one window, and adding a source is a DATA
//! change rather than a code change.**
//!
//! ⭐ **AND IT IS WHAT MAKES "ANY COUNTRY'S LIST, NOT JUST OFAC" COST NOTHING.** The SOURCE is
//! deliberately not part of the key: a listing is a listing, whoever published it. So the tree can
//! carry OFAC, the UN consolidated list, OFSI and any national register at once, and no circuit,
//! contract or client learns a thing about which. Adding a country adds leaves.
//!
//! ⭐ **AND THE HOLDER NEVER ENUMERATES ANYTHING.** They prove ABSENCE OF THEIR OWN KEY. A tree
//! holding fifty countries' listings is proven against with exactly the same single non-membership
//! witness as an empty one — which is why "we don't have to check every country, just the passport"
//! is not a scoping rule to implement, it is a property of the shape.
//!
//! 🔴 **DOMAIN SEPARATION IS LOAD-BEARING, NOT TIDINESS.** A passport number and a pool label are
//! both `Field`s. Without a domain in the preimage, a sanctioned document number could collide with
//! an innocent deposit label and blacklist it — a false positive nobody could explain and the holder
//! could not appeal, because the tree would be *correct*. The domain is what keeps one namespace's
//! listings out of another's.
//!
//! ⚠️ **POLARITY IS UNCHANGED AND IS THE WHOLE SAFETY ARGUMENT:** this is EXCLUSION. An empty root
//! admits everyone, so a publisher who stops publishing cannot censor. An inclusion set would fail
//! the other way, and one inclusion term poisons a conjunction no matter how many exclusion terms
//! sit beside it.
use std::hash::Hasher;
use poseidon::poseidon::PoseidonHasher;

/// Deposit provenance — the chainalysis/association taint set, keyed by the deposit's `label`.
/// This is the domain the existing taint check has always used; it is only now named.
pub global DOMAIN_LABEL: Field = 1;

/// Address taint, keyed by the withdrawal recipient. Upstream PP checked ONLY this.
pub global DOMAIN_ADDRESS: Field = 2;

/// Identity, keyed by `document_identifier` below. Sanctions registers publish DOCUMENT NUMBERS —
/// OFAC's `idList`, the UN's `INDIVIDUAL_DOCUMENT`, OFSI's equivalent — which is why the key is a
/// document rather than a name. **Names are not canonical and cannot key an exclusion proof**;
/// a passport number under its issuing state is.
pub global DOMAIN_DOCUMENT: Field = 3;

/// The leaf key for one identifier in one domain.
///
/// ⚠️ Both fields go into the preimage. Hashing the identifier alone and storing the domain beside
/// it would leave the collision open, since the tree is keyed by this output.
pub fn blacklist_key(domain: Field, identifier: Field) -> Field {
    let mut hasher = PoseidonHasher::default();
    hasher.write(domain);
    hasher.write(identifier);
    hasher.finish()
}

/// A travel document as one field: issuing state and document number together.
///
/// ⚠️ **THE ISSUING STATE IS PART OF THE IDENTIFIER, NOT CONTEXT.** Document numbers are unique
/// only within an issuer, so keying on the number alone would let one country's listing blacklist
/// an unrelated holder of the same number elsewhere. Both come from the MRZ at fixed offsets, so
/// neither is a free input once the circuit reads them from a verified document.
pub fn document_identifier(issuing_state: Field, document_number: Field) -> Field {
    let mut hasher = PoseidonHasher::default();
    hasher.write(issuing_state);
    hasher.write(document_number);
    hasher.finish()
}

mod tests {
    use super::{blacklist_key, document_identifier, DOMAIN_ADDRESS, DOMAIN_DOCUMENT, DOMAIN_LABEL};

    /// 🔴 THE PROPERTY THE DOMAIN EXISTS FOR: the same number in two namespaces is two keys.
    /// If this ever fails, a sanctioned document number silently blacklists a deposit label.
    #[test]
    fn domains_do_not_collide() {
        let v: Field = 42;
        assert(blacklist_key(DOMAIN_LABEL, v) != blacklist_key(DOMAIN_DOCUMENT, v));
        assert(blacklist_key(DOMAIN_LABEL, v) != blacklist_key(DOMAIN_ADDRESS, v));
        assert(blacklist_key(DOMAIN_ADDRESS, v) != blacklist_key(DOMAIN_DOCUMENT, v));
    }

    /// Distinct identifiers in one domain stay distinct — the ordinary requirement, asserted so a
    /// degenerate hash change would be caught here rather than as a mass false positive.
    #[test]
    fn identifiers_do_not_collide_within_a_domain() {
        assert(blacklist_key(DOMAIN_DOCUMENT, 1) != blacklist_key(DOMAIN_DOCUMENT, 2));
    }

    /// ⚠️ The issuing state is part of the identifier: the same document number under two issuers
    /// must not be one key, or one country's listing reaches a holder in another.
    #[test]
    fn the_issuing_state_separates_identical_document_numbers() {
        let number: Field = 123456;
        assert(document_identifier(1, number) != document_identifier(2, number));
    }

    /// ...and it is order-sensitive, so a state/number swap at a call site is not silently the same
    /// key as the correct pairing.
    #[test]
    fn the_identifier_is_order_sensitive() {
        assert(document_identifier(7, 9) != document_identifier(9, 7));
    }
}
