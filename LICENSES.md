# Third-party licenses and attribution

Zoomies is released under the MIT License (see [LICENSE](LICENSE)).

## Runtime dependencies

| Component | Use | License |
|---|---|---|
| SQLite (system `libsqlite3` on macOS) | result store | Public domain |
| Apple frameworks (Foundation, Metal, IOKit, CryptoKit) | platform APIs | Apple SDK terms |

Zoomies has no third-party Swift packages.

## External tools Zoomies runs (not bundled)

| Tool | License |
|---|---|
| [llama.cpp](https://github.com/ggml-org/llama.cpp) (`llama-bench`) | MIT (see its LICENSE). Zoomies only runs it and does not bundle it yet; bundling requires shipping that notice. |

## Test fixtures generated locally

`Tests/ZoomiesKitTests/Fixtures/llama-bench-b12359-help.txt` and `real-b12359-m5-qwen1.5b.*` are output that llama.cpp's llama-bench (MIT) printed on the dev Mac. The model path is anonymized. The model is Qwen2.5-1.5B-Instruct-GGUF (Apache-2.0); no model data is included.

## Attribution: llama-autotune

[llama-autotune](https://github.com/Najafu/llama-autotune), MIT License, Copyright (c) 2026 llama-autotune.

Zoomies contains **no source code** from llama-autotune. It does contain:

- **Test fixture:** `Tests/ZoomiesKitTests/Fixtures/llama-bench-b11347-help.txt` is copied from llama-autotune's `tests/fixtures/`. It is the `--help` output of llama.cpp's llama-bench (build 11347).
- **Design ideas, adapted:**
  - removing `LLAMA_ARG_*` environment variables before running llama.cpp;
  - checking options against the installed build's `--help` instead of assuming them;
  - interleaving configurations so background drift hits all of them equally;
  - testing at KV-cache depth as well as on an empty context.

The MIT notice, which applies to the copied fixture:

```
MIT License

Copyright (c) 2026 llama-autotune

Permission is hereby granted, free of charge, to any person obtaining a copy
of this software and associated documentation files (the "Software"), to deal
in the Software without restriction, including without limitation the rights
to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
copies of the Software, and to permit persons to whom the Software is
furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in all
copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
SOFTWARE.
```
