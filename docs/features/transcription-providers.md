# Transcription providers

Session recordings are transcribed through `Alethea.AI.Whisper`, a
provider-agnostic contract. The provider is chosen at boot from environment
variables in `:dev` and `:prod` (`Alethea.AI.Whisper.runtime_config/1`, called
from `config/runtime.exs`). Tests always use `Alethea.AI.Whisper.Fake`.

## Environment variables

| Variable | Required | Default | Meaning |
| --- | --- | --- | --- |
| `WHISPER_ENABLED` | no | unset = `false` | Capability switch. Exactly `true` or `false`; any other value fails the boot. `false` wires `Alethea.AI.Whisper.Disabled`. |
| `TRANSCRIPTION_PROVIDER` | when enabled | — | `deepgram` or `openai_compatible`. |
| `DEEPGRAM_API_KEY` | for `deepgram` | — | Deepgram API key. |
| `DEEPGRAM_MODEL` | no | `nova-3` | Deepgram model. |
| `DEEPGRAM_BASE_URL` | no | `https://api.deepgram.com` | Deepgram API base URL. |
| `WHISPER_ENDPOINT_URL` | for `openai_compatible` | — | Base URL that serves `/audio/transcriptions` (include the `/v1` part). |
| `WHISPER_API_KEY` | no | — | Sent as `Authorization: Bearer <key>` when set. |
| `WHISPER_MODEL` | no | `whisper-1` | Model name sent to the endpoint. |
| `WHISPER_RECEIVE_TIMEOUT_MS` | no | `600000` | HTTP receive timeout for one transcription. Positive integer. |

A missing required value, a blank value, or an unknown provider fails the boot
with a message that names the variable but never echoes its value.

## Providers

### Deepgram (`deepgram`)

`Alethea.AI.Whisper.Deepgram` posts the raw audio to `/v1/listen` with
`diarize_model=latest`, `utterances=true`, `punctuate=true` and
`smart_format=true`. Each segment carries the speaker number Deepgram assigns
(0, 1, ...).

```sh
WHISPER_ENABLED=true
TRANSCRIPTION_PROVIDER=deepgram
DEEPGRAM_API_KEY=your-deepgram-key
```

### OpenAI-compatible (`openai_compatible`)

`Alethea.AI.Whisper.OpenAICompatible` posts a multipart form to
`{WHISPER_ENDPOINT_URL}/audio/transcriptions` with
`response_format=verbose_json` and segment timestamps. It works with any
server that implements the OpenAI transcription API.

OpenAI:

```sh
WHISPER_ENABLED=true
TRANSCRIPTION_PROVIDER=openai_compatible
WHISPER_ENDPOINT_URL=https://api.openai.com/v1
WHISPER_API_KEY=sk-...
WHISPER_MODEL=whisper-1
```

Groq:

```sh
WHISPER_ENABLED=true
TRANSCRIPTION_PROVIDER=openai_compatible
WHISPER_ENDPOINT_URL=https://api.groq.com/openai/v1
WHISPER_API_KEY=gsk_...
WHISPER_MODEL=whisper-large-v3
```

Local faster-whisper server (no key, audio never leaves the host):

```sh
WHISPER_ENABLED=true
TRANSCRIPTION_PROVIDER=openai_compatible
WHISPER_ENDPOINT_URL=http://localhost:8000/v1
WHISPER_MODEL=Systran/faster-whisper-small
```

## Speakers

Only Deepgram separates speakers. OpenAI-compatible endpoints return segments
with `speaker: nil`, so the recording is stored as a single "Sesión" voice and
the professional is not asked to identify speakers.

## Contract

`transcribe(audio, opts)` takes the audio bytes, `content_type:` (required,
the audio MIME type) and `language:` (default `"es"`). It returns
`{:ok, %{text, language, duration, segments}}` where each segment is
`%{start, end, text, speaker}`, or one of `{:error, {:http_status, status}}`,
`{:error, :timeout}`, `{:error, {:transport, reason}}`,
`{:error, :invalid_response}`, `{:error, :missing_content_type}` and (OpenAI
compatible only) `{:error, :unsupported_content_type}`. Adapters never raise
and never log audio or transcript text.
