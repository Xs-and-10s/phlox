if Code.ensure_loaded?(Req) do
defmodule Phlox.LLM.Google do
  @moduledoc """
  LLM provider adapter for Google's Gemini API via AI Studio.

  ## Setup

  1. Get an API key at aistudio.google.com (free, no credit card)
  2. Set `GOOGLE_AI_KEY` in your environment
  3. Add `{:req, "~> 0.5"}` to your deps

  ## Usage

      Phlox.LLM.Google.chat(
        [%{role: "user", content: "Hello"}],
        model: "gemini-2.5-flash"
      )

  ## Free tier

  - 1,500 requests/day
  - 1M token context window
  - No credit card required

  ## Options

  - `:model` — default `"gemini-2.5-flash"`
  - `:max_tokens` — default `4096` (maps to `maxOutputTokens`)
  - `:temperature` — default `nil` (API default)
  - `:api_key` — default from `GOOGLE_AI_KEY` env var
  """

  @behaviour Phlox.LLM

  @default_model "gemini-2.5-flash"
  @default_max_tokens 4096
  @api_base "https://generativelanguage.googleapis.com/v1beta/models"

  @impl Phlox.LLM
  def chat(messages, opts \\ []) do
    api_key = Keyword.get(opts, :api_key) || System.get_env("GOOGLE_AI_KEY")

    unless api_key do
      raise ArgumentError,
            "Phlox.LLM.Google requires an API key. Set GOOGLE_AI_KEY or pass api_key: in opts."
    end

    model = Keyword.get(opts, :model, @default_model)
    max_tokens = Keyword.get(opts, :max_tokens, @default_max_tokens)
    temperature = Keyword.get(opts, :temperature)

    # Extract system message
    {system, messages} = extract_system(messages)

    # Build Gemini request format
    contents = Enum.map(messages, &to_gemini_content/1)

    body = %{contents: contents}

    body =
      if system do
        Map.put(body, :systemInstruction, %{parts: [%{text: system}]})
      else
        body
      end

    gen_config = %{maxOutputTokens: max_tokens}
    gen_config = if temperature, do: Map.put(gen_config, :temperature, temperature), else: gen_config
    body = Map.put(body, :generationConfig, gen_config)

    url = "#{@api_base}/#{model}:generateContent"

    case Req.post(url, json: body, params: [key: api_key], receive_timeout: 120_000) do
      {:ok, %{status: 200, body: resp}} ->
        text =
          resp
          |> get_in(["candidates", Access.at(0), "content", "parts", Access.at(0), "text"])

        if text, do: {:ok, text}, else: {:error, {:no_text_content, resp}}

      {:ok, %{status: status, body: resp}} ->
        {:error, {:http_error, status, resp}}

      {:error, reason} ->
        {:error, {:request_failed, reason}}
    end
  end

  defp extract_system(messages) do
    case Enum.split_with(messages, fn m -> to_string(m[:role] || m["role"]) == "system" end) do
      {[], rest} -> {nil, rest}
      {sys, rest} -> {Enum.map_join(sys, "\n\n", &get_content/1), rest}
    end
  end

  defp to_gemini_content(m) do
    role =
      case to_string(m[:role] || m["role"]) do
        "assistant" -> "model"
        other -> other
      end

    %{role: role, parts: [%{text: get_content(m)}]}
  end

  defp get_content(%{content: c}), do: c
  defp get_content(%{"content" => c}), do: c
end
end
