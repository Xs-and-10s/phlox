defmodule Phlox.LLM do
  @moduledoc """
  Behaviour for LLM provider adapters.

  Phlox doesn't ship with an LLM client — it's an orchestration engine
  that doesn't care what `exec/2` does. But most Phlox users are
  building AI agent pipelines, so this behaviour provides a standard
  interface for swappable LLM providers.

  ## Implementing a provider

      defmodule MyApp.LLM.Anthropic do
        @behaviour Phlox.LLM

        @impl true
        def chat(messages, opts) do
          # Call api.anthropic.com/v1/messages
          # Return {:ok, "response text"} or {:error, reason}
        end
      end

  ## Using in a Phlox node

      defmodule MyApp.ThinkNode do
        use Phlox.Node

        def prep(shared, _params), do: shared.prompt

        def exec(prompt, params) do
          provider = Map.fetch!(params, :llm)
          opts = Map.get(params, :llm_opts, [])

          messages = [%{role: "user", content: prompt}]

          case provider.chat(messages, opts) do
            {:ok, text} -> text
            {:error, reason} -> raise "LLM call failed: \#{inspect(reason)}"
          end
        end

        def post(shared, _prep, response, _params) do
          {:default, Map.put(shared, :response, response)}
        end
      end

  ## Swapping providers

  The provider is injected via node `params`, so swapping is one line:

      # Development — free, 1500 req/day
      Graph.add_node(:think, ThinkNode, %{
        llm: Phlox.LLM.Google,
        llm_opts: [model: "gemini-2.5-flash"]
      })

      # Production — paid, higher quality
      Graph.add_node(:think, ThinkNode, %{
        llm: Phlox.LLM.Anthropic,
        llm_opts: [model: "claude-sonnet-4-20250514"]
      })

  ## Message format

  Messages follow the OpenAI/Anthropic convention:

      [
        %{role: "system", content: "You are a security expert."},
        %{role: "user", content: "Review this code for vulnerabilities."},
        %{role: "assistant", content: "I'll analyze the code..."},
        %{role: "user", content: "Focus on SQL injection."}
      ]

  Provider adapters handle the translation — e.g., Anthropic extracts
  the system message into a separate field, Google restructures into
  its `contents` format.
  """

  @typedoc "A chat message with role and content."
  @type message :: %{role: String.t(), content: String.t()}

  @typedoc "Options passed to the provider. Common keys: :model, :max_tokens, :temperature"
  @type opts :: keyword()

  @doc """
  Send a chat completion request.

  Returns `{:ok, response_text}` on success or `{:error, reason}` on failure.
  The response is always a plain string — structured output parsing is
  the caller's responsibility.
  """
  @callback chat(messages :: [message()], opts :: opts()) ::
              {:ok, String.t()} | {:error, term()}

  @doc """
  Convenience: call `chat/2` and raise on error.
  """
  @spec chat!(module(), [message()], opts()) :: String.t()
  def chat!(provider, messages, opts \\ []) do
    case provider.chat(messages, opts) do
      {:ok, text} -> text
      {:error, reason} -> raise "Phlox.LLM: #{inspect(provider)} failed: #{inspect(reason)}"
    end
  end
end
