# export GROQ_API_KEY=gsk_your_key_here

# Quick smoke test — does the key work?
Phlox.LLM.Groq.chat(
  [%{role: "user", content: "Say hello in one sentence."}],
  model: "llama-3.3-70b-versatile"
)
Phlox.LLM.Groq.chat(
  [%{role: "user", content: "Do it differently."}],
  model: "llama-3.3-70b-versatile"
)

# Phlox test - do the 3 agents catch the issues,
# and does the Synthesizer agent dedupe and summarize findings?
{:ok, result} = Phlox.Examples.CodeReview.run(~S"""
  def fetch_user(id) do
    query = "SELECT * FROM users WHERE id = #{id}"
    Repo.query!(query)
  end
""",
  llm: Phlox.LLM.Groq,
  llm_opts: [model: "llama-3.3-70b-versatile"],
  # llm: Phlox.LLM.Anthropic,
  # llm_opts: [model: "claude-sonnet-4-6"]
  # llm_opts: [model: "claude-haiku-4-5-20251001"]
  # llm_opts: [model: "claude-opus-4-6"]
  language: "elixir"
)

IO.puts(result.final_review)
