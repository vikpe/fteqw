//! Quake's reliable/unreliable channel multiplexing.
//!
//! Netchan handles:
//! - Sequence numbers (sent / received)
//! - Reliable resend on ack timeout
//! - Fragmentation for packets >1450 bytes (FTE extension)
//!
//! Stub — implementation deferred until end-to-end packet plumbing
//! is needed.

#[derive(Debug, Default)]
pub struct Netchan {
    pub outgoing_seq: u32,
    pub incoming_seq: u32,
    pub incoming_ack: u32,
}

impl Netchan {
    #[must_use] 
    pub fn new() -> Self {
        Self::default()
    }

    pub fn transmit(&mut self, _payload: &[u8]) -> Vec<u8> {
        todo!("netchan transmit")
    }

    pub fn process(&mut self, _packet: &[u8]) -> Option<Vec<u8>> {
        todo!("netchan process")
    }
}
