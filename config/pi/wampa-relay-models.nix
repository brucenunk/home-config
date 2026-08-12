{ baseUrl }:

let
  zeroCost = {
    cacheRead = 0;
    cacheWrite = 0;
    input = 0;
    output = 0;
  };

  model = id: name: {
    contextWindow = 1050000;
    cost = zeroCost;
    inherit id;
    input = [
      "text"
      "image"
    ];
    maxTokens = 128000;
    inherit name;
    reasoning = true;
    thinkingLevelMap = {
      off = "none";
      minimal = null;
      xhigh = "xhigh";
      max = "max";
    };
  };
in
{
  providers.openai-proxy = {
    api = "openai-responses";
    apiKey = "dummy-key-not-required";
    inherit baseUrl;
    compat.sessionAffinityFormat = "openai-nosession";
    models = [
      (model "gpt-5.6-sol" "GPT-5.6 Sol (OpenAI Proxy)")
      (model "gpt-5.6-terra" "GPT-5.6 Terra (OpenAI Proxy)")
      (model "gpt-5.6-luna" "GPT-5.6 Luna (OpenAI Proxy)")
    ];
  };
}
