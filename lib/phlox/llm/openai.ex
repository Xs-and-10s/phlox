if Code.ensure_loaded?(Req) do
defmodule Phlox.LLM.OpenAI do
  @moduledoc """
  LLM provider adapter for OpenAI's Chat Completions API.

  ## Setup

  1. Get an API key at platform.openai.com
  2. Set `OPENAI_API_KEY` in your environment
  3. Add `{:req, "~> 0.5"}` to your deps

  ## Usage

      Phlox.LLM.OpenAI.chat(
        [%{role: "user", content: "Hello"}],
        model: "gpt-4o"
      )

  ## Options

  - `:model` — default `"gpt-4o"`
  - `:max_tokens` — default `4096`
  - `:temperature` — default `nil` (API default)
  - `:api_key` — default from `OPENAI_API_KEY` env var
  - `:base_url` — default `"https://api.openai.com/v1/chat/completions"`.
    Override to use Azure OpenAI, OpenRouter, or any OpenAI-compatible endpoint.
  """

  @behaviour Phlox.LLM

  @default_model "gpt-4o"
  @default_max_tokens 4096
  @default_url "https://api.openai.com/v1/chat/completions"

  @impl Phlox.LLM
  def chat(messages, opts \\ []) do
    api_key = Keyword.get(opts, :api_key) || System.get_env("OPENAI_API_KEY")

    unless api_key do
      raise ArgumentError,
            "Phlox.LLM.OpenAI requires an API key. Set OPENAI_API_KEY or pass api_key: in opts."
    end

    model = Keyword.get(opts, :model, @default_model)
    max_tokens = Keyword.get(opts, :max_tokens, @default_max_tokens)
    temperature = Keyword.get(opts, :temperature)
    url = Keyword.get(opts, :base_url, @default_url)

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

    case Req.post(url, json: body, headers: headers, receive_timeout: 120_000) do
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
