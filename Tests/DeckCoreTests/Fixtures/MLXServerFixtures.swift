import Foundation

/// Recorded mlx_lm.server output from the owner's v1.1.0 run (6 Nov 2026), mlx-lm 0.32.2, model
/// mlx-community/Qwen3.8-27B-MTP-4bit (model_type qwen3_5_mtp).
enum MLXServerFixtures {
    /// The generation thread died, then the HTTP server started anyway and answered.
    static let generationThreadDied = #"""
2026-11-06 21:48:55,536 - ERROR - mlx_lm.server generation thread died: Model type qwen3_5_mtp not supported.
Traceback (most recent call last):
  File "/Users/suresh/Library/Application Support/io.github.sur950.containerdeck/AI/uv-tools/mlx-lm/lib/python3.12/site-packages/mlx_lm/utils.py", line 222, in _get_classes
    arch = importlib.import_module(f"mlx_lm.models.{model_type}")
           ^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^
  File "/Users/suresh/Library/Application Support/io.github.sur950.containerdeck/AI/python/cpython-3.12.12-macos-aarch64-none/lib/python3.12/importlib/__init__.py", line 90, in import_module
    return _bootstrap._gcd_import(name[level:], package, level)
           ^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^
  File "<frozen importlib._bootstrap>", line 1387, in _gcd_import
  File "<frozen importlib._bootstrap>", line 1360, in _find_and_load
  File "<frozen importlib._bootstrap>", line 1324, in _find_and_load_unlocked
ModuleNotFoundError: No module named 'mlx_lm.models.qwen3_5_mtp'

The above exception was the direct cause of the following exception:

Traceback (most recent call last):
  File "/Users/suresh/Library/Application Support/io.github.sur950.containerdeck/AI/uv-tools/mlx-lm/lib/python3.12/site-packages/mlx_lm/server.py", line 544, in _run_generate
    self._generate()
  File "/Users/suresh/Library/Application Support/io.github.sur950.containerdeck/AI/uv-tools/mlx-lm/lib/python3.12/site-packages/mlx_lm/server.py", line 782, in _generate
    self.model_provider.load_default()
  File "/Users/suresh/Library/Application Support/io.github.sur950.containerdeck/AI/uv-tools/mlx-lm/lib/python3.12/site-packages/mlx_lm/server.py", line 475, in load_default
    self.load("default_model", None, "default_model")
  File "/Users/suresh/Library/Application Support/io.github.sur950.containerdeck/AI/uv-tools/mlx-lm/lib/python3.12/site-packages/mlx_lm/server.py", line 484, in load
    self._load(*model_key)
  File "/Users/suresh/Library/Application Support/io.github.sur950.containerdeck/AI/uv-tools/mlx-lm/lib/python3.12/site-packages/mlx_lm/server.py", line 436, in _load
    model, tokenizer, config = load(
                               ^^^^^
  File "/Users/suresh/Library/Application Support/io.github.sur950.containerdeck/AI/uv-tools/mlx-lm/lib/python3.12/site-packages/mlx_lm/utils.py", line 690, in load
    model, config = load_model(
                    ^^^^^^^^^^^
  File "/Users/suresh/Library/Application Support/io.github.sur950.containerdeck/AI/uv-tools/mlx-lm/lib/python3.12/site-packages/mlx_lm/utils.py", line 474, in load_model
    model_class, model_args_class = get_model_classes(config=config)
                                    ^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^
  File "/Users/suresh/Library/Application Support/io.github.sur950.containerdeck/AI/uv-tools/mlx-lm/lib/python3.12/site-packages/mlx_lm/utils.py", line 225, in _get_classes
    raise ValueError(msg) from e
ValueError: Model type qwen3_5_mtp not supported.
/Users/suresh/Library/Application Support/io.github.sur950.containerdeck/AI/uv-tools/mlx-lm/lib/python3.12/site-packages/mlx_lm/server.py:1894: UserWarning: mlx_lm.server is not recommended for production as it only implements basic security checks.
  warnings.warn(
2026-11-06 21:48:55,543 - INFO - Starting httpd at 127.0.0.1 on port 8585...
127.0.0.1 - - [06/Nov/2026 21:49:11] "POST /v1/chat/completions HTTP/1.1" 404 -
127.0.0.1 - - [06/Nov/2026 21:49:33] "GET /v1/models HTTP/1.1" 200 -
"""#

    /// An earlier run: the same load failure, then the --host address was not on any interface.
    static let bindFailure = #"""
                                    ^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^
  File "/Users/suresh/Library/Application Support/io.github.sur950.containerdeck/AI/uv-tools/mlx-lm/lib/python3.12/site-packages/mlx_lm/utils.py", line 225, in _get_classes
    raise ValueError(msg) from e
ValueError: Model type qwen3_5_mtp not supported.
Traceback (most recent call last):
  File "/Users/suresh/Library/Application Support/io.github.sur950.containerdeck/AI/bin/mlx_lm.server", line 12, in <module>
    sys.exit(main())
             ^^^^^^
  File "/Users/suresh/Library/Application Support/io.github.sur950.containerdeck/AI/uv-tools/mlx-lm/lib/python3.12/site-packages/mlx_lm/server.py", line 2086, in main
    run(args.host, args.port, ModelProvider(args))
  File "/Users/suresh/Library/Application Support/io.github.sur950.containerdeck/AI/uv-tools/mlx-lm/lib/python3.12/site-packages/mlx_lm/server.py", line 1917, in run
    _run_http_server(host, port, response_generator)
  File "/Users/suresh/Library/Application Support/io.github.sur950.containerdeck/AI/uv-tools/mlx-lm/lib/python3.12/site-packages/mlx_lm/server.py", line 1885, in _run_http_server
    httpd = server_class(
            ^^^^^^^^^^^^^
  File "/Users/suresh/Library/Application Support/io.github.sur950.containerdeck/AI/python/cpython-3.12.12-macos-aarch64-none/lib/python3.12/socketserver.py", line 457, in __init__
    self.server_bind()
  File "/Users/suresh/Library/Application Support/io.github.sur950.containerdeck/AI/python/cpython-3.12.12-macos-aarch64-none/lib/python3.12/http/server.py", line 136, in server_bind
    socketserver.TCPServer.server_bind(self)
  File "/Users/suresh/Library/Application Support/io.github.sur950.containerdeck/AI/python/cpython-3.12.12-macos-aarch64-none/lib/python3.12/socketserver.py", line 478, in server_bind
    self.socket.bind(self.server_address)
OSError: [Errno 49] Can't assign requested address
"""#
}
