//! Server-to-client message type codes (svc_*).
//!
//! These overlap between NQ and QW for the vanilla set but diverge
//! at the FTE / ezQuake extensions. Engine-side parsing decides
//! which dictionary to use based on the demo format and any
//! protocol-version handshake.

/// Vanilla codes shared by NQ and QW.
#[allow(non_camel_case_types, dead_code)]
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
#[repr(u8)]
pub enum SvcCommon {
    Bad = 0,
    Nop = 1,
    Disconnect = 2,
    UpdateStat = 3,
    ServerData = 11,
    SetAngle = 10,
    Lightstyle = 12,
    UpdateName = 13,
    UpdateFrags = 14,
    ClientData = 15,
    StopSound = 16,
    UpdateColors = 17,
    Particle = 18,
    Damage = 19,
    SpawnStatic = 20,
    SpawnBaseline = 22,
    TempEntity = 23,
    SetPause = 24,
    SignonNum = 25,
    CenterPrint = 26,
    KilledMonster = 27,
    FoundSecret = 28,
    SpawnStaticSound = 29,
    Intermission = 30,
    Finale = 31,
    CdTrack = 32,
    SellScreen = 33,
    CutScene = 34,
}
