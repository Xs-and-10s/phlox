defmodule Phlox.Examples.CodeReview do
  @moduledoc """
  A multi-agent code review pipeline built on Phlox.

  Three specialist agents analyze code from different angles, then a
  synthesizer combines their findings into a unified review. This is
  the "brain trust" pattern from the PXML spec.

  ## Architecture

      ┌─────────────────┐
      │  SecurityReview  │──┐
      └─────────────────┘  │
      ┌─────────────────┐  │   ┌─────────────┐
      │   LogicReview    │──┼──▶│  Synthesize  │
      └─────────────────┘  │   └─────────────┘
      ┌─────────────────┐  │
      │   StyleReview    │──┘
      └─────────────────┘

  (Sequential in this version — each specialist feeds into the next.
  The synthesizer sees all three reviews. Fan-out/parallel is a natural
  next step using BatchNode.)

  ## Usage

      # With Google AI Studio (free)
      Phlox.Examples.CodeReview.run(code_string,
        llm: Phlox.LLM.Google,
        llm_opts: [model: "gemini-2.5-flash"]
      )

      # With Anthropic ($5 free credits)
      Phlox.Examples.CodeReview.run(code_string,
        llm: Phlox.LLM.Anthropic,
        llm_opts: [model: "claude-sonnet-4-20250514"]
      )

      # With local Ollama (free, no internet)
      Phlox.Examples.CodeReview.run(code_string,
        llm: Phlox.LLM.Ollama,
        llm_opts: [model: "llama3.1:8b"]
      )

  ## Features demonstrated

  - Multi-agent pipeline (4 nodes, 3 specialists + synthesizer)
  - Provider-agnostic LLM calls (swap with one option)
  - Typed shared state via Phlox.Typed
  - Checkpoint middleware (resume if interrupted)
  - Real system/user prompt separation per agent
  """

  alias Phlox.{Graph, Pipeline}

  # ===========================================================================
  # Nodes
  # ===========================================================================

  defmodule SecurityReviewNode do
    use Phlox.Node
    use Phlox.Typed

    input fn shared ->
      if is_binary(Map.get(shared, :code)) and byte_size(shared.code) > 0,
        do: :ok,
        else: {:error, ":code must be a non-empty string"}
    end

    def prep(shared, _params) do
      %{code: shared.code, language: Map.get(shared, :language, "unknown")}
    end

    def exec(%{code: code, language: lang}, params) do
      provider = Map.fetch!(params, :llm)
      opts = Map.get(params, :llm_opts, [])

      messages = [
        %{role: "system", content: """
        You are a senior application security engineer with deep expertise
        in OWASP Top 10 vulnerabilities. You review code for:
        - Injection vulnerabilities (SQL, XSS, command injection)
        - Authentication and authorization flaws
        - Sensitive data exposure (hardcoded secrets, logging PII)
        - Insecure deserialization
        - Known vulnerable patterns in #{lang}

        Be specific. Cite line numbers. Rate each finding as CRITICAL,
        HIGH, MEDIUM, or LOW. If the code is clean, say so — don't
        invent issues.
        """},
        %{role: "user", content: """
        Review this #{lang} code for security vulnerabilities:

        ```#{lang}
        #{code}
        ```
        """}
      ]

      Phlox.LLM.chat!(provider, messages, opts)
    end

    def post(shared, _prep, review, _params) do
      {:default, Map.put(shared, :security_review, review)}
    end
  end

  defmodule LogicReviewNode do
    use Phlox.Node

    def prep(shared, _params) do
      %{code: shared.code, language: Map.get(shared, :language, "unknown")}
    end

    def exec(%{code: code, language: lang}, params) do
      provider = Map.fetch!(params, :llm)
      opts = Map.get(params, :llm_opts, [])

      messages = [
        %{role: "system", content: """
        You are a senior software engineer who specializes in logic
        correctness and algorithmic review. You look for:
        - Off-by-one errors and boundary conditions
        - Race conditions and concurrency issues
        - Null/nil handling gaps
        - Unreachable code or dead branches
        - Missing error handling
        - Algorithmic complexity concerns

        Be specific. Cite line numbers. Focus on correctness, not style.
        """},
        %{role: "user", content: """
        Review this #{lang} code for logic and correctness issues:

        ```#{lang}
        #{code}
        ```
        """}
      ]

      Phlox.LLM.chat!(provider, messages, opts)
    end

    def post(shared, _prep, review, _params) do
      {:default, Map.put(shared, :logic_review, review)}
    end
  end

  defmodule StyleReviewNode do
    use Phlox.Node

    def prep(shared, _params) do
      %{code: shared.code, language: Map.get(shared, :language, "unknown")}
    end

    def exec(%{code: code, language: lang}, params) do
      provider = Map.fetch!(params, :llm)
      opts = Map.get(params, :llm_opts, [])

      messages = [
        %{role: "system", content: """
        You are a senior developer who cares deeply about code quality,
        readability, and maintainability. You review for:
        - Naming clarity (variables, functions, modules)
        - Function length and complexity
        - Idiomatic patterns for #{lang}
        - Documentation gaps
        - DRY violations and unnecessary abstraction
        - Test coverage concerns

        Be constructive. Suggest specific improvements. Don't nitpick
        formatting — focus on things that affect maintainability.
        """},
        %{role: "user", content: """
        Review this #{lang} code for style and maintainability:

        ```#{lang}
        #{code}
        ```
        """}
      ]

      Phlox.LLM.chat!(provider, messages, opts)
    end

    def post(shared, _prep, review, _params) do
      {:default, Map.put(shared, :style_review, review)}
    end
  end

  defmodule SynthesizeNode do
    use Phlox.Node
    use Phlox.Typed

    output fn shared ->
      if is_binary(Map.get(shared, :final_review)),
        do: :ok,
        else: {:error, ":final_review must be present"}
    end

    def prep(shared, _params) do
      %{
        security: shared.security_review,
        logic: shared.logic_review,
        style: shared.style_review,
        code: shared.code,
        language: Map.get(shared, :language, "unknown")
      }
    end

    def exec(%{security: sec, logic: logic, style: style, code: code, language: lang}, params) do
      provider = Map.fetch!(params, :llm)
      opts = Map.get(params, :llm_opts, [])

      messages = [
        %{role: "system", content: """
        You are a tech lead synthesizing reviews from three specialists.
        Your job is to:
        1. Deduplicate findings across reviews
        2. Rank all issues by severity (CRITICAL → LOW)
        3. Group related issues together
        4. Add a brief summary at the top
        5. End with 2-3 actionable next steps

        Keep the tone constructive — this ships to a human developer.
        """},
        %{role: "user", content: """
        Synthesize these three reviews of #{lang} code into one unified
        review. Deduplicate, rank by severity, and be constructive.

        ## Security Review
        #{sec}

        ## Logic Review
        #{logic}

        ## Style Review
        #{style}

        ## Original Code
        ```#{lang}
        #{code}
        ```
        """}
      ]

      Phlox.LLM.chat!(provider, messages, opts)
    end

    def post(shared, _prep, synthesis, _params) do
      {:default, Map.put(shared, :final_review, synthesis)}
    end
  end

  # ===========================================================================
  # Flow builder
  # ===========================================================================

  @doc """
  Build the code review flow.

  ## Options

  - `:llm` — provider module (e.g., `Phlox.LLM.Google`)
  - `:llm_opts` — keyword list passed to the provider (e.g., `[model: "gemini-2.5-flash"]`)
  """
  def flow(opts \\ []) do
    llm = Keyword.get(opts, :llm, Phlox.LLM.Google)
    llm_opts = Keyword.get(opts, :llm_opts, [])

    params = %{llm: llm, llm_opts: llm_opts}

    Graph.new()
    |> Graph.add_node(:security, SecurityReviewNode, params)
    |> Graph.add_node(:logic, LogicReviewNode, params)
    |> Graph.add_node(:style, StyleReviewNode, params)
    |> Graph.add_node(:synthesize, SynthesizeNode, params)
    |> Graph.connect(:security, :logic)
    |> Graph.connect(:logic, :style)
    |> Graph.connect(:style, :synthesize)
    |> Graph.start_at(:security)
    |> Graph.to_flow!()
  end

  # ===========================================================================
  # Runner
  # ===========================================================================

  @doc """
  Run a code review on the given code string.

  ## Options

  - `:llm` — provider module (default: `Phlox.LLM.Google`)
  - `:llm_opts` — provider options (default: `[]`)
  - `:language` — language name for prompts (default: `"elixir"`)
  - `:checkpoint` — `{adapter, opts}` to enable checkpointing (optional)
  - `:run_id` — checkpoint run id (optional)

  ## Examples

      # Minimal — uses Google AI Studio
      {:ok, result} = Phlox.Examples.CodeReview.run(~S'''
        def fetch_user(id) do
          query = "SELECT * FROM users WHERE id = \#{id}"
          Repo.query!(query)
        end
      ''')

      IO.puts(result.final_review)

      # With Anthropic
      {:ok, result} = Phlox.Examples.CodeReview.run(code,
        llm: Phlox.LLM.Anthropic,
        llm_opts: [model: "claude-sonnet-4-20250514"],
        language: "elixir"
      )

      # With checkpointing (resume if interrupted)
      {:ok, _} = Phlox.Checkpoint.Memory.start_link()
      {:ok, result} = Phlox.Examples.CodeReview.run(code,
        llm: Phlox.LLM.Google,
        checkpoint: {Phlox.Checkpoint.Memory, []},
        run_id: "review-001"
      )
  """
  @spec run(String.t(), keyword()) :: {:ok, map()} | {:error, term()}
  def run(code, opts \\ []) do
    language = Keyword.get(opts, :language, "elixir")

    shared = %{
      code: code,
      language: language
    }

    f = flow(opts)

    # Build pipeline options
    middlewares = [Phlox.Middleware.Validate]
    metadata = %{}

    {middlewares, metadata} =
      case Keyword.get(opts, :checkpoint) do
        nil ->
          {middlewares, metadata}

        {_adapter, _adapter_opts} = cp ->
          {middlewares ++ [Phlox.Middleware.Checkpoint],
           Map.merge(metadata, %{
             checkpoint: cp,
             flow_name: "CodeReview"
           })}
      end

    pipeline_opts =
      [middlewares: middlewares, metadata: metadata]
      |> then(fn o ->
        case Keyword.get(opts, :run_id) do
          nil -> o
          run_id -> Keyword.put(o, :run_id, run_id)
        end
      end)

    try do
      result = Pipeline.orchestrate(f, f.start_id, shared, pipeline_opts)
      {:ok, result}
    rescue
      e -> {:error, e}
    end
  end
end
