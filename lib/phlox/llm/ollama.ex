if Code.ensure_loaded?(Req) do
defmodule Phlox.LLM.Ollama do
  @moduledoc """
  LLM provider adapter for Ollama (local models).

  ## Setup

  1. Install Ollama: `curl -fsSL https://ollama.com/install.sh | sh`
  2. Pull a model: `ollama pull llama3.1:8b`
  3. Add `{:req, "~> 0.5"}` to your deps

  No API key needed. No internet needed. $0 per token.

  ## Usage

      Phlox.LLM.Ollama.chat(
        [%{role: "user", content: "Hello"}],
        model: "llama3.1:8b"
      )

  ## Options

  - `:model` — default `"llama3.1:8b"`
  - `:base_url` — default `"http://localhost:11434"`
  - `:temperature` — default `nil`
  - `:max_tokens` — maps to `num_predict`, default `nil` (model default)
  """

  @behaviour Phlox.LLM

  @default_model "llama3.1:8b"
  @default_base_url "http://localhost:11434"

  @impl Phlox.LLM
  def chat(messages, opts \\ []) do
    base_url = Keyword.get(opts, :base_url, @default_base_url)
    model = Keyword.get(opts, :model, @default_model)
    temperature = Keyword.get(opts, :temperature)
    max_tokens = Keyword.get(opts, :max_tokens)

    # Ollama uses OpenAI-compatible /api/chat
    body = %{
      model: model,
      messages: Enum.map(messages, &normalize_message/1),
      stream: false
    }

    options = %{}
    options = if temperature, do: Map.put(options, :temperature, temperature), else: options
    options = if max_tokens, do: Map.put(options, :num_predict, max_tokens), else: options
    body = if map_size(options) > 0, do: Map.put(body, :options, options), else: body

    url = "#{base_url}/api/chat"

    case Req.post(url, json: body, receive_timeout: 300_000) do
      {:ok, %{status: 200, body: resp}} ->
        text = get_in(resp, ["message", "content"])
        if text, do: {:ok, text}, else: {:error, {:no_content, resp}}

      {:ok, %{status: status, body: resp}} ->
        {:error, {:http_error, status, resp}}

      {:error, reason} ->
        {:error, {:request_failed, reason}}
    end
  end

  defp normalize_message(m) do
    %{
      "role" => to_string(m[:role] || m["role"]),
      "content" => m[:content] || m["content"]
    }
  end
end
end
