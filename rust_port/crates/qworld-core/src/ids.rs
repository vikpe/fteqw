//! Typed ID newtypes for engine entities.

macro_rules! id_type {
    ($name:ident, $repr:ty) => {
        #[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, PartialOrd, Ord)]
        pub struct $name(pub $repr);

        impl From<$repr> for $name {
            fn from(v: $repr) -> Self {
                Self(v)
            }
        }
    };
}

id_type!(EntityId, u16);
id_type!(PlayerSlot, u8);
id_type!(ModelIndex, u16);
id_type!(SoundIndex, u16);
id_type!(StatIndex, u8);
