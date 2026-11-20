//! The daemon's socket: one JSON object per line each way.

use crate::lamp::Lamp;
use serde::{Deserialize, Serialize};

#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
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
    }

    #[test]
    fn replies_round_trip() {
        let lamp = Reply::Lamp(Lamp::new("armed", "Saver after 15m".into()));
        let line = serde_json::to_string(&lamp).unwrap();
        assert_eq!(serde_json::from_str::<Reply>(&line).unwrap(), lamp);
        let err = Reply::Error { error: "no".into() };
        let line = serde_json::to_string(&err).unwrap();
        assert_eq!(serde_json::from_str::<Reply>(&line).unwrap(), err);
    }
}
