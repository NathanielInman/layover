//! The daemon's socket: one JSON object per line each way.

use crate::lamp::Lamp;
use bar_anchor::Anchor;
use serde::{Deserialize, Serialize};

#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
#[serde(tag = "cmd", rename_all = "lowercase")]
pub enum Request {
    Status,
    /// Keep the connection open and send a lamp on every change.
    Watch,
    Hold {
        secs: u64,
    },
    Release,
    Now,
    Stop,
    /// Open the drawer from `anchor`, or close it when it is open.
    Toggle {
        #[serde(default)]
        anchor: Option<Anchor>,
    },
    /// Open the drawer from `anchor`.
    Show {
        #[serde(default)]
        anchor: Option<Anchor>,
    },
    /// The drawer subscribes: snapshots and open/close events, one per line.
    Board,
}

#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(untagged)]
pub enum Reply {
    Lamp(Lamp),
    Error { error: String },
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn requests_read_as_the_spec_writes_them() {
        assert_eq!(
            serde_json::from_str::<Request>(r#"{"cmd":"status"}"#).unwrap(),
            Request::Status
        );
        assert_eq!(
            serde_json::from_str::<Request>(r#"{"cmd":"hold","secs":3600}"#).unwrap(),
            Request::Hold { secs: 3600 }
        );
        assert!(serde_json::from_str::<Request>(r#"{"cmd":"explode"}"#).is_err());
        assert_eq!(
            serde_json::from_str::<Request>(r#"{"cmd":"toggle"}"#).unwrap(),
            Request::Toggle { anchor: None }
        );
        assert_eq!(serde_json::from_str::<Request>(r#"{"cmd":"board"}"#).unwrap(), Request::Board);
    }

    #[test]
    fn replies_round_trip() {
        let lamp = Reply::Lamp(Lamp::new("armed", "Saver after 15m".into()));
        assert!(matches!(&lamp, Reply::Lamp(l) if l.text == crate::lamp::MOON));
        assert!(Lamp::off().text.is_empty(), "waybar hides the lamp while the daemon is off");
        let line = serde_json::to_string(&lamp).unwrap();
        assert_eq!(serde_json::from_str::<Reply>(&line).unwrap(), lamp);
        let err = Reply::Error { error: "no".into() };
        let line = serde_json::to_string(&err).unwrap();
        assert_eq!(serde_json::from_str::<Reply>(&line).unwrap(), err);
    }
}
