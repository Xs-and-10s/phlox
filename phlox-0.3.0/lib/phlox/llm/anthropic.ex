if Code.ensure_loaded?(Req) do
defmodule Phlox.LLM.Anthropic do
  @moduledoc """
  LLM provider adapter for Anthropic's Claude API.

  ## Setup

  1. Get an API key at console.anthropic.com
  2. Set `ANTHROPIC_API_KEY` in your environment
  3. Add `{:req, "~> 0.5"}` to your deps

  ## Usage

      Phlox.LLM.Anthropic.chat(
        [%{role: "user", content: "Hello"}],
        model: "claude-sonnet-4-20250514",
        max_tokens: 1024
      )

  ## Options

  - `:model` — default `"claude-sonnet-4-20250514"`
  - `:max_tokens` — default `4096`
  - `:temperature` — default `nil` (API default)
  - `:api_key` — default from `ANTHROPIC_API_KEY` env var
  """

  @behaviour Phlox.LLM

  @default_model "claude-sonnet-4-20250514"
  @default_max_tokens 4096
  @api_url "https://api.anthropic.com/v1/messages"

  @impl Phlox.LLM
  def chat(messages, opts \\ []) do
    api_key = Keyword.get(opts, :api_key) || System.get_env("ANTHROPIC_API_KEY")

    unless api_key do
      raise ArgumentError,
            "Phlox.LLM.Anthropic requires an API key. Set ANTHROPIC_API_KEY or pass api_key: in opts."
    end

    model = Keyword.get(opts, :model, @default_model)
    max_tokens = Keyword.get(opts, :max_tokens, @default_max_tokens)
    temperature = Keyword.get(opts, :temperature)

    # Extract system message (Anthropic uses a separate field)
    {system, messages} = extract_system(messages)

    body = %{
      model: model,
      max_tokens: max_tokens,
      messages: Enum.map(messages, &normalize_message/1)
    }

    body = if system, do: Map.put(body, :system, system), else: body
    body = if temperature, do: Map.put(body, :temperature, temperature), else: body

    headers = [
      {"x-api-key", api_key},
      {"anthropic-version", "2023-06-01"},
      {"content-type", "application/json"}
    ]

    case Req.post(@api_url, json: body, headers: headers, receive_timeout: 120_000) do
      {:ok, %{status: 200, body: resp}} ->
        text =
          resp
          |> Map.get("content", [])
          |> Enum.find_value(fn
            %{"type" => "text", "text" => t} -> t
            _ -> nil
          end)

        if text, do: {:ok, text}, else: {:error, {:no_text_content, resp}}

      {:ok, %{status: status, body: resp}} ->
        {:error, {:http_error, status, resp}}

      {:error, reason} ->
        {:error, {:request_failed, reason}}
    end
  end

  defp extract_system(messages) do
    case Enum.split_with(messages, fn m -> m[:role] == "system" || m.role == "system" end) do
      {[], rest} -> {nil, rest}
      {sys, rest} -> {Enum.map_join(sys, "\n\n", &get_content/1), rest}
    end
  end

  defp get_content(%{content: c}), do: c
  defp get_content(%{"content" => c}), do: c

  defp normalize_message(m) do
    %{
      "role" => to_string(m[:role] || m["role"]),
      "content" => m[:content] || m["content"]
    }
  end
end
end
