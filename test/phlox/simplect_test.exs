defmodule Phlox.SimplectTest do
  use ExUnit.Case, async: true

  alias Phlox.Simplect

  # ===========================================================================
  # Core prompt engine
  # ===========================================================================

  describe "prompt/1" do
    test "returns a marked string for each level" do
      for level <- [:lite, :full, :ultra] do
        prompt = Simplect.prompt(level)
        assert is_binary(prompt)
        assert Simplect.marked?(prompt)
      end
    end

    test "defaults to :full" do
      assert Simplect.prompt() == Simplect.prompt(:full)
    end

    test ":full prompt includes key compression rules" do
      prompt = Simplect.raw_prompt(:full)
      assert prompt =~ "articles"
      assert prompt =~ "filler"
      assert prompt =~ "Technical terms"
      assert prompt =~ "Code blocks unchanged"
      assert prompt =~ "security warnings"
    end

    test ":ultra prompt includes abbreviation rules" do
      prompt = Simplect.raw_prompt(:ultra)
      assert prompt =~ "Abbreviate"
      assert prompt =~ "→"
    end

    test ":lite prompt keeps grammar, no article dropping" do
      prompt = Simplect.raw_prompt(:lite)
      assert prompt =~ "filler"
      refute prompt =~ "articles"
    end
  end

  describe "raw_prompt/1" do
    test "returns prompt without markers" do
      raw = Simplect.raw_prompt(:full)
      refute Simplect.marked?(raw)
      assert raw =~ "terse"
    end
  end

  # ===========================================================================
  # Message wrapping
  # ===========================================================================

  describe "wrap/2" do
    test "prepends system message when none exists" do
      messages = [%{role: "user", content: "Hello"}]
      wrapped = Simplect.wrap(messages, :full)

      assert length(wrapped) == 2
      assert hd(wrapped).role == "system"
      assert Simplect.marked?(hd(wrapped).content)
    end

    test "merges with existing system message" do
      messages = [
        %{role: "system", content: "You are an Elixir expert."},
        %{role: "user", content: "Explain GenServer"}
      ]

      wrapped = Simplect.wrap(messages, :full)

      assert length(wrapped) == 2
      system = hd(wrapped)
      assert system.content =~ "You are an Elixir expert."
      assert Simplect.marked?(system.content)
    end

    test "defaults to :full" do
      messages = [%{role: "user", content: "Hi"}]
      assert Simplect.wrap(messages) == Simplect.wrap(messages, :full)
    end

    test "works with string-keyed maps" do
      messages = [
        %{"role" => "system", "content" => "Be helpful."},
        %{"role" => "user", "content" => "Hi"}
      ]

      wrapped = Simplect.wrap(messages, :ultra)
      assert length(wrapped) == 2
      assert hd(wrapped).content =~ "Be helpful."
      assert hd(wrapped).content =~ "Abbreviate"
    end

    test "preserves non-system message order" do
      messages = [
        %{role: "user", content: "First"},
        %{role: "assistant", content: "Reply"},
        %{role: "user", content: "Second"}
      ]

      wrapped = Simplect.wrap(messages, :lite)
      assert length(wrapped) == 4
      roles = Enum.map(wrapped, & &1.role)
      assert roles == ["system", "user", "assistant", "user"]
    end
  end

  # ===========================================================================
  # Marker operations (used by Complect)
  # ===========================================================================

  describe "marked?/1" do
    test "true for marked prompts" do
      assert Simplect.marked?(Simplect.prompt(:full))
    end

    test "false for plain strings" do
      refute Simplect.marked?("You are a helpful assistant.")
    end

    test "false for non-strings" do
      refute Simplect.marked?(nil)
      refute Simplect.marked?(42)
    end
  end

  describe "strip/1" do
    test "removes marked content from a combined string" do
      combined = "You are an expert.\n\n" <> Simplect.prompt(:full)
      stripped = Simplect.strip(combined)

      assert stripped == "You are an expert."
      refute Simplect.marked?(stripped)
    end

    test "returns empty string when entire content is marked" do
      assert Simplect.strip(Simplect.prompt(:full)) == ""
    end

    test "leaves unmarked strings unchanged" do
      text = "Just a normal prompt."
      assert Simplect.strip(text) == text
    end
  end

  describe "replace/2" do
    test "replaces marked content with new level" do
      original = "Be concise.\n\n" <> Simplect.prompt(:lite)
      replaced = Simplect.replace(original, :ultra)

      assert replaced =~ "Be concise."
      assert replaced =~ "Abbreviate"
      refute replaced =~ "Keep grammar structure"
    end

    test "appends when no marked content exists" do
      text = "You are an expert."
      replaced = Simplect.replace(text, :full)

      assert replaced =~ "You are an expert."
      assert Simplect.marked?(replaced)
    end

    test "swapping levels round-trips correctly" do
      base = "Custom instructions.\n\n" <> Simplect.prompt(:lite)

      upgraded = Simplect.replace(base, :ultra)
      assert upgraded =~ "Abbreviate"
      refute upgraded =~ "Keep grammar structure"

      downgraded = Simplect.replace(upgraded, :lite)
      assert downgraded =~ "Keep grammar structure"
      refute downgraded =~ "Abbreviate"

      # User content preserved through all swaps
      assert downgraded =~ "Custom instructions."
    end
  end

  describe "validate_level/1" do
    test "accepts known levels" do
      for level <- [:lite, :full, :ultra] do
        assert {:ok, ^level} = Simplect.validate_level(level)
      end
    end

    test "rejects unknown levels" do
      assert {:error, :unknown_level} = Simplect.validate_level(:turbo)
      assert {:error, :unknown_level} = Simplect.validate_level("full")
      assert {:error, :unknown_level} = Simplect.validate_level(:off)
    end
  end

  describe "levels/0" do
    test "returns all three levels" do
      assert Simplect.levels() == [:lite, :full, :ultra]
    end
  end
end

# =============================================================================
# Middleware
# =============================================================================

defmodule Phlox.Middleware.SimplectTest do
  use ExUnit.Case, async: true

  alias Phlox.Middleware.Simplect, as: SimplectMW
  alias Phlox.Simplect

  defp ctx(metadata \\ %{}) do
    %{
      node_id: :test_node,
      node: %{id: :test_node},
      flow: %Phlox.Flow{start_id: :test_node, nodes: %{}},
      run_id: "test-run",
      metadata: metadata
    }
  end

  describe "before_node/2" do
    test "injects simplect prompt at default key" do
      {:cont, shared} = SimplectMW.before_node(%{}, ctx())

      assert is_binary(shared.system_prompt)
      assert Simplect.marked?(shared.system_prompt)
    end

    test "defaults to :full when no level specified" do
      {:cont, shared} = SimplectMW.before_node(%{}, ctx())
      assert shared.system_prompt == Simplect.prompt(:full)
    end

    test "respects level from metadata" do
      {:cont, shared} = SimplectMW.before_node(%{}, ctx(%{simplect: :ultra}))
      assert shared.system_prompt == Simplect.prompt(:ultra)
    end

    test "shared[:simplect] overrides metadata" do
      {:cont, shared} =
        SimplectMW.before_node(
          %{simplect: :lite},
          ctx(%{simplect: :ultra})
        )

      assert shared.system_prompt =~ "Keep grammar structure"
      refute shared.system_prompt =~ "Abbreviate"
    end

    test "appends to existing system_prompt" do
      existing = "You are an Elixir expert."
      {:cont, shared} = SimplectMW.before_node(%{system_prompt: existing}, ctx())

      assert shared.system_prompt =~ "You are an Elixir expert."
      assert Simplect.marked?(shared.system_prompt)
    end

    test "replaces existing simplect prompt when level changes" do
      # Simulate a prior node changing shared[:simplect] from :lite to :ultra
      prior_prompt = "Custom.\n\n" <> Simplect.prompt(:lite)
      {:cont, shared} =
        SimplectMW.before_node(
          %{system_prompt: prior_prompt, simplect: :ultra},
          ctx()
        )

      assert shared.system_prompt =~ "Custom."
      assert shared.system_prompt =~ "Abbreviate"
      refute shared.system_prompt =~ "Keep grammar structure"
    end

    test "uses custom key from metadata" do
      {:cont, shared} =
        SimplectMW.before_node(%{}, ctx(%{simplect_key: :llm_system}))

      assert is_nil(shared[:system_prompt])
      assert Simplect.marked?(shared.llm_system)
    end

    test ":off skips injection entirely" do
      {:cont, shared} = SimplectMW.before_node(%{simplect: :off}, ctx())
      refute Map.has_key?(shared, :system_prompt)
    end

    test "raises on unknown level in shared" do
      assert_raise ArgumentError, ~r/unknown level/, fn ->
        SimplectMW.before_node(%{simplect: :turbo}, ctx())
      end
    end
  end
end

# =============================================================================
# Interceptor
# =============================================================================

defmodule Phlox.Interceptor.ComplectTest do
  use ExUnit.Case, async: true

  alias Phlox.Interceptor.Complect
  alias Phlox.Simplect

  defp ctx(opts) do
    %{
      node_id: :test_node,
      node_module: __MODULE__,
      params: %{},
      interceptor_opts: opts,
      prep_res: nil
    }
  end

  defp messages(system_content) do
    [
      %{role: "system", content: system_content},
      %{role: "user", content: "Hello"}
    ]
  end

  describe "before_exec/2 with message lists" do
    test ":off strips simplect prompt, preserves user content" do
      system = "You are an expert.\n\n" <> Simplect.prompt(:full)
      {:cont, result} = Complect.before_exec(messages(system), ctx(level: :off))

      [sys | _] = result
      assert sys.content == "You are an expert."
      refute Simplect.marked?(sys.content)
    end

    test ":off removes system message entirely when it's only simplect" do
      {:cont, result} =
        Complect.before_exec(messages(Simplect.prompt(:full)), ctx(level: :off))

      roles = Enum.map(result, & &1.role)
      refute "system" in roles
      assert length(result) == 1
    end

    test ":ultra replaces simplect level" do
      system = "Custom.\n\n" <> Simplect.prompt(:lite)
      {:cont, result} = Complect.before_exec(messages(system), ctx(level: :ultra))

      [sys | _] = result
      assert sys.content =~ "Custom."
      assert sys.content =~ "Abbreviate"
      refute sys.content =~ "Keep grammar structure"
    end

    test ":lite downgrades from :ultra" do
      system = "Custom.\n\n" <> Simplect.prompt(:ultra)
      {:cont, result} = Complect.before_exec(messages(system), ctx(level: :lite))

      [sys | _] = result
      assert sys.content =~ "Keep grammar structure"
      refute sys.content =~ "Abbreviate"
    end

    test "injects prompt when none exists (no prior simplect)" do
      {:cont, result} =
        Complect.before_exec(messages("You are an expert."), ctx(level: :full))

      [sys | _] = result
      assert sys.content =~ "You are an expert."
      assert Simplect.marked?(sys.content)
    end

    test "preserves non-system messages" do
      system = "Expert.\n\n" <> Simplect.prompt(:full)
      msgs = [
        %{role: "system", content: system},
        %{role: "user", content: "Question 1"},
        %{role: "assistant", content: "Answer 1"},
        %{role: "user", content: "Question 2"}
      ]

      {:cont, result} = Complect.before_exec(msgs, ctx(level: :ultra))

      assert length(result) == 4
      assert Enum.at(result, 1).content == "Question 1"
      assert Enum.at(result, 2).content == "Answer 1"
      assert Enum.at(result, 3).content == "Question 2"
    end
  end

  describe "before_exec/2 with non-message prep_res" do
    test "passes through strings unchanged" do
      {:cont, result} = Complect.before_exec("just a string", ctx(level: :off))
      assert result == "just a string"
    end

    test "passes through maps unchanged" do
      data = %{query: "hello"}
      {:cont, result} = Complect.before_exec(data, ctx(level: :ultra))
      assert result == data
    end

    test "passes through non-message lists unchanged" do
      data = [1, 2, 3]
      {:cont, result} = Complect.before_exec(data, ctx(level: :off))
      assert result == data
    end

    test "passes through nil unchanged" do
      {:cont, result} = Complect.before_exec(nil, ctx(level: :off))
      assert result == nil
    end
  end

  describe "error handling" do
    test "raises on missing :level opt" do
      assert_raise KeyError, fn ->
        Complect.before_exec(messages("Hi"), ctx([]))
      end
    end

    test "raises on unknown level" do
      assert_raise ArgumentError, ~r/unknown level/, fn ->
        Complect.before_exec(messages("Hi"), ctx(level: :turbo))
      end
    end
  end
end
