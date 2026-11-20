//! Layover's model: config, durations, holds, the idle line state machine,
//! the lamp and the socket protocol. No Wayland, no GPU.

pub mod config;
pub mod holds;
pub mod lamp;
pub mod paths;
pub mod protocol;
pub mod span;
pub mod state;
