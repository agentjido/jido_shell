defmodule Jido.Shell.Command.HelpTest do
  use Jido.Shell.Case, async: true

  alias Jido.Shell.Session.State
  alias Jido.Shell.Command.Help

  setup do
    {:ok, state} = State.new(%{id: "test", workspace_id: :test})
    {:ok, state: state}
  end

  describe "run/3" do
    test "lists all commands when no args", %{state: state} do
      events =
        capture_events(fn emit ->
          Help.run(state, %{args: []}, emit)
        end)

      assert [{:output, output}] = events
      assert output =~ "Available commands:"
      assert output =~ "echo"
      assert output =~ "pwd"
      assert output =~ "ls"
    end

    test "shows specific command help", %{state: state} do
      events =
        capture_events(fn emit ->
          Help.run(state, %{args: ["echo"]}, emit)
        end)

      assert [{:output, output}] = events
      assert output =~ "echo"
      assert output =~ "Print arguments to output"
    end

    test "returns error for unknown command", %{state: state} do
      result = Help.run(state, %{args: ["unknowncmd"]}, fn _ -> :ok end)

      assert {:error, %Jido.Shell.Error{code: {:shell, :unknown_command}}} = result
    end

    test "shows help for command without moduledoc", %{state: state} do
      events =
        capture_events(fn emit ->
          Help.run(state, %{args: ["help"]}, emit)
        end)

      assert [{:output, output}] = events
      assert output =~ "help"
      assert output =~ "Show available commands"
    end
  end

  defp capture_events(fun) do
    emit = fn event ->
      send(self(), {:event, event})
      :ok
    end

    fun.(emit)

    receive_all_events([])
  end

  defp receive_all_events(acc) do
    receive do
      {:event, event} -> receive_all_events([event | acc])
    after
      0 -> Enum.reverse(acc)
    end
  end
end
