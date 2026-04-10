# With Google (free)
export GOOGLE_AI_KEY=your_key_here

iex -S mix

{:ok, result} = Phlox.Examples.CodeReview.run(~S"""
  def fetch_user(id) do
    query = "SELECT * FROM users WHERE id = #{id}"
    Repo.query!(query)
  end
""",
  llm: Phlox.LLM.Google,
  llm_opts: [model: "gemini-2.5-flash"],
  language: "elixir"
)

IO.puts(result.final_review)

# Check the individual specialist reviews too:
IO.puts(result.security_review)
IO.puts(result.logic_review)
IO.puts(result.style_review)
