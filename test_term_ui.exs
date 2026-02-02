# Test script to check if term_ui works standalone
# Run with: mix run test_term_ui.exs

defmodule TestApp do
  use TermUI.Elm

  alias TermUI.Event
  alias TermUI.Renderer.Style

  defstruct count: 0

  def init(_opts), do: %__MODULE__{}

  def event_to_msg(%Event.Key{key: "q"}, _state), do: {:msg, :quit}
  def event_to_msg(%Event.Key{key: :up}, _state), do: {:msg, :increment}
  def event_to_msg(%Event.Key{key: :down}, _state), do: {:msg, :decrement}
  def event_to_msg(_, _), do: :ignore

  def update(:quit, state), do: {state, [:quit]}
  def update(:increment, state), do: {%{state | count: state.count + 1}, []}
  def update(:decrement, state), do: {%{state | count: state.count - 1}, []}

  def view(state) do
    stack(:vertical, [
      text("TermUI Test", Style.new(fg: :cyan, attrs: [:bold])),
      text("Count: #{state.count}", nil),
      text("", nil),
      text("↑/↓ to change, Q to quit", Style.new(fg: :bright_black))
    ])
  end
end

IO.puts("Starting TermUI test app...")
IO.puts("Press Q to quit")
Process.sleep(500)

TermUI.Runtime.run(root: TestApp)

IO.puts("Done!")
