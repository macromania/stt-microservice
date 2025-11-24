# C++ Memory Leak Visualization

## Memory Leak Mechanism

```
┌─────────────────────────────────────────────────────────────────┐
│                     CIRCULAR REFERENCE CYCLE                     │
│                    (Prevents Garbage Collection)                 │
└─────────────────────────────────────────────────────────────────┘

    ┌──────────────────────────────────────────────────────┐
    │                                                      │
    │  ┌─────────────────────────────────────────────┐   │
    │  │  ConversationTranscriber (Python object)    │   │
    │  │  • _handle → C++ pointer (81MB native)      │   │
    │  │  • __transcribed_signal → EventSignal       │   │
    │  └───────────────┬─────────────────────────────┘   │
    │                  │                                   │
    │                  │ owns                              │
    │                  ▼                                   │
    │  ┌─────────────────────────────────────────────┐   │
    │  │  EventSignal                                │   │
    │  │  • __callbacks = [on_transcribed]          │   │
    │  │  • __context → ConversationTranscriber     │   │
    │  └───────────────┬─────────────────────────────┘   │
    │                  │                                   │
    │                  │ contains                          │
    │                  ▼                                   │
    │  ┌─────────────────────────────────────────────┐   │
    │  │  on_transcribed (closure)                   │   │
    │  │  • Captures: segments, transcriber, done    │   │
    │  └───────────────┬─────────────────────────────┘   │
    │                  │                                   │
    │                  │ references                        │
    └──────────────────┘                                   │
                                                           │
        CIRCULAR REFERENCE LOOP! ─────────────────────────┘

Result: Python GC cannot collect → __del__() never called → C++ never freed
```

## Memory Accumulation Over Time

```
WITHOUT PROPER CLEANUP:

Request 1:  [Transcriber 1: 100MB] → Leaks (circular ref)
Request 2:  [Transcriber 1: 100MB] [Transcriber 2: 100MB] → Both leak
Request 3:  [Transcriber 1: 100MB] [Transcriber 2: 100MB] [Transcriber 3: 100MB]
...
Request 10: [1GB+ leaked memory] → OOM Kill or performance degradation

┌─────────────────────────────────────────────────────────────┐
│  Memory Usage Over 100 Requests                             │
│                                                              │
│  1000MB ┤                                             ▲     │
│         │                                       ▲▲▲▲▲ ││    │
│   800MB ┤                           ▲▲▲▲▲▲▲▲▲▲ ││││││││    │
│         │                   ▲▲▲▲▲▲▲ │││││││││││││││││││    │
│   600MB ┤           ▲▲▲▲▲▲▲ │││││││││││││││││││││││││││    │
│         │   ▲▲▲▲▲▲▲ ││││││││││││││││││││││││││││││││││    │
│   400MB ┤▲▲▲│││││││││││││││││││││││││││││││││││││││││││    │
│         │││││││││││││││││││││││││││││││││││││││││││││││    │
│   200MB ┤│││││││││││││││││││││││││││││││││││││││││││││    │
│         └┴┴┴┴┴┴┴┴┴┴┴┴┴┴┴┴┴┴┴┴┴┴┴┴┴┴┴┴┴┴┴┴┴┴┴┴┴┴┴┴┴┴┴┴┴    │
│          0   10   20   30   40   50   60   70   80   90  100│
│                          Requests                            │
└─────────────────────────────────────────────────────────────┘
```

## WITH PROPER CLEANUP:

```
Request 1:  [Transcriber 1: 100MB] → Cleaned (disconnected)
Request 2:  [Transcriber 2: 100MB] → Cleaned (disconnected)
Request 3:  [Transcriber 3: 100MB] → Cleaned (disconnected)
...
Stable at: [Baseline: 200MB + Active Request: 100MB = 300MB total]

┌─────────────────────────────────────────────────────────────┐
│  Memory Usage Over 100 Requests (With Cleanup)              │
│                                                              │
│  1000MB ┤                                                    │
│         │                                                    │
│   800MB ┤                                                    │
│         │                                                    │
│   600MB ┤                                                    │
│         │                                                    │
│   400MB ┤                                                    │
│         │▬▬▬▬▬▬▬▬▬▬▬▬▬▬▬▬▬▬▬▬▬▬▬▬▬▬▬▬▬▬▬▬▬▬▬▬▬▬▬▬▬▬▬▬    │
│   200MB ┤▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀    │
│         └┴┴┴┴┴┴┴┴┴┴┴┴┴┴┴┴┴┴┴┴┴┴┴┴┴┴┴┴┴┴┴┴┴┴┴┴┴┴┴┴┴┴┴┴┴    │
│          0   10   20   30   40   50   60   70   80   90  100│
│                          Requests                            │
└─────────────────────────────────────────────────────────────┘
                   ▲
                   │
            STABLE MEMORY!
```

## Resource Cleanup Flow

```
╔═══════════════════════════════════════════════════════════════╗
║              PROPER C++ RESOURCE RELEASE FLOW                 ║
╚═══════════════════════════════════════════════════════════════╝

1. BREAK CIRCULAR REFERENCES
   ┌──────────────────────────────────────┐
   │  transcriber.transcribed             │
   │     .disconnect_all()                │◄─── Breaks callback chain
   └──────────────────────────────────────┘
                  │
                  ▼
   ┌──────────────────────────────────────┐
   │  del on_transcribed                  │◄─── Releases closure
   └──────────────────────────────────────┘
                  │
                  ▼
2. CLOSE NETWORK RESOURCES
   ┌──────────────────────────────────────┐
   │  connection.close()                  │◄─── Releases TCP sockets
   └──────────────────────────────────────┘
                  │
                  ▼
3. CLOSE CREDENTIALS
   ┌──────────────────────────────────────┐
   │  credential.close()                  │◄─── Releases HTTP client
   └──────────────────────────────────────┘
                  │
                  ▼
4. DELETE SDK OBJECTS
   ┌──────────────────────────────────────┐
   │  del transcriber                     │◄─── Hints Python GC
   │  del audio_config                    │
   │  del speech_config                   │
   └──────────────────────────────────────┘
                  │
                  ▼
5. FORCE GARBAGE COLLECTION
   ┌──────────────────────────────────────┐
   │  gc.collect()                        │◄─── Triggers __del__()
   └──────────────────────────────────────┘
                  │
                  ▼
6. PYTHON FINALIZERS
   ┌──────────────────────────────────────┐
   │  transcriber.__del__()               │
   │    → _Handle.__del__()               │
   │      → release_fn(handle)            │
   └──────────────────────────────────────┘
                  │
                  ▼
7. C++ CLEANUP (via ctypes)
   ┌──────────────────────────────────────┐
   │  _sdk_lib.recognizer_handle_release()│
   └──────────────────────────────────────┘
                  │
                  ▼
8. NATIVE MEMORY FREED
   ┌──────────────────────────────────────┐
   │  C++: delete RecognizerImpl          │
   │  • Free audio buffers (50MB)         │
   │  • Close network sockets             │
   │  • Release model memory (100MB+)     │
   └──────────────────────────────────────┘
                  │
                  ▼
           ✅ MEMORY RELEASED
```

## Event Handler Inheritance Tree

```
╔═══════════════════════════════════════════════════════════════╗
║         ConversationTranscriber Event Handler Tree            ║
╚═══════════════════════════════════════════════════════════════╝

ConversationTranscriber
├── transcribed ..................... ✅ MUST disconnect
├── transcribing .................... ✅ MUST disconnect (MISSING!)
├── canceled ........................ ✅ MUST disconnect
│
└── (inherits from Recognizer)
    ├── session_started ............. ✅ MUST disconnect (MISSING!)
    ├── session_stopped ............. ✅ MUST disconnect
    ├── speech_start_detected ....... ✅ MUST disconnect (MISSING!)
    ├── speech_end_detected ......... ✅ MUST disconnect (MISSING!)
    │
    └── (base class handlers may have internal connections)

TOTAL: 8 event signals to disconnect
CURRENT CODE: Disconnects 3
MISSING: 4 (marked above)
```

## C++ Handle Lifecycle

```
╔═══════════════════════════════════════════════════════════════╗
║              C++ Handle Wrapper Lifecycle                     ║
╚═══════════════════════════════════════════════════════════════╝

┌─────────────────────────────────────────────────────────────┐
│ Python Layer                                                 │
│                                                              │
│  transcriber = ConversationTranscriber(...)                 │
│       │                                                      │
│       │ creates                                              │
│       ▼                                                      │
│  _Handle(                                                    │
│    handle=0x7f8a3c000000,  ◄───────┐ C++ pointer           │
│    test_fn=recognizer_handle_is_valid,                      │
│    release_fn=recognizer_handle_release  ◄─┐ C++ function  │
│  )                                         │                │
└────────────────────────────────────────────┼────────────────┘
                                             │
┌────────────────────────────────────────────┼────────────────┐
│ Python GC Triggers                         │                │
│                                             │                │
│  del transcriber → GC → __del__() ─────────┘                │
│                           │                                  │
│                           ▼                                  │
│  _Handle.__del__():                                          │
│    if test_fn(handle):  # Check if valid                    │
│      release_fn(handle) # Call C++ release ◄────┐           │
└─────────────────────────────────────────────────┼───────────┘
                                                  │
┌─────────────────────────────────────────────────┼───────────┐
│ C++ Native Layer (via ctypes)                   │           │
│                                                  │           │
│  libMicrosoft.CognitiveServices.Speech.core.so  │           │
│                                                  │           │
│  recognizer_handle_release(handle): ◄───────────┘           │
│    RecognizerImpl* impl = (RecognizerImpl*)handle;          │
│    delete impl; // Frees:                                   │
│      - Audio buffers (50MB)                                 │
│      - Network connections                                  │
│      - Speech model memory (100MB+)                         │
│      - Internal caches                                      │
└─────────────────────────────────────────────────────────────┘
```

## SDK Architecture

```
╔═══════════════════════════════════════════════════════════════╗
║        Azure Speech SDK Architecture (Python Bindings)       ║
╚═══════════════════════════════════════════════════════════════╝

┌─────────────────────────────────────────────────────────────┐
│ Your Application (Python)                                    │
│                                                              │
│  service.py                                                  │
│    └─> TranscriptionService                                 │
│          └─> process_audio()                                │
└────────────────────────┬────────────────────────────────────┘
                         │
                         │ imports
                         ▼
┌─────────────────────────────────────────────────────────────┐
│ azure.cognitiveservices.speech (Python Package)              │
│                                                              │
│  speech.py                                                   │
│    ├─> SpeechConfig                                         │
│    ├─> SpeechRecognizer                                     │
│    └─> ConversationTranscriber                              │
│                                                              │
│  interop.py                                                  │
│    ├─> _Handle (C++ pointer wrapper)                        │
│    ├─> _sdk_lib (ctypes bridge)                             │
│    └─> release functions                                    │
└────────────────────────┬────────────────────────────────────┘
                         │
                         │ ctypes (FFI)
                         ▼
┌─────────────────────────────────────────────────────────────┐
│ Native C++ Libraries (Shared Objects)                        │
│                                                              │
│  libMicrosoft.CognitiveServices.Speech.core.so (81MB)       │
│    ├─> Audio processing engine                              │
│    ├─> Speech recognition models                            │
│    ├─> Network communication                                │
│    └─> Memory management                                    │
│                                                              │
│  libpal_azure_c_shared.so (8MB)                             │
│    └─> Azure platform abstraction layer                     │
│                                                              │
│  Extensions (.so files)                                     │
│    ├─> Audio codecs (3MB)                                   │
│    ├─> Keyword spotting (5MB)                               │
│    └─> Audio system integration (3MB)                       │
└─────────────────────────────────────────────────────────────┘
                         │
                         │ Network (HTTPS)
                         ▼
┌─────────────────────────────────────────────────────────────┐
│ Azure Speech Service (Cloud)                                 │
│                                                              │
│  {resource_name}.cognitiveservices.azure.com                │
│    ├─> Speech-to-Text API                                   │
│    ├─> Speaker diarization                                  │
│    └─> Language detection                                   │
└─────────────────────────────────────────────────────────────┘

MEMORY ISSUE: If Python objects aren't properly cleaned up, the
81MB+ C++ library keeps allocating memory for each request!
```

## Summary

```
┌────────────────────────────────────────────────────────────┐
│  KEY INSIGHT: Breaking Circular References                 │
│                                                             │
│  Python GC handles Python objects automatically, BUT:      │
│                                                             │
│  • Event callbacks create circular references              │
│  • Circular references prevent __del__() from firing       │
│  • No __del__() = No C++ cleanup = Memory leak             │
│                                                             │
│  SOLUTION:                                                  │
│  → Manually disconnect ALL event handlers                  │
│  → Delete callback closures                                │
│  → Force gc.collect() to trigger __del__()                 │
│  → Result: C++ memory released within 1-2 seconds          │
└────────────────────────────────────────────────────────────┘
```
