//! Protocol version constants and FTE PEXT extension flags.

/// `QuakeWorld` base protocol version.
pub const PROTOCOL_VERSION_QW: u32 = 28;

/// `NetQuake` base protocol version.
pub const PROTOCOL_VERSION_NQ: u32 = 15;

/// FTE extension handshake magics. Servers advertise which
/// extensions they support; clients ack the subset they understand.
pub mod fte {
    /// 'F' << 0 | 'T' << 8 | 'E' << 16 | 'X' << 24 — first set of
    /// FTE protocol extensions.
    pub const PROTOCOL_VERSION_FTE1: u32 =
        ('F' as u32) | (('T' as u32) << 8) | (('E' as u32) << 16) | (('X' as u32) << 24);

    pub const PROTOCOL_VERSION_FTE2: u32 = PROTOCOL_VERSION_FTE1 ^ 0x0000_0001;

    pub const PROTOCOL_VERSION_EZQUAKE1: u32 = 0x88_77_22_11;
}

/// FTE PEXT_* flags worth pulling forward for QW compatibility.
/// (Subset; full list is in the parent repo's `engine/common/protocol.h`.)
pub mod pext {
    pub const PEXT_FLOATCOORDS: u32 = 0x0000_8000;
    pub const PEXT_ENTITYDBL: u32 = 0x0000_0100;
    pub const PEXT_HEXEN2: u32 = 0x0000_2000;
    pub const PEXT_CSQC: u32 = 0x0000_4000;
    pub const PEXT_CHUNKEDDOWNLOADS: u32 = 0x0010_0000;
    pub const PEXT_COMPRESSION: u32 = 0x4000_0000;
}
