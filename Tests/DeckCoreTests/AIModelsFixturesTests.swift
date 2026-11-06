import Foundation

// Real output recorded on this Mac on 5 Nov 2026: Ollama 0.16.2, mlx-lm 0.32.2 (mlx_lm.server),
// and the public Hugging Face API. SSE streams are trimmed to a few chunks.
enum AIFixtures {
    static let ollamaVersion = #"""
{"version":"0.16.2"}
"""#

    static let ollamaTags = #"""
{"models":[{"name":"mistral:latest","model":"mistral:latest","modified_at":"2026-02-11T16:25:54.334179028+05:30","size":4372824384,"digest":"6577803aa9a036369e481d648a2baebb381ebc6e897f2bb9a766a2aa7bfbc1cf","details":{"parent_model":"","format":"gguf","family":"llama","families":["llama"],"parameter_size":"7.2B","quantization_level":"Q4_K_M"}},{"name":"tinyllama:latest","model":"tinyllama:latest","modified_at":"2026-02-11T16:00:36.2663891+05:30","size":637700138,"digest":"2644915ede352ea7bdfaff0bfac0be74c719d5d5202acb63a6fb095b52f394a4","details":{"parent_model":"","format":"gguf","family":"llama","families":["llama"],"parameter_size":"1B","quantization_level":"Q4_0"}},{"name":"qwen3:0.6b","model":"qwen3:0.6b","modified_at":"2026-02-11T15:56:08.569345208+05:30","size":522653767,"digest":"7df6b6e09427a769808717c0a93cadc4ae99ed4eb8bf5ca557c90846becea435","details":{"parent_model":"","format":"gguf","family":"qwen3","families":["qwen3"],"parameter_size":"751.63M","quantization_level":"Q4_K_M"}}]}
"""#

    static let ollamaV1Models = #"""
{"object":"list","data":[{"id":"mistral:latest","object":"model","created":1770807354,"owned_by":"library"},{"id":"tinyllama:latest","object":"model","created":1770805836,"owned_by":"library"},{"id":"qwen3:0.6b","object":"model","created":1770805568,"owned_by":"library"}]}
"""#

    static let ollamaPSEmpty = #"""
{"models":[]}
"""#

    static let ollamaPSLoaded = #"""
{"models":[{"name":"qwen3:0.6b","model":"qwen3:0.6b","size":4394327072,"digest":"7df6b6e09427a769808717c0a93cadc4ae99ed4eb8bf5ca557c90846becea435","details":{"parent_model":"","format":"gguf","family":"qwen3","families":["qwen3"],"parameter_size":"751.63M","quantization_level":"Q4_K_M"},"expires_at":"2319-02-15T22:11:33.333381807+05:30","size_vram":4394327072,"context_length":32768}]}
"""#

    static let ollamaPull = #"""
{"status":"pulling manifest"}
{"status":"pulling 7f4030143c1c","digest":"sha256:7f4030143c1c477224c5434f8272c662a8b042079a0a584f0a27a1684fe2e1fa","total":522640096,"completed":522640096}
{"status":"pulling ae370d884f10","digest":"sha256:ae370d884f108d16e7cc8fd5259ebc5773a0afa6e078b11f4ed7e39a27e0dfc4","total":1723,"completed":1723}
{"status":"pulling d18a5cc71b84","digest":"sha256:d18a5cc71b84bc4af394a31116bd3932b42241de70c77d2b76d69a314ec8aa12","total":11338,"completed":11338}
{"status":"pulling cff3f395ef37","digest":"sha256:cff3f395ef3756ab63e58b0ad1b32bb6f802905cae1472e6a12034e4246fbbdb","total":120,"completed":120}
{"status":"pulling b0830f4ff6a0","digest":"sha256:b0830f4ff6a0220cfd995455206353b0ed23c0aee865218b154b7a75087b4e55","total":490,"completed":490}
{"status":"verifying sha256 digest"}
{"status":"writing manifest"}
{"status":"success"}
"""#

    static let mlxV1Models = #"""
{"object": "list", "data": [{"id": "/private/tmp/ai rt/models/mlx-community/SmolLM-135M-Instruct-4bit", "object": "model", "created": 1793897794}]}
"""#

    static let hfSearch = #"""
[{"_id":"6696e0d58b2b1bd619807170","id":"mlx-community/SmolLM-135M-Instruct-4bit","lastModified":"2024-07-16T21:06:40.000Z","likes":6,"downloads":8305,"safetensors":{"parameters":{"U32":134479872,"F16":35136},"total":134515008},"tags":["transformers","safetensors","llama","text-generation","mlx","conversational","en","license:apache-2.0","text-generation-inference","endpoints_compatible","region:us"],"pipeline_tag":"text-generation"},{"_id":"67240298552e3589e04e7171","id":"mlx-community/SmolLM2-135M-Instruct","lastModified":"2024-10-31T22:20:24.000Z","likes":0,"downloads":4092,"safetensors":{"parameters":{"BF16":134515008},"total":134515008},"tags":["transformers","safetensors","llama","text-generation","mlx","conversational","en","base_model:HuggingFaceTB/SmolLM2-135M-Instruct","base_model:finetune:HuggingFaceTB/SmolLM2-135M-Instruct","license:apache-2.0","text-generation-inference","endpoints_compatible","region:us"],"pipeline_tag":"text-generation"},{"_id":"686d4201612a0889e6e07d17","id":"mlx-community/SmolLM3-3B-4bit","lastModified":"2025-07-08T16:16:14.000Z","likes":7,"downloads":3571,"safetensors":{"parameters":{"U32":3074949120,"BF16":149504},"total":3075098624},"tags":["mlx","safetensors","smollm3","text-generation","conversational","en","fr","es","it","pt","zh","ar","ru","base_model:HuggingFaceTB/SmolLM3-3B","base_model:quantized:HuggingFaceTB/SmolLM3-3B","license:apache-2.0","4-bit","region:us"],"pipeline_tag":"text-generation"}]
"""#

    static let hfTree = #"""
[{"type":"file","oid":"a6344aac8c09253b3b630fb776ae94478aa0275b","size":1519,"path":".gitattributes"},{"type":"file","oid":"e8422736286c02b4394cb2de63b178b1317b9a3a","size":638,"path":"README.md"},{"type":"file","oid":"95e3730d82fbbbf67d4db557a0e9494f01542023","size":803,"path":"config.json"},{"type":"file","oid":"69503b13f727ba3812b6803e97442a6de05ef5eb","size":466391,"path":"merges.txt"},{"type":"file","oid":"faff1b66d0b163ec3066d09e5d2b58af64b32ad5","size":75789919,"lfs":{"oid":"e91560ee24b13eee6ddeb14879d728a90780053d69057b15ff199ccadfcfe33b","size":75789919,"pointerSize":133},"xetHash":"390ad518644d67751d20589235916765c7c407aed1a4aff1bbad3684a3ab5950","path":"model.safetensors"},{"type":"file","oid":"31a2152f8a0bc7b22f211989a798a17c4bb01f49","size":48978,"path":"model.safetensors.index.json"},{"type":"file","oid":"44719d2e365acac0637fd25a3acf46494ca45940","size":655,"path":"special_tokens_map.json"},{"type":"file","oid":"f922b1797f0c88e71addc8393787831f2477a4bd","size":2104556,"path":"tokenizer.json"},{"type":"file","oid":"5154a1af2fdba4c9d21cc9cfc61a879745d75631","size":3590,"path":"tokenizer_config.json"},{"type":"file","oid":"0ad5ecc2035b7031b88afb544ee95e2d49baa484","size":800662,"path":"vocab.json"}]
"""#

    static let ollamaSSE = #"""
data: {"id":"chatcmpl-472","object":"chat.completion.chunk","created":1793897656,"model":"qwen3:0.6b","system_fingerprint":"fp_ollama","choices":[{"index":0,"delta":{"role":"assistant","content":"","reasoning":"Okay"},"finish_reason":null}]}

data: {"id":"chatcmpl-472","object":"chat.completion.chunk","created":1793897656,"model":"qwen3:0.6b","system_fingerprint":"fp_ollama","choices":[{"index":0,"delta":{"role":"assistant","content":"","reasoning":","},"finish_reason":null}]}

data: {"id":"chatcmpl-472","object":"chat.completion.chunk","created":1793897657,"model":"qwen3:0.6b","system_fingerprint":"fp_ollama","choices":[{"index":0,"delta":{"role":"assistant","content":"Hello"},"finish_reason":null}]}

data: {"id":"chatcmpl-472","object":"chat.completion.chunk","created":1793897657,"model":"qwen3:0.6b","system_fingerprint":"fp_ollama","choices":[{"index":0,"delta":{"role":"assistant","content":"!"},"finish_reason":null}]}

data: {"id":"chatcmpl-472","object":"chat.completion.chunk","created":1793897657,"model":"qwen3:0.6b","system_fingerprint":"fp_ollama","choices":[{"index":0,"delta":{"role":"assistant","content":""},"finish_reason":"stop"}]}

data: {"id":"chatcmpl-472","object":"chat.completion.chunk","created":1793897657,"model":"qwen3:0.6b","system_fingerprint":"fp_ollama","choices":[],"usage":{"prompt_tokens":20,"completion_tokens":182,"total_tokens":202}}

data: [DONE]
"""#

    static let mlxSSE = #"""
: keepalive 10/11

: keepalive 11/11

data: {"id": "chatcmpl-374fdd71-10cc-4950-a859-e95ebb0f72d8", "system_fingerprint": "0.32.2-0.32.4-macOS-27.2-arm64-arm-64bit-applegpu_g17g", "object": "chat.completion.chunk", "model": "/tmp/ai rt/models/mlx-community/SmolLM-135M-Instruct-4bit", "created": 1793897794, "choices": [{"index": 0, "finish_reason": null, "delta": {"role": "assistant", "content": "We"}}]}

data: {"id": "chatcmpl-374fdd71-10cc-4950-a859-e95ebb0f72d8", "system_fingerprint": "0.32.2-0.32.4-macOS-27.2-arm64-arm-64bit-applegpu_g17g", "object": "chat.completion.chunk", "model": "/tmp/ai rt/models/mlx-community/SmolLM-135M-Instruct-4bit", "created": 1793897794, "choices": [{"index": 0, "finish_reason": "length", "delta": {"role": "assistant"}}]}

data: {"id": "chatcmpl-374fdd71-10cc-4950-a859-e95ebb0f72d8", "system_fingerprint": "0.32.2-0.32.4-macOS-27.2-arm64-arm-64bit-applegpu_g17g", "object": "chat.completion", "model": "/tmp/ai rt/models/mlx-community/SmolLM-135M-Instruct-4bit", "created": 1793897794, "choices": [], "usage": {"prompt_tokens": 11, "completion_tokens": 20, "total_tokens": 31, "prompt_tokens_details": {"cached_tokens": 0}}}

data: [DONE]
"""#

}
