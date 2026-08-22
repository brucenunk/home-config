{
  bedrockBaseUrl,
  openAIBaseUrl,
}:

{
  providers = {
    openai-proxy = {
      api = "openai-responses";
      apiKey = "dummy-key-not-required";
      baseUrl = openAIBaseUrl;
      compat.sessionAffinityFormat = "openai-nosession";
      models = [
        {
          contextWindow = 1050000;
          cost = {
            cacheRead = 0;
            cacheWrite = 0;
            input = 0;
            output = 0;
          };
          id = "gpt-5.6-sol";
          input = [
            "text"
            "image"
          ];
          maxTokens = 128000;
          name = "GPT-5.6 Sol (OpenAI Proxy)";
          reasoning = true;
          thinkingLevelMap = {
            off = "none";
            minimal = null;
            xhigh = "xhigh";
            max = "max";
          };
        }
        {
          contextWindow = 1050000;
          cost = {
            cacheRead = 0;
            cacheWrite = 0;
            input = 0;
            output = 0;
          };
          id = "gpt-5.6-terra";
          input = [
            "text"
            "image"
          ];
          maxTokens = 128000;
          name = "GPT-5.6 Terra (OpenAI Proxy)";
          reasoning = true;
          thinkingLevelMap = {
            off = "none";
            minimal = null;
            xhigh = "xhigh";
            max = "max";
          };
        }
        {
          contextWindow = 1050000;
          cost = {
            cacheRead = 0;
            cacheWrite = 0;
            input = 0;
            output = 0;
          };
          id = "gpt-5.6-luna";
          input = [
            "text"
            "image"
          ];
          maxTokens = 128000;
          name = "GPT-5.6 Luna (OpenAI Proxy)";
          reasoning = true;
          thinkingLevelMap = {
            off = "none";
            minimal = null;
            xhigh = "xhigh";
            max = "max";
          };
        }
      ];
    };
    bedrock-proxy = {
      api = "bedrock-converse-stream";
      apiKey = "dummy-key-not-required";
      baseUrl = bedrockBaseUrl;
      models = [
        {
          contextWindow = 500000;
          cost = {
            cacheRead = 0;
            cacheWrite = 0;
            input = 0;
            output = 0;
          };
          id = "global.xai.grok-4.6";
          input = [ "text" ];
          maxTokens = 500000;
          name = "Grok 4.6 (Bedrock Proxy)";
          # Pi's Bedrock transport currently sends reasoning fields only for
          # Claude models.
          reasoning = false;
        }
        {
          contextWindow = 1000000;
          cost = {
            cacheRead = 0;
            cacheWrite = 0;
            input = 0;
            output = 0;
          };
          id = "global.anthropic.claude-fable-5";
          input = [ "text" ];
          maxTokens = 128000;
          name = "Claude Fable 5 (Bedrock Proxy)";
          reasoning = true;
          thinkingLevelMap = {
            off = null;
            xhigh = "xhigh";
            max = "max";
          };
        }
        {
          contextWindow = 1000000;
          cost = {
            cacheRead = 0;
            cacheWrite = 0;
            input = 0;
            output = 0;
          };
          id = "global.anthropic.claude-opus-5";
          input = [ "text" ];
          maxTokens = 128000;
          name = "Claude Opus 5 (Bedrock Proxy)";
          reasoning = true;
          thinkingLevelMap = {
            xhigh = "xhigh";
            max = "max";
          };
        }
        {
          contextWindow = 1000000;
          cost = {
            cacheRead = 0;
            cacheWrite = 0;
            input = 0;
            output = 0;
          };
          id = "global.anthropic.claude-sonnet-5";
          input = [ "text" ];
          maxTokens = 128000;
          name = "Claude Sonnet 5 (Bedrock Proxy)";
          reasoning = true;
          thinkingLevelMap = {
            xhigh = "xhigh";
            max = "max";
          };
        }
      ];
    };
  };
}
