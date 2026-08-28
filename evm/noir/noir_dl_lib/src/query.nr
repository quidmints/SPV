use std::hash::{self, Hasher};
use poseidon::poseidon::PoseidonHasher;
use crate::smt::smt_verifier;
use crate::not_passports_zk_circuits::{extract_dg1_commitment, extract_pk_identity_hash};


pub fn date_encoder_bytes<let N: u32>(date: [u8; N]) -> (u32, u32, u32) {
    //YYMMDDHHMMSSZ
    // "- 48" is for converting from ASCII to decimal: '0' == 48, '1' == 49, ...
    let yy = (date[0] - 48) as u32 * 10 + (date[1] - 48) as u32;
    let mm = (date[2] - 48) as u32 * 10 + (date[3] - 48) as u32;
    let dd = (date[4] - 48) as u32 * 10 + (date[5] - 48) as u32;

    (yy, mm, dd)
}

pub fn date_decoder(yy: u32, mm: u32, dd: u32) -> Field {
    let TWO_POW_32 = 4294967296;
    let TWO_POW_16 = 65536;

    // We take first decimal digit and shift it by 1 byte (*256), and add 48 * 256 + 48 (convert back to ASCII).
    let d_ecdoded = ((dd / 10) * 256 + dd % 10) + 12336;
    let m_ecdoded = ((mm / 10) * 256 + mm % 10) + 12336;
    let y_ecdoded = ((yy / 10) * 256 + yy % 10) + 12336;

    y_ecdoded as Field * TWO_POW_32 + m_ecdoded as Field * TWO_POW_16 + d_ecdoded as Field
}

// Date is hex for utf-8 encoded YYMMDD
// To compare dates we need current date (20 | 21 centuary)
pub fn date_is_less(date1: Field, date2: Field, current: Field) -> Field{
    let data1_bytes = date1.to_be_bytes::<6>();
    let data2_bytes = date2.to_be_bytes::<6>();
    let datac_bytes = current.to_be_bytes::<6>();

    let mut (yy1, mm1, dd1) = date_encoder_bytes(data1_bytes);
    let mut (yy2, mm2, dd2) = date_encoder_bytes(data2_bytes);
    let mut (yyc, mmc, ddc) = date_encoder_bytes(datac_bytes);

    if (yy1 > yyc){
        yy1 += 1900;
    } else {
        yy1 += 2000;
    }

    if (yy2 > yyc){
        yy2 += 1900;
    } else {
        yy2 += 2000;
    }

    let verdict = (yy1 < yy2) as Field
        + (yy1 == yy2) as Field
            * ((mm1 < mm2) as Field + (mm1 == mm2) as Field * (dd1 < dd2) as Field); 

    verdict as Field
}

/// Prove a document leaf is CURRENT in `registrationSmt`, at `root`.
///
/// MADE `pub` (it was private to this module) so `escrow_envelope` can reuse it instead of
/// reconstructing the leaf itself. The layout - index `Poseidon(documentKey, holderRoot)`, value
/// `Poseidon(dgCommit, seq, timestamp)` - is fixed by `HolderStateKeeper._bindDocument`, and a
/// second hand-written copy of it would be free to drift from this one with nothing to notice.
/// Publishing the existing function is the smaller change and the only one with no divergence risk.
///
/// PROVES CURRENT, NOT MERELY BOUND. `revokeDocument` and `renewDocument` overwrite the leaf VALUE
/// with `Poseidon1(REVOKED)` / `Poseidon1(SUPERSEDED)`, which no `Poseidon3(dgCommit, seq,
/// timestamp)` reconstruction can equal. So inclusion at this value is also a live-status check.
pub fn identity_state_verifier(
    sk_identity: Field,
    pk_pass_hash: Field,
    dg_commit: Field,
    identity_counter: Field,
    timestamp: Field,
    root: Field,
    siblings: [Field; 80],
) {
    let sk_iden_hash = extract_pk_identity_hash(sk_identity);

    let mut position_hasher = PoseidonHasher::default();
    position_hasher.write(pk_pass_hash);
    position_hasher.write(sk_iden_hash);

    let tree_position = position_hasher.finish();
    let mut value_hasher = PoseidonHasher::default();

    value_hasher.write(dg_commit);
    value_hasher.write(identity_counter);
    value_hasher.write(timestamp);

    let verified = smt_verifier(root, value_hasher.finish(), tree_position, siblings);
    assert(verified == 1, "SMT Check failed");
}

fn citizenship_check(citizenship: Field, bitmask: Field, is_needed: Field) {
    let country_codes = [
        4276823, //ABW
        4277831, //AFG
        4278095, //AGO
        4278593, //AIA
        4279362, //ALB
        4279876, //AND
        4279892, //ANT
        4280901, //ARE
        4280903, //ARG
        4280909, //ARM
        4281165, //ASM
        4281409, //ATA
        4281415, //ATG
        4281683, //AUS
        4281684, //AUT
        4282949, //AZE
        4342857, //BDI
        4343116, //BEL
        4343118, //BEN
        4343361, //BFA
        4343620, //BGD
        4343634, //BGR
        4343890, //BHR
        4343891, //BHS
        4344136, //BIH
        4344909, //BLM
        4344914, //BLR
        4344922, //BLZ
        4345173, //BMU
        4345676, //BOL
        4346433, //BRA
        4346434, //BRB
        4346446, //BRN
        4346958, //BTN
        4347713, //BWA
        4407622, //CAF
        4407630, //CAN
        4408139, //CCK
        4409413, //CHE
        4409420, //CHL
        4409422, //CHN
        4409686, //CIV
        4410706, //CMR
        4411204, //COD
        4411207, //COG
        4411211, //COK
        4411212, //COL
        4411213, //COM
        4411478, //CPV
        4411977, //CRI
        4412738, //CUB
        4412759, //CUW
        4413522, //CXR
        4413773, //CYM
        4413776, //CYP
        4414021, //CZE
        4474197, //DEU
        4475465, //DJI
        4476225, //DMA
        4476491, //DNK
        4476749, //DOM
        4479553, //DZA
        4539221, //ECU
        4540249, //EGY
        4543049, //ERI
        4543304, //ESH
        4543312, //ESP
        4543316, //EST
        4543560, //ETH
        4606286, //FIN
        4606537, //FJI
        4607051, //FLK
        4608577, //FRA
        4608591, //FRO
        4608845, //FSM
        4669762, //GAB
        4670034, //GBR
        4670799, //GEO
        4671321, //GGY
        4671553, //GHA
        4671810, //GIB
        4671822, //GIN
        4672834, //GMB
        4673090, //GNB
        4673105, //GNQ
        4674115, //GRC
        4674116, //GRD
        4674124, //GRL
        4674637, //GTM
        4674893, //GUM
        4674905, //GUY
        4737863, //HKG
        4738628, //HND
        4739670, //HRV
        4740169, //HTI
        4740430, //HUN
        4801614, //IDN
        4803918, //IMN
        4804164, //IND
        4804436, //IOT
        4805196, //IRL
        4805198, //IRN
        4805201, //IRQ
        4805452, //ISL
        4805458, //ISR
        4805697, //ITA
        4866381, //JAM
        4867417, //JEY
        4869970, //JOR
        4870222, //JPN
        4931930, //KAZ
        4932942, //KEN
        4933466, //KGZ
        4933709, //KHM
        4933970, //KIR
        4935233, //KNA
        4935506, //KOR
        4937556, //KWT
        4997455, //LAO
        4997710, //LBN
        4997714, //LBR
        4997721, //LBY
        4997953, //LCA
        4999493, //LIE
        5000001, //LKA
        5002063, //LSO
        5002325, //LTU
        5002584, //LUX
        5002817, //LVA
        5062979, //MAC
        5062982, //MAF
        5062994, //MAR
        5063503, //MCO
        5063745, //MDA
        5063751, //MDG
        5063766, //MDV
        5064024, //MEX
        5064780, //MHL
        5065540, //MKD
        5065801, //MLI
        5065812, //MLT
        5066066, //MMR
        5066309, //MNE
        5066311, //MNG
        5066320, //MNP
        5066586, //MOZ
        5067348, //MRT
        5067602, //MSR
        5068115, //MUS
        5068617, //MWI
        5069139, //MYS
        5069140, //MYT
        5128525, //NAM
        5129036, //NCL
        5129554, //NER
        5130049, //NGA
        5130563, //NIC
        5130581, //NIU
        5131332, //NLD
        5132114, //NOR
        5132364, //NPL
        5132885, //NRU
        5134924, //NZL
        5197134, //OMN
        5259595, //PAK
        5259598, //PAN
        5260110, //PCN
        5260626, //PER
        5261388, //PHL
        5262423, //PLW
        5262919, //PNG
        5263180, //POL
        5263945, //PRI
        5263947, //PRK
        5263956, //PRT
        5263961, //PRY
        5264197, //PSE
        5265734, //PYF
        5325140, //QAT
        5391701, //REU
        5394261, //ROU
        5395795, //RUS
        5396289, //RWA
        5456213, //SAU
        5456974, //SDN
        5457230, //SEN
        5457744, //SGP
        5457998, //SHN
        5458509, //SJM
        5459010, //SLB
        5459013, //SLE
        5459030, //SLV
        5459282, //SMR
        5459789, //SOM
        5460045, //SPM
        5460546, //SRB
        5460804, //SSD
        5461072, //STP
        5461330, //SUR
        5461579, //SVK
        5461582, //SVN
        5461829, //SWE
        5461850, //SWZ
        5462093, //SXM
        5462339, //SYC
        5462354, //SYR
        5522241, //TCA
        5522244, //TCD
        5523279, //TGO
        5523521, //THA
        5524043, //TJK
        5524300, //TKL
        5524301, //TKM
        5524563, //TLS
        5525326, //TON
        5526607, //TTO
        5526862, //TUN
        5526866, //TUR
        5526870, //TUV
        5527374, //TWN
        5528129, //TZA
        5588801, //UGA
        5589842, //UKR
        5591641, //URY
        5591873, //USA
        5593666, //UZB
        5652820, //VAT
        5653332, //VCT
        5653838, //VEN
        5654338, //VGB
        5654866, //VIR
        5656141, //VNM
        5657940, //VUT
        5721158, //WLF
        5722957, //WSM
        5786456, //XKX
        5850445, //YEM
        5914950, //ZAF
        5918018, //ZMB
        5920581 //ZWE
    ];

    let mut res = 0;
    let bitmask_bits = bitmask.to_le_bits::<240>();

    for i in 0..240 {
        res += (country_codes[i] * (bitmask_bits[i] as Field) == citizenship) as Field;

    }

    assert(res == 1 * is_needed as Field, "Citizenship check failed");
}

// QUERY SELECTOR:
// 0 - nullifier
// 1 - birth date
// 2 - expiration date
// 3 - name
// 4 - nationality
// 5 - citizenship
// 6 - sex
// 7 - document number
// 8 - timestamp lowerbound
// 9 - timestamp upperbound
// 10 - identity counter lowerbound
// 11 - identity counter upperbound
// 12 - passport expiration lowerbound
// 13 - passport expiration upperbound
// 14 - birth date lowerbound
// 15 - birth date upperbound
// 16 - verify citizenship mask as a whitelist
// 17 - verify citizenship mask as a blacklist

// Passport encoding time is UTF-8 "YYMMDD"
// Timestamps has 2 times of encoding:
// - standard (UNIX) timestamp, like 1716482295 (UT - UNIX timestamp)
// - passport timestamp, like UTF-8 "010203" -> 0x303130323033 -> 52987820126259 (PT - passport timestamp)

pub fn query_identity(
    event_id: Field,
    event_data: Field,
    id_state_root: Field,
    selector: Field,
    current_date: Field,
    timestamp_lowerbound: Field,
    timestamp_upperbound: Field,
    identity_count_lowerbound: Field,
    identity_count_upperbound: Field,
    birth_date_lowerbound: Field,
    birth_date_upperbound: Field,
    expiration_date_lowerbound: Field,
    expiration_date_upperbound: Field,
    citizenship_mask: Field,
    sk_identity: Field,
    pk_passport_hash: Field,
    dg1: [u8; 93],
    siblings: [Field; 80],
    timestamp: Field,
    identity_counter: Field,
) -> (
    Field, // nullifier Poseidon3(sk_i, Poseidon1(sk_i), eventID)
    Field, // birthDate: *(PT - passport timestamp)
    Field, // expirationDate: *(PT - passport timestamp)
    Field, // name: surname
    Field, // nameResidual: given name
    Field, // nationality: UTF-8 encoded | "USA" -> 0x555341 -> 5591873
    Field, // citizenship: UTF-8 encoded | "USA" -> 0x555341 -> 5591873
    Field, // Sex: UTF-8 encoded | "F" -> 0x46 -> 70
    Field // document number
) {


    // selector decoding
    let selector_bits = selector.to_be_bits::<19>();

    // ----------------------
    // Passport data decoding
    let mut (birth_date, expiration_date, name, name_residial, nationality, citizenship, sex, doc_number) = dg1_data_extractor(dg1);

    // ----------------------
    // Nullifier calculation
    let mut sk_iden_hasher = PoseidonHasher::default();
    sk_iden_hasher.write(sk_identity);
    let mut nullifier_hasher = PoseidonHasher::default();
    nullifier_hasher.write(sk_identity);
    nullifier_hasher.write(sk_iden_hasher.finish());
    nullifier_hasher.write(event_id);
    let nullifier = nullifier_hasher.finish() * selector_bits[18] as Field;


    // First value is result of comparation, other is selector bit
    // 0 0 -> 1
    // 1 0 -> 1
    // 0 1 -> 0
    // 1 1 -> 1
    // We should pass all situtions except when we fail check but selector bit is 1

    // --------------------------
    // Timestamp lowerbound check
    let mut n1 = (timestamp as u64 >= timestamp_lowerbound as u64) as u8;
    let mut n2 = selector_bits[10] as u8;
    assert((n1 + (1 - n2) - n1 * (1 - n2)) == 1, "Timestamp lowerbound");

    // Timestamp upperbound check

    n1 = (timestamp as u64 <= timestamp_upperbound as u64) as u8;
    n2 = selector_bits[9] as u8;

    assert((n1 + (1 - n2) - n1 * (1 - n2)) == 1, "Timestamp upperbound");

    //---------------------------------
    // Identity counter lowerbound check
    n1 = (identity_counter as u64 >= identity_count_lowerbound as u64) as u8;
    n2 = selector_bits[8] as u8;
    assert((n1 + (1 - n2) - n1 * (1 - n2)) == 1, "Identity counter lowerbound");

    // Identity counter upperbound
    n1 = (identity_counter as u64 <= identity_count_upperbound as u64) as u8;
    n2 = selector_bits[7] as u8;
    assert((n1 + (1 - n2) - n1 * (1 - n2)) == 1, "Identity counter upperbound");

    //---------------------------------
    // Expiration date lowerbound: expirationDateLowerbound < expirationDate
    n1 = (expiration_date as u64 >= expiration_date_lowerbound as u64) as u8;
    n2 = selector_bits[6] as u8;

    assert((n1 + (1 - n2) - n1 * (1 - n2)) == 1, "Expiration date lowerbound");

    // Expiration date upperbound: expirationDate < expirationDateUpperbound
    n1 = (expiration_date as u64 <= expiration_date_upperbound as u64) as u8;
    n2 = selector_bits[5] as u8;
    assert((n1 + (1 - n2) - n1 * (1 - n2)) == 1, "Expiration date upperbound");
    
    //---------------------------------
    // Birth date lowerbound: birthDateLowerbound < birthDate
    n1 = date_is_less(birth_date_lowerbound, birth_date, current_date) as u8;
    n2 = selector_bits[4] as u8;
    assert((n1 + (1 - n2) - n1 * (1 - n2)) == 1, "Birth date lowerbound");

    // Birth date lowerbound: birthDateLowerbound < birthDate
    n1 = date_is_less(birth_date, birth_date_upperbound, current_date) as u8;
    n2 = selector_bits[3] as u8;
    assert((n1 + (1 - n2) - n1 * (1 - n2)) == 1, "Birth date upperbound");

    // dg1 commitment
    let dg1_commit = extract_dg1_commitment(dg1, sk_identity);

    // Verify identity ownerships
    let _ = identity_state_verifier(
        sk_identity,
        pk_passport_hash,
        dg1_commit,
        identity_counter,
        timestamp,
        id_state_root,
        siblings,
    );

    // Citizenship check
    let _ = citizenship_check(
        citizenship,
        citizenship_mask,
        selector_bits[0] as Field,
    );


    birth_date *= selector_bits[17] as Field;
    expiration_date *= selector_bits[16] as Field;
    name *= selector_bits[15] as Field;
    name_residial *= selector_bits[15] as Field;
    nationality *= selector_bits[14] as Field;
    citizenship *= selector_bits[13] as Field;
    sex *= selector_bits[12] as Field;
    doc_number *= selector_bits[11] as Field;

    (
        nullifier, birth_date, expiration_date, name, name_residial, nationality, citizenship, sex, doc_number,
    )
}

// QUERY SELECTOR:
// 0 - nullifier   (+)
// 1 - birth date  (+)
// 2 - expiration date (+)
// 3 - name (+)
// 4 - nationality (+)
// 5 - citizenship (+)
// 6 - sex (+)
// 7 - document number (+)
// 8 - timestamp lowerbound (+)
// 9 - timestamp upperbound (+)
// 10 - identity counter lowerbound (+)
// 11 - identity counter upperbound (+)
// 12 - passport expiration lowerbound
// 13 - passport expiration upperbound
// 14 - birth date lowerbound
// 15 - birth date upperbound
// 16 - personal number hash
// 17 - doc type
// 18 - enforce the citizenship mask (sec. 2.18an)
//
// BIT 18 EXISTS BECAUSE THE CITIZENSHIP CHECK USED TO BORROW BIT 16. It had no bit of its own and
// read the one meaning "personal number hash", so in TD1 - which returns a personal number, unlike
// TD3 - asking "are you a citizen of X?" ALSO disclosed the holder's national ID number hash, and
// asking for the ID number silently imposed a citizenship constraint that made proving impossible.
//
// WIDENING FROM 18 TO 19 BITS CHANGES NO CALLER. The selector is big-endian, so the index is
// `width - 1 - bit`: adding a bit shifts every INDEX in this file by one while leaving every
// documented bit's VALUE untouched. A caller passing 2**16 still means "personal number hash". The
// only new thing is 2**18.

// Passport encoding time is UTF-8 "YYMMDD"
// Timestamps has 2 times of encoding: 
// - standard (UNIX) timestamp, like 1716482295 (UT - UNIX timestamp)
// - passport timestamp, like UTF-8 "010203" -> 0x303130323033 -> 52987820126259 (PT - passport timestamp)
pub fn query_identity_td1(
    event_id: Field,
    event_data: Field,
    id_state_root: Field,
    selector: Field,
    current_date: Field,
    timestamp_lowerbound: Field,
    timestamp_upperbound: Field,
    identity_count_lowerbound: Field,
    identity_count_upperbound: Field,
    birth_date_lowerbound: Field,
    birth_date_upperbound: Field,
    expiration_date_lowerbound: Field,
    expiration_date_upperbound: Field,
    citizenship_mask: Field,
    sk_identity: Field,
    pk_passport_hash: Field,
    dg1: [u8; 95],
    siblings: [Field; 80],
    timestamp: Field,
    identity_counter: Field,
) -> (
    Field, // nullifier Poseidon3(sk_i, Poseidon1(sk_i), eventID)
    Field, // birthDate: *(PT - passport timestamp)
    Field, // expirationDate: *(PT - passport timestamp)
    Field, // name: surname
    Field, // nationality: UTF-8 encoded | "USA" -> 0x555341 -> 5591873
    Field, // citizenship: UTF-8 encoded | "USA" -> 0x555341 -> 5591873
    Field, // Sex: UTF-8 encoded | "F" -> 0x46 -> 70
    Field, // document number hash
    Field, // personal number hash
    Field, // UTF-8 encoded | "ID"
) {
    // selector decoding
    let selector_bits = selector.to_be_bits::<19>();

    // ----------------------
    // ID card data decoding
    let mut (birth_date, expiration_date, name, nationality, citizenship, sex, doc_number, personal_number, doc_type) = td1_dg1_data_extractor(dg1);

    // ----------------------
    // Document number hasher
    let mut doc_number_hasher = PoseidonHasher::default();
    doc_number_hasher.write(doc_number);
    let mut doc_number_hash = doc_number_hasher.finish();

    // ----------------------
    // Personal number hasher
    let mut pers_number_hasher = PoseidonHasher::default();
    pers_number_hasher.write(personal_number);
    let mut personal_number_hash = pers_number_hasher.finish();

    // ----------------------
    // Nullifier calculation
    let mut sk_iden_hasher = PoseidonHasher::default();
    sk_iden_hasher.write(sk_identity);
    let mut nullifier_hasher = PoseidonHasher::default();
    nullifier_hasher.write(sk_identity);
    nullifier_hasher.write(sk_iden_hasher.finish());
    nullifier_hasher.write(event_id);
    let nullifier = nullifier_hasher.finish() * selector_bits[18] as Field;


    // First value is result of comparation, other is selector bit
    // 0 0 -> 1
    // 1 0 -> 1
    // 0 1 -> 0
    // 1 1 -> 1
    // We should pass all situtions except when we fail check but selector bit is 1

    // --------------------------
    // Timestamp lowerbound check
    let mut n1 = (timestamp as u64 >= timestamp_lowerbound as u64) as u8;
    let mut n2 = selector_bits[10] as u8;
    assert((n1 + (1 - n2) - n1 * (1 - n2)) == 1, "Timestamp lowerbound");

    // Timestamp upperbound check

    n1 = (timestamp as u64 <= timestamp_upperbound as u64) as u8;
    n2 = selector_bits[9] as u8;

    assert((n1 + (1 - n2) - n1 * (1 - n2)) == 1, "Timestamp upperbound");

    //---------------------------------
    // Identity counter lowerbound check
    n1 = (identity_counter as u64 >= identity_count_lowerbound as u64) as u8;
    n2 = selector_bits[8] as u8;
    assert((n1 + (1 - n2) - n1 * (1 - n2)) == 1, "Identity counter lowerbound");

    // Identity counter upperbound
    n1 = (identity_counter as u64 <= identity_count_upperbound as u64) as u8;
    n2 = selector_bits[7] as u8;
    assert((n1 + (1 - n2) - n1 * (1 - n2)) == 1, "Identity counter upperbound");

    //---------------------------------
    // Expiration date lowerbound: expirationDateLowerbound < expirationDate
    n1 = (expiration_date as u64 >= expiration_date_lowerbound as u64) as u8;
    n2 = selector_bits[6] as u8;

    assert((n1 + (1 - n2) - n1 * (1 - n2)) == 1, "Expiration date lowerbound");

    // Expiration date upperbound: expirationDate < expirationDateUpperbound
    n1 = (expiration_date as u64 <= expiration_date_upperbound as u64) as u8;
    n2 = selector_bits[5] as u8;
    assert((n1 + (1 - n2) - n1 * (1 - n2)) == 1, "Expiration date upperbound");
    
    //---------------------------------
    // Birth date lowerbound: birthDateLowerbound < birthDate
    n1 = date_is_less(birth_date_lowerbound, birth_date, current_date) as u8;
    n2 = selector_bits[4] as u8;
    assert((n1 + (1 - n2) - n1 * (1 - n2)) == 1, "Birth date lowerbound");

    // Birth date lowerbound: birthDateLowerbound < birthDate
    n1 = date_is_less(birth_date, birth_date_upperbound, current_date) as u8;
    n2 = selector_bits[3] as u8;
    assert((n1 + (1 - n2) - n1 * (1 - n2)) == 1, "Birth date upperbound");

    // dg1 commitment
    let dg1_commit = extract_dg1_commitment(dg1, sk_identity);

    // Verify identity ownerships
    let _ = identity_state_verifier(
        sk_identity,
        pk_passport_hash,
        dg1_commit,
        identity_counter,
        timestamp,
        id_state_root,
        siblings,
    );

    // Citizenship check
    let _ = citizenship_check(
        citizenship,
        citizenship_mask,
        selector_bits[0] as Field,
    );

    birth_date *= selector_bits[17] as Field;
    expiration_date *= selector_bits[16] as Field;
    name *= selector_bits[15] as Field;
    nationality *= selector_bits[14] as Field;
    citizenship *= selector_bits[13] as Field;
    sex *= selector_bits[12] as Field;
    doc_number_hash *= selector_bits[11] as Field;
    personal_number_hash *= selector_bits[2] as Field;
    doc_type *= selector_bits[1] as Field;

    (
        nullifier, birth_date, expiration_date, name, nationality, citizenship, sex, doc_number_hash, personal_number_hash, doc_type
    )
}


// Extract data from dg1
fn dg1_data_extractor
(
    dg1: [u8; 93]
) -> (Field, Field, Field, Field, Field, Field, Field, Field){

    // BIRTH DATE
    let BIRTH_DATE_SIZE  = 6;
    let BIRTH_DATE_SHIFT = 62;

    let mut birth_date = 0;
    let mut current = 1;
    for i in 0..BIRTH_DATE_SIZE{
        birth_date += current * dg1[BIRTH_DATE_SIZE + BIRTH_DATE_SHIFT - 1 - i] as Field;
        current *= 256;
    }   

    // EXPIRATION DATE
    let EXPIRATION_DATE_SIZE  = 6;
    let EXPIRATION_DATE_SHIFT = 70;

    let mut expiration_date = 0;
    current = 1;
    for i in 0..EXPIRATION_DATE_SIZE{
        expiration_date += current * dg1[EXPIRATION_DATE_SIZE + EXPIRATION_DATE_SHIFT - i - 1] as Field;
        current *= 256;
    }
    
    // NAME, 31 bytes
    let NAME_FIELD_SIZE     = 31;
    let NAME_FIELD_SHIFT    = 10;
    let NAME_FIELD_RESIDUAL = 8;

    let mut name = 0;
    let mut name_residial = 0;
    current = 1;
    for i in 0..NAME_FIELD_SIZE{
        name += current * dg1[NAME_FIELD_SIZE + NAME_FIELD_SHIFT - 1 - i] as Field;
        current *= 256;
    }
    current = 1;
    for i in 0..NAME_FIELD_RESIDUAL{
        name_residial += current * dg1[ NAME_FIELD_RESIDUAL + NAME_FIELD_SHIFT + NAME_FIELD_SIZE - 1 - i] as Field;
        current *= 256;
    }

    // NATIONALITY 
    let NATIONALITY_FIELD_SIZE  = 3;
    let NATIONALITY_FIELD_SHIFT = 59;

    let mut nationality = 0;
    current = 1;
    for i in 0..NATIONALITY_FIELD_SIZE{
        nationality += current * dg1[NATIONALITY_FIELD_SIZE + NATIONALITY_FIELD_SHIFT - 1 -  i] as Field;
        current *= 256;
    }

    // CITIZENSHIP CODE (== issuing authority)
    let CITIZENSHIP_FIELD_SIZE  = 3;
    let CITIZENSHIP_FIELD_SHIFT = 7;

    let mut citizenship = 0;
    current = 1;
    for i in 0..CITIZENSHIP_FIELD_SIZE{
        citizenship += current * dg1[CITIZENSHIP_FIELD_SIZE - 1 - i + CITIZENSHIP_FIELD_SHIFT] as Field;
        current *= 256;
    }

    // SEX
    let SEX_POSITION   = 69;
    let mut sex = dg1[SEX_POSITION] as Field;

    // DOCUMENT NUMBER
    let DOCUMENT_NUMBER_SHIFT = 49;
    let DOCUMENT_NUMBER_SIZE  = 9;

    let mut doc_number = 0;
    current = 1;
    for i in 0..DOCUMENT_NUMBER_SIZE{
        doc_number += current * dg1[DOCUMENT_NUMBER_SHIFT + DOCUMENT_NUMBER_SIZE - 1 - i] as Field;
        current *= 256;
    }

    (birth_date, expiration_date, name, name_residial, nationality, citizenship, sex, doc_number)
}

fn td1_dg1_data_extractor
(
    dg1: [u8; 95]
) -> (Field, Field, Field, Field, Field, Field, Field, Field, Field){

    // BIRTH DATE
    let BIRTH_DATE_SIZE  = 6;
    let BIRTH_DATE_SHIFT = 35;

    let mut birth_date = 0;
    let mut current = 1;
    for i in 0..BIRTH_DATE_SIZE{
        birth_date += current * dg1[BIRTH_DATE_SIZE + BIRTH_DATE_SHIFT - 1 - i] as Field;
        current *= 256;
    }   

    // EXPIRATION DATE
    let EXPIRATION_DATE_SIZE  = 6;
    let EXPIRATION_DATE_SHIFT = 43;

    let mut expiration_date = 0;
    current = 1;
    for i in 0..EXPIRATION_DATE_SIZE{
        expiration_date += current * dg1[EXPIRATION_DATE_SIZE + EXPIRATION_DATE_SHIFT - i - 1] as Field;
        current *= 256;
    }
    
    // NAME, 31 bytes
    let NAME_FIELD_SIZE     = 30;
    let NAME_FIELD_SHIFT    = 65;


    let mut name = 0;
    current = 1;
    for i in 0..NAME_FIELD_SIZE{
        name += current * dg1[NAME_FIELD_SIZE + NAME_FIELD_SHIFT - 1 - i] as Field;
        current *= 256;
    }

    // NATIONALITY 
    let NATIONALITY_FIELD_SIZE  = 3;
    let NATIONALITY_FIELD_SHIFT = 50;

    let mut nationality = 0;
    current = 1;
    for i in 0..NATIONALITY_FIELD_SIZE{
        nationality += current * dg1[NATIONALITY_FIELD_SIZE + NATIONALITY_FIELD_SHIFT - 1 -  i] as Field;
        current *= 256;
    }

    // CITIZENSHIP CODE (== issuing authority)
    let CITIZENSHIP_FIELD_SIZE  = 3;
    let CITIZENSHIP_FIELD_SHIFT = 7;

    let mut citizenship = 0;
    current = 1;
    for i in 0..CITIZENSHIP_FIELD_SIZE{
        citizenship += current * dg1[CITIZENSHIP_FIELD_SIZE - 1 - i + CITIZENSHIP_FIELD_SHIFT] as Field;
        current *= 256;
    }

    // SEX
    let SEX_POSITION   = 48;
    let mut sex = dg1[SEX_POSITION] as Field;

    // DOCUMENT NUMBER
    let DOCUMENT_NUMBER_SHIFT = 10;
    let DOCUMENT_NUMBER_SIZE  = 9;

    let mut doc_number = 0;
    current = 1;
    for i in 0..DOCUMENT_NUMBER_SIZE{
        doc_number += current * dg1[DOCUMENT_NUMBER_SHIFT + DOCUMENT_NUMBER_SIZE - 1 - i] as Field;
        current *= 256;
    }

    // PERSONAL NUMBER
    let PERSONAL_NUMBER_SHIFT = 20;
    let PERSONAL_NUMBER_SIZE  = 11;

    let mut personal_number = 0;
    current = 1;
    for i in 0..PERSONAL_NUMBER_SIZE{
        personal_number += current * dg1[PERSONAL_NUMBER_SHIFT + PERSONAL_NUMBER_SIZE - 1 - i] as Field;
        current *= 256;
    }

    // DOCUMENT TYPE
    let DOCUMENT_TYPE_SHIFT = 5;
    let DOCUMENT_TYPE_SIZE  = 2;

    let mut doc_type = 0;
    current = 1;
    for i in 0..DOCUMENT_TYPE_SIZE{
        doc_type += current * dg1[DOCUMENT_TYPE_SHIFT + DOCUMENT_TYPE_SIZE - 1 - i] as Field;
        current *= 256;
    }

    (birth_date, expiration_date, name, nationality, citizenship, sex, doc_number, personal_number, doc_type)
}

/// The two MRZ fields a sanctions list is published against: issuing authority and document number.
///
/// ⚠️ THIS ADDS NO PARSING. It is a `pub` window onto `td1_dg1_data_extractor`, which already reads
/// both at the offsets ICAO fixes (citizenship at [7..10), document number at [10..19)) and is
/// exercised by this file's own tests. Re-deriving the offsets in a caller would be a second MRZ
/// parser that drifts from this one silently - the reason it is exposed rather than copied.
///
/// ⛔ TD1 ONLY, and the caller must not reach for it with a TD3 buffer: the document number sits at
/// [10..19) on a TD1 card and [49..58) on a TD3 booklet. The `[u8; 95]` type is what enforces that -
/// a 93-byte TD3 DG1 will not compile against it, which is the whole reason the length is in the
/// signature instead of being a runtime check.
pub fn td1_document_fields(dg1: [u8; 95]) -> (Field, Field) {
    let (
        _birth_date, _expiration_date, _name, _nationality, citizenship, _sex, doc_number,
        _personal_number, _doc_type,
    ) = td1_dg1_data_extractor(dg1);
    (citizenship, doc_number)
}

// =================================================================================================
// THE FIRST TESTS THIS FILE HAS EVER HAD (sec. 2.18ak).
//
// 883 lines, zero tests, inherited from rarime at the fork commit with zero - verified, not assumed:
// `rsa.nr` arrived carrying five, so vendoring did not strip them.
//
// WHY THIS FILE AND NOT ANOTHER. `query.nr` decides WHAT A PROOF DISCLOSES. That is the one thing
// real-passport testing cannot cover, and the sentence to keep in mind is:
//
//     A selector mask can be wrong for every passport ever tried and still verify.
//
// A passport test exercises the SIGNATURE path - does this SOD verify, does the DSC chain to a CSCA.
// A proof that reveals the wrong fields still verifies perfectly: prover satisfied, verifier
// satisfied, passport genuine. Nothing cryptographic anywhere looks at which values came out. So the
// only way these properties can fail loudly is a test that asserts them.
mod disclosure_tests {
    use super::{date_is_less, query_identity};
    use crate::not_passports_zk_circuits::{extract_dg1_commitment, extract_pk_identity_hash};
    use poseidon::poseidon::PoseidonHasher;
    use std::hash::Hasher;

    global SK: Field = 1234;
    global PK_PASSPORT_HASH: Field = 5678;
    global IDENTITY_COUNTER: Field = 3;
    global TIMESTAMP: Field = 1_700_000_000;
    global EVENT_ID: Field = 99;
    global EVENT_DATA: Field = 100;

    /// "260101" - the reference "today" every date comparison is windowed against.
    global CURRENT_DATE: Field = 0x323630313031;

    /// "800101" -> 1980, comfortably before the DG1's 1990 birth date, so the lowerbound is
    /// SATISFIED. Not 0: see `test_a_zero_date_bound_aborts_proving` for why zero is not a no-op.
    global A_SATISFIED_BIRTH_LOWERBOUND: Field = 0x383030313031;

    /// "950101" -> 1995, AFTER the DG1's birth date, so the lowerbound is VIOLATED.
    global A_VIOLATED_BIRTH_LOWERBOUND: Field = 0x393530313031;

    /// A DG1 carrying birth date "900101" at [62..68) and expiry "300101" at [70..76), the offsets
    /// `dg1_data_extractor` reads. Everything else is filler - these tests are about the selector
    /// and the bounds, not about MRZ parsing.
    fn a_dg1() -> [u8; 93] {
        let mut dg1: [u8; 93] = [0; 93];
        for i in 0..93 {
            dg1[i] = 0x30; // ASCII '0', so unrelated fields stay well-formed digits
        }
        let birth: [u8; 6] = [0x39, 0x30, 0x30, 0x31, 0x30, 0x31]; // "900101"
        let expiry: [u8; 6] = [0x33, 0x30, 0x30, 0x31, 0x30, 0x31]; // "300101"
        for i in 0..6 {
            dg1[62 + i] = birth[i];
            dg1[70 + i] = expiry[i];
        }
        dg1
    }

    /// The single-leaf witness `identity_state_verifier` accepts, built the way sec. 2.18ah built
    /// withdraw_identity's: derive the leaf, then let the root BE the leaf hash with zero siblings.
    /// Nothing is faked - these are the same primitives the circuit itself uses.
    fn a_valid_root(dg1: [u8; 93]) -> Field {
        let dg1_commit = extract_dg1_commitment::<93>(dg1, SK);
        let sk_iden_hash = extract_pk_identity_hash(SK);

        let mut position_hasher = PoseidonHasher::default();
        position_hasher.write(PK_PASSPORT_HASH);
        position_hasher.write(sk_iden_hash);
        let tree_position = position_hasher.finish();

        let mut value_hasher = PoseidonHasher::default();
        value_hasher.write(dg1_commit);
        value_hasher.write(IDENTITY_COUNTER);
        value_hasher.write(TIMESTAMP);
        let value = value_hasher.finish();

        // smt_hash1(key, value) - Poseidon(key, value, 1). Private in smt.nr, so recomputed here;
        // if that convention ever changed, every test below would fail rather than silently pass.
        let mut leaf_hasher = PoseidonHasher::default();
        leaf_hasher.write(tree_position);
        leaf_hasher.write(value);
        leaf_hasher.write(1);
        leaf_hasher.finish()
    }

    /// Runs the query with `selector`, leaving every BOUND wide open so only disclosure is measured.
    fn query_with(
        selector: Field,
        birth_lower: Field,
    ) -> (Field, Field, Field, Field, Field, Field, Field, Field, Field) {
        let dg1 = a_dg1();
        query_identity(
            EVENT_ID,
            EVENT_DATA,
            a_valid_root(dg1),
            selector,
            CURRENT_DATE,
            0,                    // timestamp lowerbound
            0xFFFFFFFFFFFF,       // timestamp upperbound
            0,                    // identity counter lowerbound
            0xFFFFFFFFFFFF,       // identity counter upperbound
            birth_lower,
            0xFFFFFFFFFFFF,       // birth date upperbound
            0,                    // expiration date lowerbound
            0xFFFFFFFFFFFF,       // expiration date upperbound
            0,                    // citizenship mask
            SK,
            PK_PASSPORT_HASH,
            dg1,
            [0; 80],
            TIMESTAMP,
            IDENTITY_COUNTER,
        )
    }

    // -- the selector map ----------------------------------------------------------------------

    /*
     * THE FLAGSHIP. The comment block above `query_identity_td1` documents the selector as
     * "0 - nullifier, 1 - birth date, 2 - expiration date, ...", while the CODE indexes
     * `selector.to_be_bits::<19>()` - big-endian, so documented bit k lives at index 18 - k.
     *
     * That off-by-inversion is invisible: pick the wrong end and every field still gets multiplied
     * by SOME bit, the proof still verifies, and the caller gets a different field than it asked
     * for. This asserts the mapping one bit at a time, so a reordering breaks a named test instead
     * of quietly redefining the API.
     */
    #[test]
    fn test_bit_1_alone_reveals_the_birth_date_and_nothing_else() {
        // 2 == documented bit 1, which the code must read at index 16.
        let (nullifier, birth, expiry, name, name_residual, nationality, citizenship, sex, doc) =
            query_with(2, A_SATISFIED_BIRTH_LOWERBOUND);

        assert(birth != 0, "bit 1 is documented as birth date but did not reveal it");
        assert(nullifier == 0, "bit 1 leaked the nullifier");
        assert(expiry == 0, "bit 1 leaked the expiration date");
        assert(name == 0, "bit 1 leaked the surname");
        assert(name_residual == 0, "bit 1 leaked the given name");
        assert(nationality == 0, "bit 1 leaked nationality");
        assert(citizenship == 0, "bit 1 leaked citizenship");
        assert(sex == 0, "bit 1 leaked sex");
        assert(doc == 0, "bit 1 leaked the document number");
    }

    /// Bit 0 is the nullifier, and it must not drag anything else out with it.
    #[test]
    fn test_bit_0_alone_reveals_the_nullifier_and_nothing_else() {
        let (nullifier, birth, expiry, name, name_residual, nationality, citizenship, sex, doc) =
            query_with(1, A_SATISFIED_BIRTH_LOWERBOUND);

        assert(nullifier != 0, "bit 0 is documented as the nullifier but did not reveal it");
        assert(birth == 0, "bit 0 leaked the birth date");
        assert(expiry == 0, "bit 0 leaked the expiration date");
        assert(name == 0, "bit 0 leaked the surname");
        assert(name_residual == 0, "bit 0 leaked the given name");
        assert(nationality == 0, "bit 0 leaked nationality");
        assert(citizenship == 0, "bit 0 leaked citizenship");
        assert(sex == 0, "bit 0 leaked sex");
        assert(doc == 0, "bit 0 leaked the document number");
    }

    /// An EMPTY selector must disclose nothing at all. The fail-safe direction, pinned: if the
    /// masking were ever inverted, this is the test that catches it on the first run.
    #[test]
    fn test_an_empty_selector_discloses_nothing() {
        let (nullifier, birth, expiry, name, name_residual, nationality, citizenship, sex, doc) =
            query_with(0, A_SATISFIED_BIRTH_LOWERBOUND);

        assert(nullifier == 0, "an empty selector still produced a nullifier");
        assert(birth == 0, "an empty selector still revealed the birth date");
        assert(expiry == 0, "an empty selector still revealed the expiration date");
        assert(name == 0, "an empty selector still revealed the surname");
        assert(name_residual == 0, "an empty selector still revealed the given name");
        assert(nationality == 0, "an empty selector still revealed nationality");
        assert(citizenship == 0, "an empty selector still revealed citizenship");
        assert(sex == 0, "an empty selector still revealed sex");
        assert(doc == 0, "an empty selector still revealed the document number");
    }

    /*
     * THE NULLIFIER COLLISION HAZARD, documented by test rather than left to be discovered.
     *
     * `nullifier = Poseidon3(...) * selector_bits[18]`, so with bit 0 CLEAR the nullifier is 0 - not
     * absent, ZERO, for every user. A relying party doing double-spend prevention on this value
     * without checking that bit 0 was set would treat all holders as one person. That is a caller
     * obligation the circuit cannot enforce, and the only defence is that it is written down.
     */
    #[test]
    fn test_the_nullifier_is_zero_for_everyone_when_its_bit_is_clear() {
        let (nullifier, _, _, _, _, _, _, _, _) = query_with(2, A_SATISFIED_BIRTH_LOWERBOUND);
        assert(
            nullifier == 0,
            "bit 0 clear must zero the nullifier - if this ever changes, the collision note above is stale",
        );
    }

    // -- the bounds are OPT-IN, which is the thing that cannot fail loudly ---------------------

    /*
     * `assert((n1 + (1 - n2) - n1 * (1 - n2)) == 1)` is `n1 OR NOT n2`: the bound is enforced ONLY
     * when its selector bit is set. So a relying party that wants "born before 1995" and forgets to
     * set bit 14 receives a perfectly valid proof that says NOTHING about age - and there is no
     * error, no revert, no signal of any kind.
     *
     * This pair is the whole point. The first test proves the check really is skipped (so the
     * hazard is real and documented), the second proves it really does bite when requested (so the
     * feature is not vacuous). Neither is meaningful without the other.
     */
    #[test]
    fn test_an_out_of_range_birth_date_passes_when_its_bound_bit_is_clear() {
        // "950101" as a lowerbound is NOT less than the DG1's "900101", so the bound is violated.
        // Bit 14 is clear, so nothing checks it and the proof stands.
        let (_, birth, _, _, _, _, _, _, _) = query_with(2, A_VIOLATED_BIRTH_LOWERBOUND);
        assert(birth != 0, "the query should still have succeeded with the bound unrequested");
    }

    #[test(should_fail_with = "Birth date lowerbound")]
    fn test_the_same_out_of_range_birth_date_is_rejected_when_the_bit_is_set() {
        // 2 + 16384 == bit 1 (reveal birth date) + bit 14 (enforce the lowerbound).
        let _ = query_with(2 + 16384, A_VIOLATED_BIRTH_LOWERBOUND);
    }

    /// And a SATISFIED bound must pass with the bit set, or the two tests above would agree for the
    /// wrong reason - a bound that rejects everything is not a working bound.
    #[test]
    fn test_a_satisfied_birth_date_bound_passes_when_the_bit_is_set() {
        let (_, birth, _, _, _, _, _, _, _) = query_with(2 + 16384, A_SATISFIED_BIRTH_LOWERBOUND);
        assert(birth != 0, "a satisfied lowerbound was rejected");
    }

    /*
     * FOUND BY THESE TESTS, NOT BY READING: ZERO IS NOT A NO-OP DATE BOUND.
     *
     * The obvious way to say "I do not care about birth date" is to pass 0 - exactly what this
     * suite's first draft did. It does not skip the check, it ABORTS PROVING. `date_is_less` does
     * `to_be_bytes::<6>()` and then `date[0] - 48` inside `date_encoder_bytes`, so a zero byte
     * underflows a u8 and the circuit fails with "attempt to subtract with overflow".
     *
     * TWO THINGS MAKE THIS WORSE THAN AN ORDINARY BAD INPUT:
     *
     * 1. IT HAPPENS EVEN WHEN THE BOUND IS NOT REQUESTED. `date_is_less` is evaluated
     *    UNCONDITIONALLY, before the `n1 OR NOT n2` gate that decides whether anyone cares. So a
     *    caller who correctly leaves selector bit 14 clear, and passes 0 because the bound is
     *    unused, cannot produce a proof at all. No selector setting makes a zero date safe.
     * 2. IT IS SAFE ONLY BY ACCIDENT. Noir's u8 underflow check is the only thing making this loud.
     *    The same arithmetic over a Field would wrap to an enormous year and silently invert the
     *    comparison - which is precisely the disclosure bug this suite exists to catch.
     *
     * PINNED RATHER THAN CLAMPED. Clamping would convert a loud abort into a quietly wrong
     * comparison, which is the trap this project keeps naming. The real gap is that there is no
     * documented "unused" sentinel: "000000" parses as year 2000, month 0, day 0 - a real
     * comparison, not a skip. Until one exists, callers must pass a genuine ASCII YYMMDD for every
     * date bound whether or not they intend to use it, and this test is where that is written down.
     */
    #[test(should_fail_with = "attempt to subtract with overflow")]
    fn test_a_zero_date_bound_aborts_proving_even_when_unrequested() {
        // Selector 2: bit 14 is CLEAR, so nothing asks for the lowerbound to hold. It still cannot
        // be proven, because date_is_less runs before the gate that would have ignored it.
        let _ = query_with(2, 0);
    }

    // -- date_is_less, where an off-by-one is a disclosure bug ---------------------------------

    /*
     * The two-digit-year window. `date_is_less` maps a year to 19xx if it is GREATER than the
     * current two-digit year and 20xx otherwise, so the pivot sits exactly at equality. Getting
     * that boundary wrong shifts every age comparison by a century for one birth year, and the
     * proof still verifies.
     */
    #[test]
    fn test_a_year_equal_to_the_current_year_is_this_century() {
        // "260101" vs "260102" with current "260101": both 2026, so day ordering decides.
        assert(date_is_less(0x323630313031, 0x323630313032, CURRENT_DATE) == 1);
        assert(date_is_less(0x323630313032, 0x323630313031, CURRENT_DATE) == 0);
    }

    #[test]
    fn test_a_year_above_the_current_year_is_last_century() {
        // "900101" -> 1990 (90 > 26), "100101" -> 2010 (10 <= 26). 1990 < 2010.
        assert(
            date_is_less(0x393030313031, 0x313030313031, CURRENT_DATE) == 1,
            "a 19xx year was not ordered before a 20xx year",
        );
        assert(
            date_is_less(0x313030313031, 0x393030313031, CURRENT_DATE) == 0,
            "a 20xx year was ordered before a 19xx year",
        );
    }

    /// Strictly less, not less-or-equal - an equal date must NOT compare as less.
    #[test]
    fn test_an_equal_date_is_not_less() {
        assert(date_is_less(CURRENT_DATE, CURRENT_DATE, CURRENT_DATE) == 0);
    }

    /// Month ordering must dominate day ordering: 01-31 precedes 02-01.
    #[test]
    fn test_the_month_outranks_the_day() {
        assert(
            date_is_less(0x323630313331, 0x323630323031, CURRENT_DATE) == 1,
            "Jan 31 was not ordered before Feb 1",
        );
        assert(
            date_is_less(0x323630323031, 0x323630313331, CURRENT_DATE) == 0,
            "Feb 1 was ordered before Jan 31",
        );
    }
}



// =================================================================================================
// THE TD1 QUERY PATH - and a defect the TD3 tests above could not have found (sec. 2.18an).
//
// TD1 is the LIVE length: `escrow_envelope`, `register_identity_light_td1` and the wallet's circuit
// registry all use 95-byte DG1. Testing only `query_identity` (93-byte TD3) would have left the path
// people actually use uncovered, which is how sec. 2.18ac's registration mismatch happened.
mod td1_disclosure_tests {
    use super::query_identity_td1;
    use crate::not_passports_zk_circuits::{extract_dg1_commitment, extract_pk_identity_hash};
    use poseidon::poseidon::PoseidonHasher;
    use std::hash::Hasher;

    global SK: Field = 4321;
    global PK_PASSPORT_HASH: Field = 8765;
    global IDENTITY_COUNTER: Field = 2;
    global TIMESTAMP: Field = 1_700_000_000;
    global EVENT_ID: Field = 77;
    global EVENT_DATA: Field = 78;
    global CURRENT_DATE: Field = 0x323630313031; // "260101"
    global A_SATISFIED_BIRTH_LOWERBOUND: Field = 0x383030313031; // "800101" -> 1980

    /// TD1 offsets, from `td1_dg1_data_extractor`: birth date at [35..41), expiry at [43..49),
    /// citizenship at [7..10). Citizenship is set to "ABW" - `country_codes[0]` in
    /// `citizenship_check`, i.e. bitmask bit 0 - so the mask can be made to match on purpose.
    fn a_dg1() -> [u8; 95] {
        let mut dg1: [u8; 95] = [0; 95];
        for i in 0..95 {
            dg1[i] = 0x30; // ASCII '0' - unrelated fields stay well-formed digits
        }
        let birth: [u8; 6] = [0x39, 0x30, 0x30, 0x31, 0x30, 0x31]; // "900101"
        let expiry: [u8; 6] = [0x33, 0x30, 0x30, 0x31, 0x30, 0x31]; // "300101"
        for i in 0..6 {
            dg1[35 + i] = birth[i];
            dg1[43 + i] = expiry[i];
        }
        let abw: [u8; 3] = [0x41, 0x42, 0x57]; // "ABW" == 4276823 == country_codes[0]
        for i in 0..3 {
            dg1[7 + i] = abw[i];
        }
        dg1
    }

    fn a_valid_root(dg1: [u8; 95]) -> Field {
        let dg1_commit = extract_dg1_commitment::<95>(dg1, SK);
        let sk_iden_hash = extract_pk_identity_hash(SK);

        let mut position_hasher = PoseidonHasher::default();
        position_hasher.write(PK_PASSPORT_HASH);
        position_hasher.write(sk_iden_hash);
        let tree_position = position_hasher.finish();

        let mut value_hasher = PoseidonHasher::default();
        value_hasher.write(dg1_commit);
        value_hasher.write(IDENTITY_COUNTER);
        value_hasher.write(TIMESTAMP);
        let value = value_hasher.finish();

        let mut leaf_hasher = PoseidonHasher::default();
        leaf_hasher.write(tree_position);
        leaf_hasher.write(value);
        leaf_hasher.write(1);
        leaf_hasher.finish()
    }

    fn query_with(
        selector: Field,
        citizenship_mask: Field,
    ) -> (Field, Field, Field, Field, Field, Field, Field, Field, Field, Field) {
        let dg1 = a_dg1();
        query_identity_td1(
            EVENT_ID,
            EVENT_DATA,
            a_valid_root(dg1),
            selector,
            CURRENT_DATE,
            0,
            0xFFFFFFFFFFFF,
            0,
            0xFFFFFFFFFFFF,
            A_SATISFIED_BIRTH_LOWERBOUND,
            0xFFFFFFFFFFFF,
            0,
            0xFFFFFFFFFFFF,
            citizenship_mask,
            SK,
            PK_PASSPORT_HASH,
            dg1,
            [0; 80],
            TIMESTAMP,
            IDENTITY_COUNTER,
        )
    }

    /// Baseline: an empty selector with a non-matching mask discloses nothing and still proves.
    #[test]
    fn test_an_empty_selector_discloses_nothing() {
        let (nullifier, birth, expiry, name, nationality, citizenship, sex, doc, personal, doc_type) =
            query_with(0, 0);

        assert(nullifier == 0, "empty selector produced a nullifier");
        assert(birth == 0, "empty selector revealed the birth date");
        assert(expiry == 0, "empty selector revealed the expiration date");
        assert(name == 0, "empty selector revealed the name");
        assert(nationality == 0, "empty selector revealed nationality");
        assert(citizenship == 0, "empty selector revealed citizenship");
        assert(sex == 0, "empty selector revealed sex");
        assert(doc == 0, "empty selector revealed the document number");
        assert(personal == 0, "empty selector revealed the PERSONAL NUMBER");
        assert(doc_type == 0, "empty selector revealed the document type");
    }

    /// Bit 1 (index 16) is the birth date here too, and it must not drag the rest out with it.
    #[test]
    fn test_bit_1_alone_reveals_the_birth_date_and_nothing_else() {
        let (nullifier, birth, expiry, name, nationality, citizenship, sex, doc, personal, doc_type) =
            query_with(2, 0);

        assert(birth != 0, "bit 1 did not reveal the birth date");
        assert(nullifier == 0, "bit 1 leaked the nullifier");
        assert(expiry == 0, "bit 1 leaked the expiration date");
        assert(name == 0, "bit 1 leaked the name");
        assert(nationality == 0, "bit 1 leaked nationality");
        assert(citizenship == 0, "bit 1 leaked citizenship");
        assert(sex == 0, "bit 1 leaked sex");
        assert(doc == 0, "bit 1 leaked the document number");
        assert(personal == 0, "bit 1 leaked the PERSONAL NUMBER");
        assert(doc_type == 0, "bit 1 leaked the document type");
    }

    /*
     * === THE DEFECT THAT WAS HERE, AND THE FIX (sec. 2.18an) ===
     *
     * `query_identity_td1` used to read `selector_bits[1]` TWICE - once to gate `citizenship_check`
     * and once to unmask `personal_number_hash`. Under the old 18-bit selector, index 1 was
     * documented bit 16, "personal number hash": the citizenship check had NO BIT OF ITS OWN and
     * borrowed that one. TD3 escaped it only because `query_identity` returns no personal number, so
     * index 1 had a single reader there.
     *
     * Both directions were harmful, and one was a privacy leak:
     *   1. Asking for the personal number silently ENFORCED a citizenship constraint - bit set, no
     *      mask, `citizenship_check` wanting exactly one match and getting none, so the proof could
     *      not be produced at all and the error named citizenship.
     *   2. THE LEAK: asking only "are you a citizen of X?" - a yes/no question - ALSO disclosed the
     *      holder's national ID number hash, because the only way to turn the check on was to set
     *      the bit that unmasked it. The user chose one thing and disclosed two; the proof verified
     *      perfectly and nothing anywhere reported a problem.
     *
     * FIXED, NOT PINNED. The first write-up of this claimed a fix meant a coordinated ABI change
     * across the wallet, `PublicSignalsBuilder` and rarime's tooling, because "all 18 bits are
     * assigned". THAT WAS WRONG, and checking took one grep: `PublicSignalsBuilder` only STORES the
     * selector integer at signal index 12 and never decomposes it, so nothing outside this file
     * interprets bit positions at all.
     *
     * The selector is BIG-ENDIAN, so an index is `width - 1 - bit`. Widening 18 -> 19 therefore
     * shifts every INDEX in this file by one while leaving every documented bit's VALUE untouched: a
     * caller passing 2**16 still means "personal number hash", and 2**18 is simply new. The
     * citizenship check now owns documented bit 18, i.e. `selector_bits[0]`.
     *
     * The two tests below are the old defect tests, rewritten to assert the FIXED behaviour - which
     * is what the retired ones instructed. They fail if the two ever share a bit again.
     */
    #[test]
    fn test_the_personal_number_can_be_requested_without_a_citizenship_constraint() {
        // 65536 == documented bit 16 alone. Under the defect this ABORTED with "Citizenship check
        // failed"; a caller wanting an ID number and indifferent to nationality could not prove.
        let (_, _, _, _, _, citizenship, _, _, personal, _) = query_with(65536, 0);

        assert(personal != 0, "bit 16 did not disclose the personal number");
        assert(citizenship == 0, "bit 16 leaked citizenship, which it does not gate");
    }

    /// THE LEAK, CLOSED. Enforcing citizenship must disclose NOTHING by itself.
    #[test]
    fn test_asking_about_citizenship_no_longer_discloses_the_personal_number() {
        // 262144 == 2**18, the citizenship check's own bit. Mask bit 0 == "ABW", which this DG1
        // matches, so the constraint is satisfied - and nothing is unmasked by satisfying it.
        let (nullifier, birth, expiry, name, nationality, citizenship, sex, doc, personal, doc_type) =
            query_with(262144, 1);

        assert(
            personal == 0,
            "enforcing citizenship still leaks the PERSONAL NUMBER - the bits are coupled again",
        );
        assert(citizenship == 0, "the citizenship VALUE leaked; bit 18 enforces, bit 5 discloses");
        assert(nullifier == 0, "citizenship enforcement leaked the nullifier");
        assert(birth == 0, "citizenship enforcement leaked the birth date");
        assert(expiry == 0, "citizenship enforcement leaked the expiration date");
        assert(name == 0, "citizenship enforcement leaked the name");
        assert(nationality == 0, "citizenship enforcement leaked nationality");
        assert(sex == 0, "citizenship enforcement leaked sex");
        assert(doc == 0, "citizenship enforcement leaked the document number");
        assert(doc_type == 0, "citizenship enforcement leaked the document type");
    }

    /// And the constraint still BITES - a mask the citizenship does not match must refuse. Without
    /// this the test above would pass just as well if bit 18 did nothing at all.
    #[test(should_fail_with = "Citizenship check failed")]
    fn test_the_citizenship_constraint_still_rejects_a_non_matching_mask() {
        // Bit 18 set, mask bit 1 == "AFG", but this DG1 says "ABW".
        let _ = query_with(262144, 2);
    }
}
