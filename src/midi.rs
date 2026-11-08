use crossbeam_channel::{bounded, Receiver};
use midir::{Ignore, MidiInput, MidiInputConnection};

#[derive(Debug, Clone, Copy)]
pub enum MidiEvent {
    ControlChange(u8, u8),
    NoteOn(u8, u8),
    NoteOff(#[allow(dead_code)] u8),
}

pub struct MidiCapture {
    pub event_rx: Receiver<MidiEvent>,
}

impl MidiCapture {
    /// Returns immediately; port enumeration and connection happen on a
    /// background thread. On Windows, WinMM initialisation can block for
    /// several seconds (observed ~11 s on a VM with no MIDI hardware), which
    /// previously froze the window before its first frame. The thread owns
    /// the connection and parks for the life of the process.
    pub fn start() -> Result<Self, String> {
        let (event_tx, event_rx) = bounded::<MidiEvent>(256);
        std::thread::Builder::new()
            .name("midi-init".into())
            .spawn(move || match connect(event_tx) {
                Ok(_connection) => loop {
                    std::thread::park();
                },
                Err(e) => log::warn!(
                    "MIDI capture failed: {} — visualizer will run without MIDI control",
                    e
                ),
            })
            .map_err(|e| format!("Failed to spawn MIDI thread: {}", e))?;
        Ok(Self { event_rx })
    }
}

fn connect(
    event_tx: crossbeam_channel::Sender<MidiEvent>,
) -> Result<MidiInputConnection<()>, String> {
    {
        let mut midi_in = MidiInput::new("abstrakt-deck")
            .map_err(|e| format!("Failed to create MIDI input: {}", e))?;
        midi_in.ignore(Ignore::None);

        let ports = midi_in.ports();
        if ports.is_empty() {
            return Err("No MIDI input ports available".to_string());
        }

        for p in &ports {
            let name = midi_in.port_name(p).unwrap_or_else(|_| "<unknown>".to_string());
            log::info!("MIDI port available: {}", name);
        }

        // Priority: VMPK by name → "MIDI Out" (VMPK's actual port label) → non-Through → first port
        let port = ports
            .iter()
            .find(|p| {
                midi_in
                    .port_name(p)
                    .map(|n| n.to_lowercase().contains("vmpk"))
                    .unwrap_or(false)
            })
            .or_else(|| {
                ports.iter().find(|p| {
                    midi_in
                        .port_name(p)
                        .map(|n| n.to_lowercase().contains("midi out"))
                        .unwrap_or(false)
                })
            })
            .or_else(|| {
                ports.iter().find(|p| {
                    midi_in
                        .port_name(p)
                        .map(|n| !n.to_lowercase().contains("through"))
                        .unwrap_or(false)
                })
            })
            .unwrap_or(&ports[0]);

        let port_name = midi_in
            .port_name(port)
            .unwrap_or_else(|_| "<unknown>".to_string());
        log::info!("MIDI port selected: {}", port_name);

        let connection = midi_in
            .connect(
                port,
                "abstrakt-deck-midi",
                move |_timestamp, message, _| {
                    if message.is_empty() { return; }
                    let status = message[0] & 0xF0;

                    let event = match status {
                        0x80 if message.len() >= 2 => Some(MidiEvent::NoteOff(message[1])),
                        0x90 if message.len() >= 3 => {
                            if message[2] == 0 {
                                Some(MidiEvent::NoteOff(message[1]))
                            } else {
                                Some(MidiEvent::NoteOn(message[1], message[2]))
                            }
                        }
                        0xB0 if message.len() >= 3 => {
                            Some(MidiEvent::ControlChange(message[1], message[2]))
                        }
                        _ => None,
                    };

                    if let Some(e) = event {
                        let _ = event_tx.try_send(e);
                    }
                },
                (),
            )
            .map_err(|e| format!("Failed to connect to MIDI port: {}", e))?;

        log::info!("MIDI capture started");
        Ok(connection)
    }
}
