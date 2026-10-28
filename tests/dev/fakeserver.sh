#!/bin/bash
# fake llama-server for dashboard tests (Linux/macOS dev only). Env: FAKE_EXIT_AFTER (s), FAKE_EXIT_CODE, FAKE_NO_IDLE=1 (readiness then only via /health)
echo "load_backend: loaded CPU backend from C:\\x\\ggml-cpu-haswell.dll"
echo "build: 10453 (3cb7ffb1a) with Clang 20.1.8 for Windows x86_64"
echo "system_info: n_threads = 4 (n_threads_batch = 4) / 8 | CPU : SSE3 = 1 | SSSE3 = 1 | AVX = 1 | AVX2 = 1 | F16C = 1 | FMA = 1 | BMI2 = 1 |"
echo "srv    load_model: (startup) loading model C:\\m.gguf"
echo "llama_context: n_ctx         = 4096"
echo "llama_context: n_ctx_train   = 32768"
sleep 1
echo "srv  start: listening on http://127.0.0.1:18080"
[ -z "$FAKE_NO_IDLE" ] && echo "srv  update_slots: all slots are idle"
sleep 1
echo "slot print_timing: id  0 | task 0 |"
echo "prompt eval time =     828.71 ms /    26 tokens (   31.87 ms per token,    31.37 tokens per second)"
echo "       eval time =   26855.14 ms /   197 tokens (  136.32 ms per token,     7.34 tokens per second)"
echo "      total time =   27683.85 ms /   223 tokens"
echo "prompt eval time =     100.00 ms /     5 tokens (   20.00 ms per token,    50.00 tokens per second)"
echo "prompt eval time =     866.50 ms /    30 tokens (   28.88 ms per token,    34.62 tokens per second)"
echo "       eval time =   22698.00 ms /   180 tokens (  126.10 ms per token,     7.93 tokens per second)"
echo "      total time =   23564.50 ms /   210 tokens"
echo "srv  operator(): couldn't bind HTTP server socket, hostname: 127.0.0.1, port: 8080" >&2
sleep ${FAKE_EXIT_AFTER:-3}
exit ${FAKE_EXIT_CODE:-0}
