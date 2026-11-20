//! What holds the idle line: parsers for Hyprland's client list and pactl's
//! stream lists. The daemon fetches the text; everything here is pure.

use anyhow::{Context, Result};
use serde::Deserialize;

/// What was holding the line when a station was reached.
#[derive(Clone, Debug, Default, PartialEq, Eq)]
pub struct HoldSnapshot {
    /// Window classes holding an idle inhibitor, minus the ignored ones.
    pub inhibitors: Vec<String>,
    /// An app is playing audio.
    pub audio: bool,
    /// An app is recording from a microphone.
    pub mic: bool,
}

#[derive(Deserialize)]
struct Client {
    #[serde(default)]
    class: String,
    #[serde(default, rename = "inhibitingIdle")]
    inhibiting_idle: bool,
}

/// Classes of windows holding an idle inhibitor, from `hyprctl -j clients`
/// (the `j/clients` socket request), skipping `ignore`. Each class once.
pub fn inhibiting_classes(clients_json: &str, ignore: &[String]) -> Result<Vec<String>> {
    let clients: Vec<Client> =
        serde_json::from_str(clients_json).context("Hyprland's client list is not JSON")?;
    let mut out: Vec<String> = Vec::new();
    for c in clients {
        if !c.inhibiting_idle || ignore.iter().any(|i| i == &c.class) {
            continue;
        }
        let class = if c.class.is_empty() { "a window".to_string() } else { c.class };
        if !out.contains(&class) {
            out.push(class);
        }
    }
    Ok(out)
}

#[derive(Deserialize)]
struct Stream {
    #[serde(default)]
    corked: bool,
    #[serde(default)]
    mute: bool,
    #[serde(default)]
    properties: std::collections::HashMap<String, Option<String>>,
}

impl Stream {
    fn prop(&self, key: &str) -> Option<&str> {
        self.properties.get(key).and_then(|v| v.as_deref())
    }
}

fn streams(json: &str) -> Result<Vec<Stream>> {
    serde_json::from_str(json).context("pactl's stream list is not JSON")
}

/// True when some app is playing sound, from `pactl -f json list sink-inputs`.
/// Paused (corked) and muted streams don't count.
pub fn audio_playing(sink_inputs_json: &str) -> Result<bool> {
    Ok(streams(sink_inputs_json)?.iter().any(|s| !s.corked && !s.mute))
}

/// True when some app is recording, from `pactl -f json list source-outputs`.
/// Level meters (pavucontrol's peak detect, anything marked as a monitor
/// stream) don't count.
pub fn mic_recording(source_outputs_json: &str) -> Result<bool> {
    Ok(streams(source_outputs_json)?.iter().any(|s| {
        !s.corked
            && s.prop("stream.monitor") != Some("true")
            && s.prop("media.name") != Some("Peak detect")
    }))
}

#[cfg(test)]
mod tests {
    use super::*;

    const CLIENTS: &str = include_str!("../fixtures/hyprland-clients.json");

    #[test]
    fn finds_inhibiting_windows_and_skips_ignored_ones() {
        let all = inhibiting_classes(CLIENTS, &[]).unwrap();
        assert_eq!(all, ["mpv", "com.t3tools.T3Code"]);
        let some = inhibiting_classes(CLIENTS, &["com.t3tools.T3Code".into()]).unwrap();
        assert_eq!(some, ["mpv"]);
    }

    #[test]
    fn playing_and_paused_audio() {
        assert!(audio_playing(include_str!("../fixtures/pactl-sink-inputs-playing.json")).unwrap());
        assert!(!audio_playing(include_str!("../fixtures/pactl-sink-inputs-paused.json")).unwrap());
        assert!(!audio_playing("[]").unwrap());
    }

    #[test]
    fn a_call_records_but_a_level_meter_does_not() {
        assert!(mic_recording(include_str!("../fixtures/pactl-source-outputs-call.json")).unwrap());
        assert!(
            !mic_recording(include_str!("../fixtures/pactl-source-outputs-none.json")).unwrap()
        );
        let meter_only = r#"[{"corked":false,"mute":false,"properties":{"media.name":"Peak detect","stream.monitor":"true"}}]"#;
        assert!(!mic_recording(meter_only).unwrap());
    }

    #[test]
    fn garbage_is_an_error_not_a_hold() {
        assert!(inhibiting_classes("not json", &[]).is_err());
        assert!(audio_playing("{").is_err());
    }
}
