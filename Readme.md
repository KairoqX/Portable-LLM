# ⚡ Portable LLM

> **Run a local LLM directly from a USB drive — no installation required.**

A simple, lightweight and portable local AI setup powered by **llama.cpp**.

Plug in your USB → run `START.bat` → choose a model → your local AI opens in the browser.

Everything runs locally on your computer.

---

## ✨ Features

* 🧠 Run local LLMs with **GGUF** models
* 💾 Designed to run directly from a USB drive
* 🚫 No Ollama installation required
* 🚫 No Python installation required
* 🌐 Built-in browser-based Web UI
* 🔄 Automatic model selection
* 📁 Supports multiple GGUF models
* 🔌 Drive-letter independent paths
* 🪶 Lightweight and easy to carry
* 🔒 Runs locally on `127.0.0.1`

---

## 📂 Folder Structure

```text
Portable-LLM/
│
├── START.bat              # Start the LLM
├── STOP.bat               # Stop the LLM
├── CONFIG.bat             # Configuration
├── README.md
├── .gitignore
│
├── llama/
│   ├── llama-server.exe
│   └── required DLL files
│
├── models/
│   └── YourModel.gguf
│
└── logs/
```

---

## 🚀 Quick Start

### 1. Download llama.cpp

Download the latest Windows build from the official repository:

**[llama.cpp Releases](https://github.com/ggml-org/llama.cpp/releases)**

Extract the required files into:

```text
llama/
```

Make sure you have:

```text
llama/llama-server.exe
```

and any required DLL files that came with the release.

---

### 2. Download a GGUF Model

Download a compatible `.gguf` model and place it inside:

```text
models/
```

Example:

```text
models/
└── Qwen3-2B-Q4_K_M.gguf
```

---

### 3. Start

Double-click:

```text
START.bat
```

You'll get a model selection menu:

```text
==========================================
         PORTABLE LLM - V2
==========================================

Available models:

[1] Qwen3-2B-Q4_K_M.gguf
[2] AnotherModel.gguf

Select model number:
```

Choose your model and the local web interface will open.

Default address:

```text
http://127.0.0.1:8080
```

---

## 🧠 Recommended Models

### 🥇 Qwen3-2B — Best Lightweight Choice

**Recommended quantization:** `Q4_K_M`

Good for:

* General chatting
* Basic coding
* Explanations
* School/study assistance
* Low-RAM systems
* Portable USB setups

**Download:**

[Qwen3-2B-GGUF — Hugging Face](https://huggingface.co/unsloth/Qwen3-2B-GGUF)

---

### 🥈 Qwen3-4B — Better Quality

**Recommended quantization:** `Q4_K_M`

A stronger option if your PC has enough RAM.

Good for:

* General conversations
* Coding
* Reasoning
* Writing
* More complex questions

**Download:**

[Qwen3-4B-GGUF — Hugging Face](https://huggingface.co/unsloth/Qwen3-4B-GGUF)

---

### 🥉 TinyLlama 1.1B — Very Lightweight

A very small model intended for systems where speed and low memory usage matter more than quality.

Good for:

* Testing
* Very low-end hardware
* Extremely small portable setups

**Download:**

[TinyLlama-1.1B-Chat-v1.0-GGUF — Hugging Face](https://huggingface.co/TheBloke/TinyLlama-1.1B-Chat-v1.0-GGUF)

---

## 📊 Which Model Should I Use?

| Model              |    Size Class | Quality | Speed | Recommended     |
| ------------------ | ------------: | ------: | ----: | --------------- |
| **Qwen3-2B Q4**    |      🟢 Small |    ⭐⭐⭐⭐ |  ⚡⚡⚡⚡ | ⭐ Best portable |
| **Qwen3-4B Q4**    |     🟡 Medium |   ⭐⭐⭐⭐⭐ |   ⚡⚡⚡ | Best quality    |
| **TinyLlama 1.1B** | 🟢 Very Small |      ⭐⭐ | ⚡⚡⚡⚡⚡ | Low-end PCs     |

> 💡 For an **8 GB RAM laptop**, start with **Qwen3-2B Q4_K_M**. If performance is acceptable, move up to **Qwen3-4B Q4_K_M**.

---

## 💾 USB Storage Recommendations

Approximate setup:

```text
llama.cpp files     ~100–300 MB
Qwen3-2B Q4        ~1–2 GB
Qwen3-4B Q4        ~2–3 GB
```

A **4 GB+ USB drive** can work for a basic setup.

For multiple models, a **16 GB or 32 GB USB drive** is much more comfortable.

---

## 🔒 Privacy

This project is designed for local inference.

Your prompts and model responses are processed by the local llama.cpp server.

The server is bound to:

```text
127.0.0.1
```

so it is intended to be accessible only from your own computer.

**Do not expose the server to your network or the internet unless you understand the security implications.**

---

## 🛠️ How It Works

```text
              USB Drive
                  │
                  ▼
             START.bat
                  │
                  ▼
          Select GGUF Model
                  │
                  ▼
          llama-server.exe
                  │
                  ▼
        Localhost : 8080
                  │
                  ▼
             Web Browser
                  │
                  ▼
             🤖 Local LLM
```

---

## 📌 Adding More Models

Just place another `.gguf` file inside:

```text
models/
```

For example:

```text
models/
├── Qwen3-2B-Q4_K_M.gguf
├── Qwen3-4B-Q4_K_M.gguf
└── TinyLlama.gguf
```

Run `START.bat` again and the launcher will detect the models automatically.

---

## 📜 Credits

This project uses:

* **[llama.cpp](https://github.com/ggml-org/llama.cpp)** — Local LLM inference engine
* **Qwen** — Recommended model family
* **GGUF** — Model format

This project does not bundle llama.cpp binaries or model weights.

Please follow the individual licenses of the software and models you download.

---

## ⭐ Support

If this project helped you run a local LLM portably:

**⭐ Star the repository**

and feel free to contribute improvements!

---

### 👨‍💻 Made for portable AI

**Plug in. Run. Chat. No installation.**

`USB → START.bat → 🤖`
