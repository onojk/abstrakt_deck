use std::io::Write;
use std::path::PathBuf;
use std::process::{Child, ChildStdin, Stdio};
use std::time::Instant;

pub struct Recorder {
    ffmpeg: Child,
    ffmpeg_stdin: ChildStdin,
    pub start_time: Instant,
    pub frame_count: u64,
    #[allow(dead_code)] pub width: u32,
    #[allow(dead_code)] pub height: u32,
    pub output_path: PathBuf,
}

/// Output frame rate of live (F12) recordings.
const RECORD_FPS: u32 = 30;

impl Recorder {
    /// Number of frames that should have been written by now so the video
    /// tracks wall-clock time (frame 0 is due at t=0).
    fn frames_due(&self) -> u64 {
        (self.start_time.elapsed().as_secs_f64() * RECORD_FPS as f64) as u64 + 1
    }

    /// False when we're ahead of wall-clock time; the caller can then skip
    /// the GPU readback for this frame entirely.
    pub fn wants_frame(&self) -> bool {
        self.frame_count < self.frames_due()
    }

    pub fn start(width: u32, height: u32) -> Result<Self, String> {
        let output_dir = dirs::video_dir()
            .or_else(|| dirs::home_dir().map(|h| h.join("Videos")))
            .ok_or_else(|| "Could not find Videos dir".to_string())?
            .join("abstrakt-deck");
        std::fs::create_dir_all(&output_dir)
            .map_err(|e| format!("Failed to create output dir: {}", e))?;

        let timestamp = chrono::Local::now().format("%Y%m%d-%H%M%S");
        let output_path = output_dir.join(format!("abstrakt-deck-{}.mp4", timestamp));

        log::info!("Starting recording to {}", output_path.display());

        let mut ffmpeg = crate::ffmpeg::command()
            .args([
                "-y",
                "-f", "rawvideo",
                "-pixel_format", "rgba",
                "-video_size", &format!("{}x{}", width, height),
                "-framerate", &RECORD_FPS.to_string(),
                "-i", "-",
                "-c:v", "libx264",
                "-preset", "medium",
                "-crf", "23",
                "-pix_fmt", "yuv420p",
                "-vf", "vflip",
            ])
            .arg(&output_path)
            .stdin(Stdio::piped())
            .stderr(Stdio::null())
            .spawn()
            .map_err(|e| format!(
                "Failed to spawn ffmpeg: {} ({})", e, crate::ffmpeg::install_hint()
            ))?;

        let ffmpeg_stdin = ffmpeg.stdin.take()
            .ok_or_else(|| "Failed to open ffmpeg stdin".to_string())?;

        Ok(Self {
            ffmpeg,
            ffmpeg_stdin,
            start_time: Instant::now(),
            frame_count: 0,
            width,
            height,
            output_path,
        })
    }

    /// Writes `data` once, or several times if rendering has fallen behind
    /// RECORD_FPS, so the output duration matches real time regardless of
    /// the display's refresh rate.
    pub fn submit_frame(&mut self, data: &[u8]) -> Result<(), String> {
        let due = self.frames_due();
        loop {
            self.ffmpeg_stdin.write_all(data)
                .map_err(|e| format!("Failed to write frame: {}", e))?;
            self.frame_count += 1;
            if self.frame_count >= due {
                break;
            }
        }
        Ok(())
    }

    pub fn elapsed(&self) -> std::time::Duration {
        self.start_time.elapsed()
    }

    pub fn finalize(mut self) -> Result<PathBuf, String> {
        drop(self.ffmpeg_stdin);
        let status = self.ffmpeg.wait()
            .map_err(|e| format!("Failed to wait for ffmpeg: {}", e))?;
        if !status.success() {
            return Err(format!("ffmpeg exited with status {}", status));
        }
        log::info!(
            "Recording finalized: {} ({} frames)",
            self.output_path.display(),
            self.frame_count
        );
        Ok(self.output_path)
    }
}
