{
  "$schema": "https://pi.dev/schemas/models.schema.json",
  "providers": {
    "ollama": {
      "baseUrl": "__BASE_URL__/v1",
      "api": "openai-completions",
      "apiKey": "ollama",
      "models": [__MODELS__]
    }
  }
}
