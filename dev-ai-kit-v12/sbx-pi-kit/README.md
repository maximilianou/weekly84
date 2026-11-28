sbx run --name weekly85  --env-file ./.env  -e OLLAMA_HOST=http://192.168.122.1:11434  -e OPENAI_BASE_URL=http://192.168.122.1:11434/v1  -e OPENAI_API_KEY=ollama  -e OLLAMA_MODEL=inkling-2-mini  docker.io/sbx/pi-kit:latest  ./weekly85


sbx run --name weekly85


