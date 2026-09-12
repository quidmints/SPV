//! The Solana verifier for `p3probe`'s Merkle-path STARK: same config, the byte hash is the
//! `sha256` syscall, the heap is a scratch account (Solana's own heap tops out at 256 KiB and
//! the proof alone is ~100 KB).
#![allow(unexpected_cfgs)]
extern crate alloc;

use alloc::vec::Vec;
use core::alloc::{GlobalAlloc, Layout};

use p3_symmetric::CryptographicHasher;
use solana_program::{
    account_info::AccountInfo, entrypoint::ProgramResult, msg, program_error::ProgramError, pubkey::Pubkey,
};

/// SHA-256 through the runtime syscall — byte-identical to the prover's `p3_sha256::Sha256`.
#[derive(Clone)]
pub struct SolSha256;

impl CryptographicHasher<u8, [u8; 32]> for SolSha256 {
    fn hash_iter<I: IntoIterator<Item = u8>>(&self, input: I) -> [u8; 32] {
        let bytes: Vec<u8> = input.into_iter().collect();
        solana_program::hash::hashv(&[&bytes]).to_bytes()
    }
    fn hash_iter_slices<'a, I: IntoIterator<Item = &'a [u8]>>(&self, input: I) -> [u8; 32] {
        let slices: Vec<&[u8]> = input.into_iter().collect();
        solana_program::hash::hashv(&slices).to_bytes()
    }
}

/// A bump allocator that starts on the runtime's 32 KiB heap and, once `adopt` is called, bumps
/// through a scratch account's data instead. Nothing is ever freed: a verification is one shot.
/// Its three words of state live at the START of the runtime heap, not in a `static` — the SBF
/// loader rejects writable `.data`/`.bss` sections, which is what a mutable static becomes.
pub struct RegionAlloc;
const RUNTIME_HEAP_START: usize = 0x300000000;
const RUNTIME_HEAP_LEN: usize = 32 * 1024;
const STATE_WORDS: usize = 3; // base, cur, end

impl RegionAlloc {
    #[inline(always)]
    fn state() -> *mut usize {
        RUNTIME_HEAP_START as *mut usize
    }
    pub fn adopt(ptr: *mut u8, len: usize) {
        unsafe {
            let s = Self::state();
            *s = ptr as usize;
            *s.add(1) = ptr as usize;
            *s.add(2) = ptr as usize + len;
        }
    }
    pub fn used() -> usize {
        unsafe {
            let s = Self::state();
            (*s.add(1)).saturating_sub(*s)
        }
    }
}

unsafe impl GlobalAlloc for RegionAlloc {
    unsafe fn alloc(&self, layout: Layout) -> *mut u8 {
        let s = Self::state();
        if *s == 0 {
            // First allocation: bump over the runtime heap, after our own state words.
            let start = RUNTIME_HEAP_START + STATE_WORDS * core::mem::size_of::<usize>();
            *s = start;
            *s.add(1) = start;
            *s.add(2) = RUNTIME_HEAP_START + RUNTIME_HEAP_LEN;
        }
        let cur = *s.add(1);
        let start = (cur + layout.align() - 1) & !(layout.align() - 1);
        let next = start + layout.size();
        if next > *s.add(2) {
            return core::ptr::null_mut();
        }
        *s.add(1) = next;
        start as *mut u8
    }
    unsafe fn dealloc(&self, _ptr: *mut u8, _layout: Layout) {}
}

#[cfg(all(target_os = "solana", not(feature = "no-entrypoint")))]
#[global_allocator]
static ALLOC: RegionAlloc = RegionAlloc;

// `entrypoint!` would install the runtime's bump allocator; `entrypoint_no_alloc!` is the
// variant that leaves the global allocator to us.
#[cfg(all(target_os = "solana", not(feature = "no-entrypoint")))]
solana_program::entrypoint!(process_instruction);

/// accounts[0]: the proof bytes (postcard). accounts[1]: scratch heap (writable, large).
/// instruction data: `u8 log_blowup ‖ u8 num_queries ‖ u8 pow_bits ‖ 16 × u32 LE public values`.
pub fn process_instruction(_program_id: &Pubkey, accounts: &[AccountInfo], data: &[u8]) -> ProgramResult {
    use p3_field::PrimeCharacteristicRing;
    use p3probe::{config, FriShape, MerklePathAir, Val, NUM_PUBLIC};
    if accounts.len() < 2 || data.len() != 3 + 4 * NUM_PUBLIC {
        return Err(ProgramError::InvalidInstructionData);
    }
    {
        let scratch = accounts[1].try_borrow_mut_data()?;
        let ptr = scratch.as_ptr() as *mut u8;
        let len = scratch.len();
        // The borrow is released here; the allocator keeps writing through the raw pointer for
        // the rest of this instruction. Sound only because nothing else touches the account.
        RegionAlloc::adopt(ptr, len);
    }
    let fri = FriShape { log_blowup: data[0] as usize, num_queries: data[1] as usize, query_pow_bits: data[2] as usize };
    let pis: Vec<Val> = data[3..]
        .chunks(4)
        .map(|c| Val::from_u32(u32::from_le_bytes([c[0], c[1], c[2], c[3]])))
        .collect();
    let cfg = config(SolSha256, fri);
    let air = MerklePathAir::new();
    let proof_bytes = accounts[0].try_borrow_data()?;
    let proof: p3_uni_stark::Proof<p3probe::Config<SolSha256>> =
        postcard::from_bytes(&proof_bytes).map_err(|_| ProgramError::InvalidAccountData)?;
    msg!("proof decoded, heap used {}", RegionAlloc::used());
    p3_uni_stark::verify(&cfg, &air, &proof, &pis).map_err(|_| ProgramError::InvalidArgument)?;
    msg!("STARK verified, heap used {}", RegionAlloc::used());
    Ok(())
}
