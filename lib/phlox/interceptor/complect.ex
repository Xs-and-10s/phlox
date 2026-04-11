defmodule Phlox.Interceptor.Complect do
  @moduledoc """
  Per-node override for `Phlox.Middleware.Simplect`.

  While Simplect applies token compression across an entire pipeline,
  Complect lets individual nodes dial the intensity up, down, or off.
  Declared directly on the node module.

  ## Why "Complect"?

  Rich Hickey coined "complect" to mean braiding things together — adding
  complexity. In this context, Complect *re-complects* the LLM output for
  nodes that need full verbosity (summaries, user-facing prose, safety-
  critical explanations).

  ## Usage

      defmodule MyApp.Nodes.QuickClassifier do
        use Phlox.Node

        # Maximum compression — we only need a label back
        intercept Phlox.Interceptor.Complect, level: :ultra

        def prep(shared, _params) do
          [
            %{role: "system", content: shared.system_prompt},
            %{role: "user", content: "Classify: \#{shared.text}"}
          ]
        end

        def exec(messages, params), do: Phlox.LLM.Groq.chat(messages, params)
        def post(shared, _prep, {:ok, label}, _params), do: {:default, Map.put(shared, :label, label)}
      end

      defmodule MyApp.Nodes.UserSummary do
        use Phlox.Node

        # This node's output goes directly to the user — need full prose
        intercept Phlox.Interceptor.Complect, level: :off

        def prep(shared, _params) do
          [
            %{role: "system", content: shared.system_prompt},
            %{role: "user", content: "Summarize: \#{shared.analysis}"}
          ]
        end

        def exec(messages, params), do: Phlox.LLM.Anthropic.chat(messages, params)
        def post(shared, _prep, {:ok, text}, _params), do: {:default, Map.put(shared, :summary, text)}
      end

  ## How it works

  `before_exec/2` inspects `prep_res`. If it's a list of message maps
  (the standard LLM message format), Complect finds the system message
  and either:

  - **`:off`** — strips the simplect-marked portion, leaving any
    user-authored system prompt intact
  - **`:lite` / `:full` / `:ultra`** — replaces the simplect-marked
    portion with the specified level's prompt

  If `prep_res` is not a message list (the node doesn't do LLM calls),
  Complect passes through unchanged.

  ## Options

  - `level:` — (**required**) `:off`, `:lite`, `:full`, or `:ultra`
  """

  @behaviour Phlox.Interceptor

  alias Phlox.Simplect

  @valid_levels [:off, :lite, :full, :ultra]

  @impl true
  def before_exec(prep_res, ctx) do
    level = Keyword.fetch!(ctx.interceptor_opts, :level)

    unless level in @valid_levels do
      raise ArgumentError,
            "Phlox.Interceptor.Complect: unknown level #{inspect(level)}. " <>
              "Expected :off, :lite, :full, or :ultra."
    end

    case prep_res do
      messages when is_list(messages) ->
        if message_list?(messages) do
          {:cont, adjust_messages(messages, level)}
        else
          {:cont, prep_res}
        end

      _ ->
        {:cont, prep_res}
    end
  end

  # ---------------------------------------------------------------------------
  # Private
  # ---------------------------------------------------------------------------

  defp message_list?([%{role: _} | _]), do: true
  defp message_list?([%{"role" => _} | _]), do: true
  defp message_list?(_), do: false

  defp adjust_messages(messages, :off) do
    Enum.map(messages, fn msg ->
      if system?(msg) do
        content = msg[:content] || msg["content"]

        case Simplect.strip(content) do
          "" -> nil
          stripped -> %{msg | content: stripped}
        end
      else
        msg
      end
    end)
    |> Enum.reject(&is_nil/1)
  end

  defp adjust_messages(messages, level) do
    Enum.map(messages, fn msg ->
      if system?(msg) do
        content = msg[:content] || msg["content"]
        %{msg | content: Simplect.replace(content, level)}
      else
        msg
      end
    end)
  end

  defp system?(m) do
    role = to_string(m[:role] || m["role"])
    role == "system"
  end
end
