import Foundation

// Real responses recorded on 9 Nov 2026, trimmed to a few entries:
// ollama.com/search?q=qwen (HTML), ollama.com/library/qwen3/tags (HTML and JSON),
// registry.ollama.ai manifest, lmstudio.ai/api/v1/artifacts?type=model, the model.yaml part of
// lmstudio.ai/models/qwen/qwen3-4b, and `lms ls --json` from LM Studio core 0.4 (llmster 0.0.27).
enum LibraryFixtures {
    static let ollamaSearch = #"""
<div hidden data-result-count="20" data-has-more="true"></div>
<ul role="list">
<li  class="border-t-[0.5px] border-line first:border-t-0">
  <a href="/library/qwen3.8" class="group grid grid-cols-1 gap-x-4 px-4 py-6 sm:grid-cols-[minmax(0,1fr)_auto] md:px-7">
    <div class="flex min-w-0 items-baseline gap-2.5">
      <h2 class="min-w-0 truncate text-xl font-medium leading-7 tracking-tight underline-offset-4 group-hover:underline" title="qwen3.8">
        <span >qwen3.8</span>
      </h2>
      <span class="flex-none text-[15px] tabular-nums text-muted" title="Updated November 8, 2026">1d</span>
    </div>
    <div class="order-last mt-3 flex flex-wrap items-center gap-2 text-[13px] leading-5 sm:order-none sm:mt-0 sm:max-w-[20rem] sm:justify-end sm:self-center"><span  class="inline-flex items-center rounded-md bg-indigo-50 px-2 py-0.5 text-xs font-medium text-indigo-600 sm:text-[13px]">vision</span><span  class="inline-flex items-center rounded-md bg-indigo-50 px-2 py-0.5 text-xs font-medium text-indigo-600 sm:text-[13px]">tools</span><span  class="inline-flex items-center rounded-md bg-indigo-50 px-2 py-0.5 text-xs font-medium text-indigo-600 sm:text-[13px]">thinking</span>
    </div>
    <p class="mt-1 line-clamp-2 text-[15px] leading-6 text-black sm:col-span-2">Qwen3.8 delivers substantial gains across coding, professional work, research, and long-horizon agentic tasks.</p>
    <div class="mt-3 flex flex-wrap items-center gap-2 text-sm text-black/60 sm:col-span-2 [&_svg]:size-[15px]">
      <span class="inline-flex items-center gap-1.5 tabular-nums text-ink sm:mr-1" title="6,089,193 downloads"><svg class="flex-none" width="15" height="15" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.75" stroke-linecap="round" stroke-linejoin="round" aria-hidden="true"><path d="M12 3.5v12M6.5 10.5l5.5 5.5 5.5-5.5M4.5 20.5h15"/></svg><span >6.1M</span></span>
      <span class="inline-flex items-center gap-1.5 tabular-nums text-ink sm:mr-1"><svg class="flex-none" width="15" height="15" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.75" stroke-linecap="round" stroke-linejoin="round" aria-hidden="true"><path d="M3.5 12.4V5a1.5 1.5 0 0 1 1.5-1.5h7.4a1.5 1.5 0 0 1 1 .4l7.2 7.2a1.5 1.5 0 0 1 0 2.2l-7.3 7.3a1.5 1.5 0 0 1-2.2 0l-7.2-7.2a1.5 1.5 0 0 1-.4-1z"/><circle cx="8.2" cy="8.2" r="1.1" fill="currentColor" stroke="none"/></svg><span >13 tags</span></span>
      <span  class="inline-flex items-center rounded-md bg-[#ddf4ff] px-2 py-0.5 text-xs font-medium text-blue-600 sm:text-[13px]">27b</span>
    </div>
  </a>
</li>
<li  class="border-t-[0.5px] border-line first:border-t-0">
  <a href="/library/qwen3" class="group grid grid-cols-1 gap-x-4 px-4 py-6 sm:grid-cols-[minmax(0,1fr)_auto] md:px-7">
    <div class="flex min-w-0 items-baseline gap-2.5">
      <h2 class="min-w-0 truncate text-xl font-medium leading-7 tracking-tight underline-offset-4 group-hover:underline" title="qwen3">
        <span >qwen3</span>
      </h2>
      <span class="flex-none text-[15px] tabular-nums text-muted" title="Updated October 10, 2025">1y</span>
    </div>
    <div class="order-last mt-3 flex flex-wrap items-center gap-2 text-[13px] leading-5 sm:order-none sm:mt-0 sm:max-w-[20rem] sm:justify-end sm:self-center"><span  class="inline-flex items-center rounded-md bg-indigo-50 px-2 py-0.5 text-xs font-medium text-indigo-600 sm:text-[13px]">tools</span><span  class="inline-flex items-center rounded-md bg-indigo-50 px-2 py-0.5 text-xs font-medium text-indigo-600 sm:text-[13px]">thinking</span>
    </div>
    <p class="mt-1 line-clamp-2 text-[15px] leading-6 text-black sm:col-span-2">Qwen3 is the latest generation of large language models in Qwen series, offering a comprehensive suite of dense and mixture-of-experts (MoE) models.</p>
    <div class="mt-3 flex flex-wrap items-center gap-2 text-sm text-black/60 sm:col-span-2 [&_svg]:size-[15px]">
      <span class="inline-flex items-center gap-1.5 tabular-nums text-ink sm:mr-1" title="42,889,046 downloads"><svg class="flex-none" width="15" height="15" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.75" stroke-linecap="round" stroke-linejoin="round" aria-hidden="true"><path d="M12 3.5v12M6.5 10.5l5.5 5.5 5.5-5.5M4.5 20.5h15"/></svg><span >42.9M</span></span>
      <span class="inline-flex items-center gap-1.5 tabular-nums text-ink sm:mr-1"><svg class="flex-none" width="15" height="15" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.75" stroke-linecap="round" stroke-linejoin="round" aria-hidden="true"><path d="M3.5 12.4V5a1.5 1.5 0 0 1 1.5-1.5h7.4a1.5 1.5 0 0 1 1 .4l7.2 7.2a1.5 1.5 0 0 1 0 2.2l-7.3 7.3a1.5 1.5 0 0 1-2.2 0l-7.2-7.2a1.5 1.5 0 0 1-.4-1z"/><circle cx="8.2" cy="8.2" r="1.1" fill="currentColor" stroke="none"/></svg><span >58 tags</span></span>
      <span  class="inline-flex items-center rounded-md bg-[#ddf4ff] px-2 py-0.5 text-xs font-medium text-blue-600 sm:text-[13px]">0.6b</span>
      <span  class="inline-flex items-center rounded-md bg-[#ddf4ff] px-2 py-0.5 text-xs font-medium text-blue-600 sm:text-[13px]">1.7b</span>
      <span  class="inline-flex items-center rounded-md bg-[#ddf4ff] px-2 py-0.5 text-xs font-medium text-blue-600 sm:text-[13px]">4b</span>
      <span  class="inline-flex items-center rounded-md bg-[#ddf4ff] px-2 py-0.5 text-xs font-medium text-blue-600 sm:text-[13px]">8b</span>
      <span  class="inline-flex items-center rounded-md bg-[#ddf4ff] px-2 py-0.5 text-xs font-medium text-blue-600 sm:text-[13px]">14b</span>
      <span  class="inline-flex items-center rounded-md bg-[#ddf4ff] px-2 py-0.5 text-xs font-medium text-blue-600 sm:text-[13px]">30b</span>
      <span  class="inline-flex items-center rounded-md bg-[#ddf4ff] px-2 py-0.5 text-xs font-medium text-blue-600 sm:text-[13px]">32b</span>
      <span  class="inline-flex items-center rounded-md bg-[#ddf4ff] px-2 py-0.5 text-xs font-medium text-blue-600 sm:text-[13px]">235b</span>
    </div>
  </a>
</li>
<li  class="border-t-[0.5px] border-line first:border-t-0">
  <a href="/library/qwen3-embedding" class="group grid grid-cols-1 gap-x-4 px-4 py-6 sm:grid-cols-[minmax(0,1fr)_auto] md:px-7">
    <div class="flex min-w-0 items-baseline gap-2.5">
      <h2 class="min-w-0 truncate text-xl font-medium leading-7 tracking-tight underline-offset-4 group-hover:underline" title="qwen3-embedding">
        <span >qwen3-embedding</span>
      </h2>
      <span class="flex-none text-[15px] tabular-nums text-muted" title="Updated September 23, 2025">1y</span>
    </div>
    <div class="order-last mt-3 flex flex-wrap items-center gap-2 text-[13px] leading-5 sm:order-none sm:mt-0 sm:max-w-[20rem] sm:justify-end sm:self-center"><span  class="inline-flex items-center rounded-md bg-indigo-50 px-2 py-0.5 text-xs font-medium text-indigo-600 sm:text-[13px]">embedding</span>
    </div>
    <p class="mt-1 line-clamp-2 text-[15px] leading-6 text-black sm:col-span-2">Building upon the foundational models of the Qwen3 series, Qwen3 Embedding provides a comprehensive range of text embeddings models in various sizes</p>
    <div class="mt-3 flex flex-wrap items-center gap-2 text-sm text-black/60 sm:col-span-2 [&_svg]:size-[15px]">
      <span class="inline-flex items-center gap-1.5 tabular-nums text-ink sm:mr-1" title="4,538,102 downloads"><svg class="flex-none" width="15" height="15" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.75" stroke-linecap="round" stroke-linejoin="round" aria-hidden="true"><path d="M12 3.5v12M6.5 10.5l5.5 5.5 5.5-5.5M4.5 20.5h15"/></svg><span >4.5M</span></span>
      <span class="inline-flex items-center gap-1.5 tabular-nums text-ink sm:mr-1"><svg class="flex-none" width="15" height="15" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.75" stroke-linecap="round" stroke-linejoin="round" aria-hidden="true"><path d="M3.5 12.4V5a1.5 1.5 0 0 1 1.5-1.5h7.4a1.5 1.5 0 0 1 1 .4l7.2 7.2a1.5 1.5 0 0 1 0 2.2l-7.3 7.3a1.5 1.5 0 0 1-2.2 0l-7.2-7.2a1.5 1.5 0 0 1-.4-1z"/><circle cx="8.2" cy="8.2" r="1.1" fill="currentColor" stroke="none"/></svg><span >12 tags</span></span>
      <span  class="inline-flex items-center rounded-md bg-[#ddf4ff] px-2 py-0.5 text-xs font-medium text-blue-600 sm:text-[13px]">0.6b</span>
      <span  class="inline-flex items-center rounded-md bg-[#ddf4ff] px-2 py-0.5 text-xs font-medium text-blue-600 sm:text-[13px]">4b</span>
      <span  class="inline-flex items-center rounded-md bg-[#ddf4ff] px-2 py-0.5 text-xs font-medium text-blue-600 sm:text-[13px]">8b</span>
    </div>
  </a>
</li>
</ul>
"""#

    /// ollama.com/library (what an empty search shows, most popular first), one entry.
    static let ollamaLibraryPage = #"""
<li  class="flex items-baseline border-b border-neutral-200 py-6">
      <a href="/library/qwen3" class="group w-full space-y-5">
        <div  title="qwen3" class="flex flex-col">
          <h2 class="truncate text-xl font-medium underline-offset-2 md:text-2xl">
            <div class="flex space-x-2 items-center">
              <span class="group-hover:underline truncate">qwen3</span>
            </div>
          </h2>
          <p class="max-w-lg break-words text-neutral-800 text-md">Qwen3 is the latest generation of large language models in Qwen series, offering a comprehensive suite of dense and mixture-of-experts (MoE) models.</p>
        </div>
        <div class="flex flex-col space-y-2">
          <div class="flex flex-wrap space-x-2">
              <span  class="inline-flex items-center rounded-md bg-indigo-50 px-2 py-0.5 text-xs font-medium text-indigo-600 sm:text-[13px]">tools</span>
              <span  class="inline-flex items-center rounded-md bg-indigo-50 px-2 py-0.5 text-xs font-medium text-indigo-600 sm:text-[13px]">thinking</span>
              <span  class="inline-flex items-center rounded-md bg-[#ddf4ff] px-2 py-0.5 text-xs font-medium text-blue-600 sm:text-[13px]">0.6b</span>
              <span  class="inline-flex items-center rounded-md bg-[#ddf4ff] px-2 py-0.5 text-xs font-medium text-blue-600 sm:text-[13px]">1.7b</span>
              <span  class="inline-flex items-center rounded-md bg-[#ddf4ff] px-2 py-0.5 text-xs font-medium text-blue-600 sm:text-[13px]">4b</span>
              <span  class="inline-flex items-center rounded-md bg-[#ddf4ff] px-2 py-0.5 text-xs font-medium text-blue-600 sm:text-[13px]">8b</span>
              <span  class="inline-flex items-center rounded-md bg-[#ddf4ff] px-2 py-0.5 text-xs font-medium text-blue-600 sm:text-[13px]">14b</span>
              <span  class="inline-flex items-center rounded-md bg-[#ddf4ff] px-2 py-0.5 text-xs font-medium text-blue-600 sm:text-[13px]">30b</span>
              <span  class="inline-flex items-center rounded-md bg-[#ddf4ff] px-2 py-0.5 text-xs font-medium text-blue-600 sm:text-[13px]">32b</span>
              <span  class="inline-flex items-center rounded-md bg-[#ddf4ff] px-2 py-0.5 text-xs font-medium text-blue-600 sm:text-[13px]">235b</span>
          </div>
          <p class="flex space-x-5 text-[13px] font-medium text-neutral-500">
              <span class="flex items-center">
                <span >42.9M</span>
                <span class="hidden sm:flex">&nbsp;Pulls</span>
              </span>
              <span class="flex items-center">
                <span >58</span>
                <span class="hidden sm:flex">&nbsp;Tags</span>
              </span>
              <span class="flex items-center" title="Oct 10, 2025 8:18 PM UTC">
                <span class="hidden sm:flex">Updated&nbsp;</span>
                <span >1 year ago</span>
              </span>
          </p>
        </div>
      </a>
    </li>
"""#

    static let ollamaTagsPage = #"""
<div class="group px-4 py-3">
            
            <a href="/library/qwen3:latest" class="md:hidden flex flex-col space-y-[6px] group">
              <div class="flex items-center font-medium">
                <div class="flex items-center justify-between w-full">
                  <div>
                    <span class="group-hover:underline">qwen3:latest</span>
                    </span>
                    
                    
                  </div>              
                  
                </div>
              </div>
              <div class="flex flex-col text-neutral-500 text-[13px]">
                <span>
                  <span class="font-mono">
                    500a1f067a9f</span> • 5.2GB • 40K context window  •
                  <span class="hidden sm:inline">
                    Text input • 
                    1 year ago
                  </span>
                </span>
                  <div class="flex sm:hidden">
                    Text input • 
                    1 year ago
                  </div>
                </span>
              </div>
            </a>
            
            </div>
<div class="group px-4 py-3">
            
            <a href="/library/qwen3:0.6b" class="md:hidden flex flex-col space-y-[6px] group">
              <div class="flex items-center font-medium">
                <div class="flex items-center justify-between w-full">
                  <div>
                    <span class="group-hover:underline">qwen3:0.6b</span>
                    </span>
                    
                    
                  </div>              
                  
                </div>
              </div>
              <div class="flex flex-col text-neutral-500 text-[13px]">
                <span>
                  <span class="font-mono">
                    7df6b6e09427</span> • 523MB • 40K context window  •
                  <span class="hidden sm:inline">
                    Text input • 
                    1 year ago
                  </span>
                </span>
                  <div class="flex sm:hidden">
                    Text input • 
                    1 year ago
                  </div>
                </span>
              </div>
            </a>
            
            </div>
<div class="group px-4 py-3">
            
            <a href="/library/qwen3:8b-q8_0" class="md:hidden flex flex-col space-y-[6px] group">
              <div class="flex items-center font-medium">
                <div class="flex items-center justify-between w-full">
                  <div>
                    <span class="group-hover:underline">qwen3:8b-q8_0</span>
                    </span>
                    
                    
                  </div>              
                  
                </div>
              </div>
              <div class="flex flex-col text-neutral-500 text-[13px]">
                <span>
                  <span class="font-mono">
                    e56358ca25dd</span> • 8.9GB • 40K context window  •
                  <span class="hidden sm:inline">
                    Text input • 
                    1 year ago
                  </span>
                </span>
                  <div class="flex sm:hidden">
                    Text input • 
                    1 year ago
                  </div>
                </span>
              </div>
            </a>
            
            </div>
"""#

    static let ollamaTagList = #"""
{"tags":["latest","0.6b","1.7b","4b","8b","0.6b-q4_K_M","0.6b-q8_0","0.6b-fp16","8b-q4_K_M"]}
"""#

    static let ollamaManifest = #"""
{"schemaVersion":2,"mediaType":"application/vnd.docker.distribution.manifest.v2+json","config":{"mediaType":"application/vnd.docker.container.image.v1+json","digest":"sha256:05a61d37b08453e59290add468e3bb2f688e23a01e967fecb0e2fa41218cea76","size":487},"layers":[{"mediaType":"application/vnd.ollama.image.model","digest":"sha256:a3de86cd1c132c822487ededd47a324c50491393e6565cd14bafa40d0b8e686f","size":5225374496},{"mediaType":"application/vnd.ollama.image.template","digest":"sha256:ae370d884f108d16e7cc8fd5259ebc5773a0afa6e078b11f4ed7e39a27e0dfc4","size":1723},{"mediaType":"application/vnd.ollama.image.license","digest":"sha256:d18a5cc71b84bc4af394a31116bd3932b42241de70c77d2b76d69a314ec8aa12","size":11338},{"mediaType":"application/vnd.ollama.image.params","digest":"sha256:cff3f395ef3756ab63e58b0ad1b32bb6f802905cae1472e6a12034e4246fbbdb","size":120}]}
"""#

    static let lmStudioCatalog = #"""
{"publicArtifacts":[{"identifier":"qwen/qwen3-4b","owner":"qwen","name":"qwen3-4b","type":"model","private":false,"description":"The 4B parameter version of the Qwen3 model family.","createdAt":"2025-05-01T03:06:36.996Z","updatedAt":"2025-05-24T20:44:18.713Z","restricted":"none","ownerIsOrganization":true,"forkedFromArtifactIdentifier":null,"forkCount":4,"likeCount":12,"downloadCount":85816,"current":{"fileTreeIdentifier":"BmAhh+q84p3AzSshyDswXjL2","sizeBytes":170891,"sha256Hex":"6a920f8b3375b50910b2ffa850ce8bc24db2b4922441e1f3512cbf38c9c70cef","revisionNumber":8,"downloadCount":85367,"artifactUrl":"https://lmstudio.ai/models/qwen/qwen3-4b","creatorProfile":{"username":"lmmy","profileImageUrl":"https://avatars.lmstudio.com/profile-images/lmmy"}},"staffPickedAt":"2025-04-28T16:56:04.000Z","staffPickedDirectives":"[{\"type\":\"onboarding\",\"message\":\"\"}]","discussionCount":0,"url":"https://lmstudio.ai/models/qwen/qwen3-4b"},{"identifier":"openai/gpt-oss-20b","owner":"openai","name":"gpt-oss-20b","type":"model","private":false,"description":"The 20B variant of OpenAI's open source model. Apache 2.0 licensed.","createdAt":"2025-08-05T17:24:09.426Z","updatedAt":"2025-08-29T21:35:46.925Z","restricted":"none","ownerIsOrganization":true,"forkedFromArtifactIdentifier":null,"forkCount":0,"likeCount":326,"downloadCount":1542474,"current":{"fileTreeIdentifier":"j1t5HEsdBVjHXcKCPvBasU4W","sizeBytes":91716,"sha256Hex":"55b24d2b5b8aae87bb7064347a34b9531c72be6c456afb05942402e0fb12598e","revisionNumber":7,"downloadCount":1205527,"artifactUrl":"https://lmstudio.ai/models/openai/gpt-oss-20b","creatorProfile":{"username":"lmmy","profileImageUrl":"https://avatars.lmstudio.com/profile-images/lmmy"}},"staffPickedAt":"2025-08-05T17:37:42.732Z","staffPickedDirectives":"[]","discussionCount":0,"url":"https://lmstudio.ai/models/openai/gpt-oss-20b"},{"identifier":"buns/qwen38-27b","owner":"buns","name":"qwen38-27b","type":"model","private":false,"description":"State-of-the-art laptop size model capable of reasoning, tools calling, and image understanding","createdAt":"2026-11-03T05:10:10.411Z","updatedAt":"2026-11-03T05:10:10.411Z","restricted":"none","ownerIsOrganization":false,"forkedFromArtifactIdentifier":"qwen/qwen3.8-27b","forkCount":0,"likeCount":0,"downloadCount":0,"current":{"fileTreeIdentifier":"78QOJDBpORz2TyvtI2J04Gt2","sizeBytes":171183,"sha256Hex":"4839b84bf058c32c51f9d12d3207ad890bf4f7308ec76e2de18fcd7adca4db23","revisionNumber":1,"downloadCount":0,"artifactUrl":"https://lmstudio.ai/buns/qwen38-27b","creatorProfile":{"username":"buns"}},"staffPickedAt":null,"staffPickedDirectives":null,"discussionCount":0,"url":"https://lmstudio.ai/buns/qwen38-27b"}]}
"""#

    static let lmStudioModelPage = #"""
}]]}]]}],\"$La1\",\"$La2\",\"$La3\"],\"$La4\"]}]}]\na9:T519,# model.yaml is an open standard for defining cross-platform, composable AI models\n# Learn more at https://modelyaml.org\nmodel: qwen/qwen3-4b\nbase:\n  - key: lmstudio-community/qwen3-4b-gguf\n    sources:\n      - type: huggingface\n        user: lmstudio-community\n        repo: Qwen3-4B-GGUF\n  - key: lmstudio-community/qwen3-4b-mlx-4bit\n    sources:\n      - type: huggingface\n        user: lmstudio-community\n        repo: Qwen3-4B-MLX-4bit\n  - key: lmstudio-community/qwen3-4b-mlx-8bit\n    sources:\n      - type: huggingface\n        user: lmstudio-community\n        repo: Qwen3-4B-MLX-8bit\nmetadataOverrides:\n  domain: llm\n  architectures:\n    - qwen3\n  compatibilityTypes:\n    - gguf\n    - safetensors\n  paramsStrings:\n    - 4B\n  minMemoryUsageBytes: 2200000000\n  contextLengths:\n    - 40960\n  vision: false\n  reasoning: true\n  trainedForToolUse: true\nconfig:\n  operation:\n    fields:\n      - key: llm.prediction.topKSampling\n        value: 20\n      - key: llm.prediction.minPSampling\n        value:\n          checked: true\n          value: 0\ncustomFields:\n  - k"])</script>
"""#

    /// lmstudio.ai/models/google/gemma-3-1b: a colored copy first, then model.yaml escaped twice.
    static let lmStudioModelPageDoubled = #"""
-shiki-dark:#7F848E;--shiki-dark-font-style:italic\"\u003e# model.yaml is an open standard for defining cross-platform, composable AI models\u003c/span\u003e\u003c/span\u003e\n\u003cspan class=\"line\"\u003e\u003cspan style=\"color:#929394;font-style:inherit;--shiki-dark:#7F848E;--shiki-dark-font-style:italic\"\u003e# Learn more at https://modelyaml.org\u003c/span\u003e\u003c/span\u003e\n\u003cspan class=\"line\"\u003e\u003cspan style=\"color:#D32F2F;--shi ... :[[\"$\",\"$L87\",null,{\"content\":\"# model.yaml is an open standard for defining cross-platform, composable AI models\\n# Learn more at https://modelyaml.org\\nmodel: google/gemma-3-1b\\nbase:\\n  - key: lmstudio-community/gemma-3-1B-it-QAT-GGUF\\n    sources:\\n      - type: huggingface\\n        user: lmstudio-community\\n        repo: gemma-3-1B-it-QAT-GGUF\\n  - key: mlx-community/gemma-3-1b-it-qat-4bit\\n    sources:\\n      - type: huggingface\\n        user: mlx-community\\n        repo: gemma-3-1b-it-qat-4bit\\ndescription: gemma 3 1b it by google\\nmetadataOverrides:\\n  domain: llm\\n  architectures:\\n    - gemma3\\n  compatibilityTypes:\\n    - gguf\\n    - safetensors\\n  paramsStrings:\\n    - 1B\\n  minMemoryUsageBytes: 754974720\\n  trainedForToolUse: false\\n  vision: false\\n\",\"className\":\"pointer-eve
"""#

    /// lmstudio.ai/models/qwen/qwen3.6-27b: model.yaml with a chat template that is not plain YAML once cut out.
    static let lmStudioModelPageTemplate = #"""
L89\",\"$L8a\"],\"$L8b\"]}]}]\n91:T3060,# model.yaml is an open standard for defining cross-platform, composable AI models\n# Learn more at https://modelyaml.org\nmodel: qwen/qwen3.6-27b\nbase:\n  - key: lmstudio-community/qwen3.6-27b-gguf\n    sources:\n      - type: huggingface\n        user: lmstudio-community\n        repo: Qwen3.6-27B-GGUF\n  - key: lmstudio-community/qwen3.6-27b-mlx-4bit\n    sources:\n      - type: huggingface\n        user: lmstudio-community\n        repo: Qwen3.6-27B-MLX-4bit\n  - key: lmstudio-community/qwen3.6-27b-mlx-5bit\n    sources:\n      - type: huggingface\n        user: lmstudio-community\n        repo: Qwen3.6-27B-MLX-5bit\n  - key: lmstudio-community/qwen3.6-27b-mlx-6bit\n    sources:\n      - type: huggingface\n        user: lmstudio-community\n        repo: Qwen3.6-27B-MLX-6bit\n  - key: lmstudio-community/qwen3.6-27b-mlx-8bit\n    sources:\n      - type: huggingface\n        user: lmstudio-community\n        repo: Qwen3.6-27B-MLX-8bit\nmetadataOverrides:\n  domain: llm\n  architectures:\n    - qwen35\n  compatibilityTypes:\n    - gguf\n    - safetensors\n  paramsStrings:\n    - 27B\n  minMemoryUsageBytes: 16100000000\n  contextLengths:\n    - 262144\n  vision: true\n  reasoning: true\n  trainedForToolUse: truevideo_count = namespace(value=0) %}\n              {%- macro render_content(content, do_vision_count, is_system_content=false) %}\n                  {%- if content is string %}\n                      {{- content }}\n                  {%- elif content is iterable and content is not mapping %}\n                      {%- for item in content %}\n                          {%- if 'image' in item or 'image_url' in item or item.type == 'image' %}\n                              {%- if is_system_content %\n82:[\"$\",\"div\",
"""#

    static let lmsList = #"""
[{"type":"embedding","modelKey":"text-embedding-nomic-embed-text-v1.5","format":"gguf","displayName":"Nomic Embed Text v1.5","publisher":"nomic-ai","path":"nomic-ai/nomic-embed-text-v1.5-GGUF/nomic-embed-text-v1.5.Q4_K_M.gguf","sizeBytes":84106624,"indexedModelIdentifier":"nomic-ai/nomic-embed-text-v1.5-GGUF/nomic-embed-text-v1.5.Q4_K_M.gguf","deviceIdentifier":null,"architecture":"nomic-bert","quantization":{"name":"Q4_K_M","bits":4},"maxContextLength":2048}]
"""#

    /// `lms get` progress bar frames, as the stream splits them on \r.
    static let lmsGetOutput = [
        "Resolving qwen/qwen3-4b...",
        "\u{1B}[?25l\u{1B}[s\r⠋ [█████▌                ] 24.50% | 612.30 MB / 2.50 GB | 10.20 MB/s | ETA 3m 5s          \u{1B}[u",
        "Finalizing download...",
        "Download completed."
    ]
}
