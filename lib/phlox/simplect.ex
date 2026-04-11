defmodule Phlox.Simplect do
  @moduledoc """
  🪨 Token-efficient LLM communication. Why use many token when few token do trick.

  Inspired by [caveman](https://github.com/JuliusBrussee/caveman) by Julius Brussee
  and named after Rich Hickey's concept of "complected" — if things that are braided
  together are *complected*, then things stripped to their essence are *simplected*.

  ## Intensity levels

  | Level   | What it do                                           | Savings |
  |---------|------------------------------------------------------|---------|
  | `:lite` | Drop filler, keep grammar. Professional, no fluff.   | ~40%    |
  | `:full` | Drop articles, fragments OK, short synonyms. Classic.| ~65%    |
  | `:ultra`| Abbreviate, arrows for causality, maximum compress.  | ~75%    |

  ## Direct usage with Phlox.LLM adapters

      messages = [%{role: "user", content: "Explain GenServer"}]

      messages
      |> Phlox.Simplect.wrap(:full)
      |> Phlox.LLM.Anthropic.chat(model: "claude-sonnet-4-20250514")

  ## As middleware + interceptor

  Use `Phlox.Middleware.Simplect` for pipeline-wide injection, and
  `Phlox.Interceptor.Complect` for per-node overrides. See their
  moduledocs for details.

  ## Safety

  The system prompt instructs the LLM to use full English for security
  warnings, irreversible action confirmations, and multi-step sequences
  where compressed fragments risk being misread.
  """

  @levels [:lite, :full, :ultra]

  # Markers so Complect interceptor can find/replace/strip the simplect
  # prompt inside a system message without touching user-authored content.
  @marker_start "<<SIMPLECT>>"
  @marker_end "<</SIMPLECT>>"

  @doc false
  def marker_start, do: @marker_start

  @doc false
  def marker_end, do: @marker_end

  @doc """
  Return the simplect system prompt for the given intensity level,
  wrapped in markers for `Phlox.Interceptor.Complect` to locate.

  ## Levels

  - `:lite` — drop filler/hedging, keep grammar structure
  - `:full` — (default) drop articles, fragments OK, short synonyms
  - `:ultra` — abbreviate, arrows for causality, maximum compression
  """
  @spec prompt(atom()) :: String.t()
  def prompt(level \\ :full)

  def prompt(:lite) do
    mark("""
    Respond concisely. Drop filler words (just, really, basically, actually, simply). \
    Drop pleasantries (sure, certainly, of course, happy to help). \
    Drop hedging (it might be worth considering, you may want to). \
    Keep grammar structure intact. Professional but no fluff. \
    Technical terms stay exact. Code blocks unchanged. Error messages quoted exact. \
    Drop concise mode for: security warnings, irreversible action confirmations. \
    Use full English for those, then resume concise mode.\
    """)
  end

  def prompt(:full) do
    mark("""
    Respond terse like smart caveman. All technical substance stay. Only fluff die. \
    Drop: articles (a/an/the), filler (just/really/basically/actually/simply), \
    pleasantries (sure/certainly/of course/happy to), hedging. \
    Fragments OK. No need full sentence. \
    Short synonyms (big not extensive, fix not "implement a solution for"). \
    Technical terms exact. Code blocks unchanged. Errors quoted exact. \
    Pattern: [thing] [action] [reason]. [next step]. \
    Not: "Sure! I'd be happy to help you with that. The issue is..." \
    But: "Issue: [x]. Fix: [y]." \
    Drop terse mode for: security warnings, irreversible action confirmations, \
    multi-step sequences where fragment order risks misread. \
    Use full English for those, then resume terse mode.\
    """)
  end

  def prompt(:ultra) do
    mark("""
    Maximum compression mode. \
    Abbreviate (DB/auth/config/req/res/fn/impl). \
    Strip conjunctions. Arrows for causality (X → Y). \
    One word when one word enough. \
    Drop: articles, filler, pleasantries, hedging, all grammar fluff. \
    Technical terms exact. Code blocks unchanged. Errors quoted exact. \
    Pattern: [thing] → [cause] → [fix]. \
    Drop compression for: security warnings, irreversible actions. \
    Full English for those, resume ultra after.\
    """)
  end

  @doc """
  Return the raw prompt text without markers.
  Useful for inspection or testing.
  """
  @spec raw_prompt(atom()) :: String.t()
  def raw_prompt(level \\ :full) do
    level |> prompt() |> strip_markers()
  end

  @doc """
  Prepend a simplect system message to a list of LLM messages.

  If the messages already contain a system message, the simplect prompt
  is appended to it (separated by a double newline) rather than adding
  a second system message.

  ## Examples

      iex> messages = [%{role: "user", content: "Explain OTP"}]
      iex> wrapped = Phlox.Simplect.wrap(messages, :full)
      iex> hd(wrapped).role
      "system"

      iex> messages = [
      ...>   %{role: "system", content: "You are an Elixir expert."},
      ...>   %{role: "user", content: "Explain OTP"}
      ...> ]
      iex> wrapped = Phlox.Simplect.wrap(messages, :full)
      iex> length(wrapped)
      2
  """
  @spec wrap([map()], atom()) :: [map()]
  def wrap(messages, level \\ :full) when level in @levels do
    simplect = prompt(level)

    case Enum.split_with(messages, &system?/1) do
      {[], rest} ->
        [%{role: "system", content: simplect} | rest]

      {[sys | tail_sys], rest} ->
        existing = sys[:content] || sys["content"]
        merged = %{role: "system", content: existing <> "\n\n" <> simplect}
        [merged | tail_sys ++ rest]
    end
  end

  @doc """
  Validate that a level atom is a known simplect intensity.
  Returns `{:ok, level}` or `{:error, :unknown_level}`.
  """
  @spec validate_level(atom()) :: {:ok, atom()} | {:error, :unknown_level}
  def validate_level(level) when level in @levels, do: {:ok, level}
  def validate_level(_), do: {:error, :unknown_level}

  @doc "List all supported intensity levels."
  @spec levels() :: [atom()]
  def levels, do: @levels

  @doc """
  Check whether a string contains a simplect-marked prompt.
  """
  @spec marked?(String.t()) :: boolean()
  def marked?(text) when is_binary(text) do
    String.contains?(text, @marker_start)
  end

  def marked?(_), do: false

  @doc """
  Strip all simplect-marked content from a string.
  Returns the string with the marked section (and surrounding whitespace) removed.
  """
  @spec strip(String.t()) :: String.t()
  def strip(text) when is_binary(text) do
    text
    |> String.replace(~r/\n?\n?#{Regex.escape(@marker_start)}.*?#{Regex.escape(@marker_end)}/s, "")
    |> String.trim()
  end

  @doc """
  Replace any existing simplect-marked content with a new level's prompt.
  If no marked content exists, appends the prompt.
  """
  @spec replace(String.t(), atom()) :: String.t()
  def replace(text, level) when is_binary(text) and level in @levels do
    new_prompt = prompt(level)

    if marked?(text) do
      text
      |> String.replace(
        ~r/#{Regex.escape(@marker_start)}.*?#{Regex.escape(@marker_end)}/s,
        new_prompt
      )
      |> String.trim()
    else
      (text <> "\n\n" <> new_prompt) |> String.trim()
    end
  end

  # ---------------------------------------------------------------------------
  # Private
  # ---------------------------------------------------------------------------

  defp mark(text), do: @marker_start <> String.trim(text) <> @marker_end

  defp strip_markers(text) do
    text
    |> String.replace(@marker_start, "")
    |> String.replace(@marker_end, "")
  end

  defp system?(m) do
    role = to_string(m[:role] || m["role"])
    role == "system"
  end
end
