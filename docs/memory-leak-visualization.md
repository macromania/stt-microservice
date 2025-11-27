# C++ Memory Leak Visualization

## Memory Leak Mechanism

```
┌─────────────────────────────────────────────────────────────────┐
│                     CIRCULAR REFERENCE CYCLE                    │
│                    (Prevents Garbage Collection)                │
└─────────────────────────────────────────────────────────────────┘

    ┌──────────────────────────────────────────────────────┐
    │                                                      │
    │  ┌─────────────────────────────────────────────┐     │
    │  │  ConversationTranscriber (Python object)    │     │
    │  │  • _handle → C++ pointer (81MB native)      │     │
    │  │  • __transcribed_signal → EventSignal       │     │
    │  └───────────────┬─────────────────────────────┘     │
    │                  │                                   │
    │                  │ owns                              │
    │                  ▼                                   │
    │  ┌─────────────────────────────────────────────┐     │
    │  │  EventSignal                                │     │
    │  │  • __callbacks = [on_transcribed]           │     │
    │  │  • __context → ConversationTranscriber      │     │
    │  └───────────────┬─────────────────────────────┘     │
    │                  │                                   │
    │                  │ contains                          │
    │                  ▼                                   │
    │  ┌─────────────────────────────────────────────┐     │
    │  │  on_transcribed (closure)                   │     │
    │  │  • Captures: segments, transcriber, done    │     │
    │  └───────────────┬─────────────────────────────┘     │
    │                  │                                   │
    │                  │ references                        │
    └──────────────────┘                                   │
                                                           │
        CIRCULAR REFERENCE LOOP! ──────────────────────────┘

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
│                                                             │
│  1000MB ┤                                             ▲     │
│         │                                       ▲▲▲▲▲ ││    │
│   800MB ┤                           ▲▲▲▲▲▲▲▲▲▲ ││││││││     │
│         │                   ▲▲▲▲▲▲▲ │││││││││││││││││││     │
│   600MB ┤           ▲▲▲▲▲▲▲ │││││││││││││││││││││││││││     │
│         │   ▲▲▲▲▲▲▲ ││││││││││││││││││││││││││││││││││      │
│   400MB ┤▲▲▲│││││││││││││││││││││││││││││││││││││││││││     │
│         │││││││││││││││││││││││││││││││││││││││││││││││     │
│   200MB ┤│││││││││││││││││││││││││││││││││││││││││││││      │
│         └┴┴┴┴┴┴┴┴┴┴┴┴┴┴┴┴┴┴┴┴┴┴┴┴┴┴┴┴┴┴┴┴┴┴┴┴┴┴┴┴┴┴┴┴┴      │
│          0   10   20   30   40   50   60   70   80   90  100│
│                          Requests                           │
└─────────────────────────────────────────────────────────────┘
```

## Summary

```
┌────────────────────────────────────────────────────────────┐
│  KEY INSIGHT: Breaking Circular References                 │
│                                                            │
│  Python GC handles Python objects automatically, BUT:      │
│                                                            │
│  • Event callbacks create circular references              │
│  • Circular references prevent __del__() from firing       │
│  • No __del__() = No C++ cleanup = Memory leak             │
│                                                            │
└────────────────────────────────────────────────────────────┘
```
