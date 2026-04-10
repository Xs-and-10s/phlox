if Code.ensure_loaded?(Req) do
defmodule Phlox.LLM.Groq do
  @moduledoc """
  LLM provider adapter for Groq's inference API.

  ## Setup

  1. Get an API key at console.groq.com (free tier: 14,400 req/day)
  2. Set `GROQ_API_KEY` in your environment
  3. Add `{:req, "~> 0.5"}` to your deps

  ## Why Groq

  300+ tokens/second inference on Llama 3.3 70B. The fastest
  free LLM API available — great for rapid iteration.

  ## Usage

      Phlox.LLM.Groq.chat(
        [%{role: "user", content: "Hello"}],
        model: "llama-3.3-70b-versatile"
      )

  ## Options

  - `:model` — default `"llama-3.3-70b-versatile"`
  - `:max_tokens` — default `4096`
  - `:temperature` — default `nil`
  - `:api_key` — default from `GROQ_API_KEY` env var
  """

  @behaviour Phlox.LLM

  @default_model "llama-3.3-70b-versatile"
  @default_max_tokens 4096
  @api_url "https://api.groq.com/openai/v1/chat/completions"

  @impl Phlox.LLM
  def chat(messages, opts \\ []) do
    api_key = Keyword.get(opts, :api_key) || System.get_env("GROQ_API_KEY")

    unless api_key do
      raise ArgumentError,
            "Phlox.LLM.Groq requires an API key. Set GROQ_API_KEY or pass api_key: in opts."
    end

    model = Keyword.get(opts, :model, @default_model)
    max_tokens = Keyword.get(opts, :max_tokens, @default_max_tokens)
    temperature = Keyword.get(opts, :temperature)

    body = %{
      model: model,
      max_tokens: max_tokens,
      messages: Enum.map(messages, &normalize_message/1)
    }

    body = if temperature, do: Map.put(body, :temperature, temperature), else: body

    headers = [
      {"authorization", "Bearer #{api_key}"},
      {"content-type", "application/json"}
    ]

    case Req.post(@api_url, json: body, headers: headers, receive_timeout: 60_000) do
      {:ok, %{status: 200, body: resp}} ->
        text = get_in(resp, ["choices", Access.at(0), "message", "content"])
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
