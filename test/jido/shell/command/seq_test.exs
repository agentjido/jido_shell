defmodule Jido.Shell.Command.SeqTest do
  use Jido.Shell.Case, async: true

  alias Jido.Shell.ShellSession.State
  alias Jido.Shell.Command.Seq

  setup do
    {:ok, state} = State.new(%{id: "test", workspace_id: "test"})
    {:ok, state: state}
  end

  describe "run/3" do
    test "prints sequence with defaults", %{state: state} do
      events =
        capture_events(fn emit ->
          Seq.run(state, %{args: []}, emit)
        end)

      assert length(events) == 10
      assert {:output, "1\n"} in events
      assert {:output, "10\n"} in events
    end

    test "prints custom count", %{state: state} do
      events =
        capture_events(fn emit ->
          Seq.run(state, %{args: ["3"]}, emit)
        end)

      assert length(events) == 3
    end

    test "respects delay", %{state: state} do
      start = System.monotonic_time(:millisecond)

      capture_events(fn emit ->
        Seq.run(state, %{args: ["3", "50"]}, emit)
      end)

      elapsed = System.monotonic_time(:millisecond) - start
      assert elapsed >= 100
    end

    test "returns count on success", %{state: state} do
      result = Seq.run(state, %{args: ["5", "0"]}, fn _ -> :ok end)
      assert {:ok, 5} = result
    end

    test "works with zero delay", %{state: state} do
      events =
        capture_events(fn emit ->
          Seq.run(state, %{args: ["2", "0"]}, emit)
        end)

      assert length(events) == 2
    end

    test "returns validation error for invalid count", %{state: state} do
      assert {:error, %Jido.Shell.Error{code: {:validation, :invalid_args}}} =
               Seq.run(state, %{args: ["abc", "0"]}, fn _ -> :ok end)
    end

    test "returns validation error for invalid delay", %{state: state} do
      assert {:error, %Jido.Shell.Error{code: {:validation, :invalid_args}}} =
               Seq.run(state, %{args: ["2", "-1"]}, fn _ -> :ok end)
    end
  end

  describe "metadata" do
    test "has correct name" do
      assert Seq.name() == "seq"
    end

    test "has summary" do
      assert Seq.summary() == "Print sequence of numbers"
    end

    test "has schema" do
      assert Seq.schema()
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
