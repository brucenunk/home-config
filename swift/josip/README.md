# Josip recorder helper

Josip is a small macOS microphone recorder helper used by Emacs dictation in this repo. It exists so macOS grants microphone permission to a narrow helper app instead of to Emacs, Pi, or a terminal frontend.

The installed command is `josip`; it launches `Josip.app` through LaunchServices and waits for the app to finish recording.

## CLI contract

```sh
josip \
  --output /path/to/dictation.wav \
  --max-duration 90 \
  --stop-file /path/to/stop \
  --ready-file /path/to/ready
```

Arguments:

- `--output` — WAV file to create.
- `--max-duration` — maximum recording duration in seconds. Values must be greater than 0 and no more than 90.
- `--stop-file` — when this file appears, Josip stops recording and exits.
- `--ready-file` — Josip creates this file after audio capture has actually started.

Josip writes exactly one WAV file, creates the ready file once recording begins, then stops when either the stop file appears or the max duration elapses.

## Ownership boundary

Josip owns only:

- macOS microphone permission;
- raw microphone capture;
- WAV file creation;
- the stop/ready file handshake;
- the hard 90 second recording cap.

Josip deliberately does not know about:

- Pi sessions, Ghostel terminals, or Emacs buffers;
- transcripts or editor state;
- API keys, models, or provider config;
- network transcription;
- automatic submission to an agent or command.

Callers own temporary directory lifecycle, transcript requests, UI, insertion/paste behavior, and cleanup.

## Audio format

Josip records WAV audio as:

- mono;
- 16-bit PCM;
- 16 kHz sample rate.

Input volume/gain is controlled by macOS and the selected microphone.

## macOS microphone permission

The first dictation run may trigger a macOS microphone permission prompt for **Josip**. Allow it.

If recording fails, check **System Settings → Privacy & Security → Microphone** and confirm **Josip** is allowed. Also check the selected default input device and input volume.
