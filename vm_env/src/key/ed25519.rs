use anoma_shared::types::address::Address;
use anoma_shared::types::key::ed25519::{self, PublicKey};

use crate::imports::vp;

/// Get the public key associated with the given address. Panics if not found.
pub fn get(owner: &Address) -> Option<PublicKey> {
    let key = ed25519::pk_key(owner).to_string();
    vp::read_pre(&key)
}
