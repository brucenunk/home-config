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
          id = "gpt-6.2-astra";
          input = [
            "text"
            "image"
          ];
          maxTokens = 128000;
          name = "GPT-6.2 Astra";
          reasoning = true;
          thinkingLevelMap = {
            off = null;
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
          id = "gpt-6.2-sol";
          input = [
            "text"
            "image"
          ];
          maxTokens = 128000;
          name = "GPT-6.2 Sol";
          reasoning = true;
          thinkingLevelMap = {
            off = null;
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
          id = "gpt-6-luna";
          input = [
            "text"
            "image"
          ];
          maxTokens = 128000;
          name = "GPT-6 Luna";
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
          id = "gpt-6.1-terra";
          input = [
            "text"
            "image"
          ];
          maxTokens = 128000;
          name = "GPT-6.1 Terra";
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
          contextWindow = 524288;
          cost = {
            cacheRead = 0;
            cacheWrite = 0;
            input = 0;
            output = 0;
          };
          id = "global.xai.grok-4.7";
          input = [
            "text"
            "image"
          ];
          maxTokens = 524288;
          name = "Grok 4.7";
          # Pi's Bedrock transport does not forward Grok reasoning effort.
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
          id = "global.anthropic.claude-fable-5-2";
          input = [
            "text"
            "image"
          ];
          maxTokens = 128000;
          name = "Claude Fable 5.2";
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
          id = "global.anthropic.claude-opus-5-5";
          input = [
            "text"
            "image"
          ];
          maxTokens = 128000;
          name = "Claude Opus 5.5";
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
          id = "global.anthropic.claude-sonnet-5-5";
          input = [
            "text"
            "image"
          ];
          maxTokens = 128000;
          name = "Claude Sonnet 5.5";
          reasoning = true;
          thinkingLevelMap = {
            off = null;
            xhigh = "xhigh";
            max = "max";
          };
        }
      ];
    };
  };
}
