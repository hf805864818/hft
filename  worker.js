export default {
  async fetch(request, env) {
    const url = new URL(request.url);

    // 跨域 OPTIONS 预检
    if (request.method === "OPTIONS") {
      return new Response(null, {
        headers: {
          "Access-Control-Allow-Origin": "*",
          "Access-Control-Allow-Methods": "POST, GET, OPTIONS",
          "Access-Control-Allow-Headers": "Content-Type, Authorization"
        }
      });
    }

    // 模型映射表
    const modelMap = {
      "llama3-8b": "@cf/meta/llama-3-8b-instruct",
      "llama3-70b": "@cf/meta/llama-3-70b-instruct",
      "mistral-7b": "@cf/mistral/mistral-7b-instruct-v0.1",
      "qwen-7b": "@cf/qwen/qwen1.5-7b-chat-awq",
      "gemma-7b": "@cf/google/gemma-7b-it",
      "phi-2": "@cf/microsoft/phi-2"
    };

    // 获取模型列表接口 /v1/models
    if (url.pathname === "/v1/models") {
      const modelList = Object.keys(modelMap).map(id => ({
        id,
        object: "model",
        created: Math.floor(Date.now() / 1000),
        owned_by: "cloudflare"
      }));
      return new Response(JSON.stringify({
        object: "list",
        data: modelList
      }), {
        headers: {
          "Content-Type": "application/json",
          "Access-Control-Allow-Origin": "*"
        }
      });
    }

    // 仅允许对话接口 POST 请求
    if (url.pathname !== "/v1/chat/completions" || request.method !== "POST") {
      return new Response(JSON.stringify({
        error: { message: "Not Found" }
      }), { status: 404, headers: { "Content-Type": "application/json" } });
    }

    // 密钥鉴权：读取环境变量 API_KEY
    const authHeader = request.headers.get("Authorization");
    const token = authHeader?.replace("Bearer ", "");
    const validKey = env.API_KEY;

    if (!token || token !== validKey) {
      return new Response(JSON.stringify({
        error: { message: "Invalid API key" }
      }), { status: 401, headers: { "Content-Type": "application/json" } });
    }

    try {
      const body = await request.json();
      const { model, messages } = body;

      if (!modelMap[model]) {
        return new Response(JSON.stringify({
          error: { message: `Model \`${model}\` is not available` }
        }), { status: 400, headers: { "Content-Type": "application/json" } });
      }

      const aiRes = await env.AI.run(modelMap[model], { messages });

      const result = {
        id: `chatcmpl-${Date.now()}`,
        object: "chat.completion",
        created: Math.floor(Date.now() / 1000),
        model: model,
        choices: [
          {
            index: 0,
            message: {
              role: "assistant",
              content: aiRes.response
            },
            finish_reason: "stop"
          }
        ],
        usage: aiRes.usage || {
          prompt_tokens: 0,
          completion_tokens: 0,
          total_tokens: 0
        }
      };

      return new Response(JSON.stringify(result), {
        headers: {
          "Content-Type": "application/json",
          "Access-Control-Allow-Origin": "*"
        }
      });
    } catch (err) {
      return new Response(JSON.stringify({
        error: { message: "Server internal error" }
      }), { status: 500, headers: { "Content-Type": "application/json" } });
    }
  }
};